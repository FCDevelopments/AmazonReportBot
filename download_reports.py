"""
Amazon Business - Orders report "Download order documents -> Download all".

Flow per date range:
  1. Navigate to the reports page with dateSpanSelection=<SPAN> (sets the range).
  2. Click "Download order documents" -> "Download all".
  3. In the "Choose the type of documents to download" modal, tick the requested
     document type(s) and click Download. (Amazon queues an async export.)
  4. Go to the "Documents downloaded" history tab, wait for the new export row to
     finish ("In progress" -> "Download documents" button), then download the zip.

Saves zips to ./downloads and prints a SUMMARY. Exit codes:
  0 = all requested ranges downloaded
  2 = login wall (session expired -> re-auth needed)
  3 = one or more ranges failed
  4 = "too many orders" limit hit for a range
"""
import os
import re
import sys
import json
import time
from datetime import datetime, timedelta
from pathlib import Path
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).parent
PROFILE = ROOT / "edge-profile"
LOGS = ROOT / "logs"
DOWNLOADS = ROOT / "downloads"

# Document types to request in the modal (by checkbox 'name' attribute).
# "printable-order-summary" = the order receipt/summary documents.
# "pbi-invoice" = Pay By Invoice program documents.
DOC_TYPES = ["printable-order-summary"]

VALID_SPANS = {
    "WEEK_TO_DATE", "PAST_7_DAYS", "MONTH_TO_DATE", "PAST_4_WEEKS", "LAST_MONTH",
    "QUARTER_TO_DATE", "PAST_12_WEEKS", "YEAR_TO_DATE", "PAST_12_MONTHS",
}

REPORTS_URL = ("https://www.amazon.com/b2b/aba/reports"
               "?reportType=items_report_1&dateSpanSelection={span}&ref=hpr_redirect_report")
HISTORY_URL = ("https://www.amazon.com/b2b/aba/reports"
               "?ref=hpr_redirect_download_history&activeTab=bulk-download-history-tab")

TOP_ROW = "#generic_listitem_bulk_download_item_0"
DL_BTN = 'button[data-testid="download-csv-file"]'


def log(msg):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def is_login_wall(page):
    u = page.url.lower()
    return "/ap/signin" in u or ("signin" in u and "openid" in u)


def settle(page, idle_ms=15000, pause=2):
    try:
        page.wait_for_load_state("networkidle", timeout=idle_ms)
    except PWTimeout:
        pass
    time.sleep(pause)


def parse_created_on(row_text):
    """Extract the 'Created on: 6/9/2026, 10:19:51 AM' timestamp from a row, or None."""
    m = re.search(r"Created on:\s*([\d/]+,\s*[\d:]+\s*[AP]M)", row_text)
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1), "%m/%d/%Y, %I:%M:%S %p")
    except ValueError:
        return None


def goto_reports(page, span, retries=3):
    """Navigate to the reports page for a span, retrying transient login walls.
    Returns True if the reports page loaded logged-in, False if a persistent login wall."""
    for attempt in range(retries):
        page.goto(REPORTS_URL.format(span=span), wait_until="domcontentloaded", timeout=60000)
        settle(page, idle_ms=20000, pause=2)
        if not is_login_wall(page):
            return True
        log(f"[{span}] login wall on load (attempt {attempt + 1}/{retries}) - backing off")
        time.sleep(6 * (attempt + 1))
    return False


def active_modal_text(page):
    m = page.locator("div.b-modal.b-active[role='dialog']")
    if m.count() == 0:
        return ""
    try:
        return m.first.inner_text()
    except Exception:
        return ""


def submit_export(page, span):
    """Open Download all -> modal -> select doc types -> Download. Returns True/'TOO_MANY'/False."""
    try:
        page.locator("#download-order-documents-dropdown").click(timeout=15000)
    except PWTimeout:
        page.screenshot(path=str(LOGS / f"fail_{span}_nobtn.png"))
        log(f"[{span}] 'Download order documents' button not clickable")
        return False
    time.sleep(0.8)

    dl_all = page.locator('[data-testid="download-all-order-documents"]')
    if dl_all.count() == 0 or not dl_all.first.is_visible():
        page.screenshot(path=str(LOGS / f"fail_{span}_nodownloadall.png"))
        log(f"[{span}] 'Download all' option missing")
        return False
    dl_all.first.click()
    time.sleep(1.5)

    modal = page.locator("div.b-modal.b-active[role='dialog']")
    if modal.count() == 0:
        # maybe a 'too many orders' warning popped instead
        txt = active_modal_text(page).lower()
        if "too many" in txt or "fewer than" in txt:
            log(f"[{span}] TOO MANY ORDERS: {txt[:160]}")
            return "TOO_MANY"
        page.screenshot(path=str(LOGS / f"fail_{span}_nomodal.png"))
        log(f"[{span}] document-type modal did not appear")
        return False

    # Select the requested document types
    for name in DOC_TYPES:
        lbl = modal.locator(f"label[for]:has(input[name='{name}'])")
        if lbl.count() == 0:
            log(f"[{span}] doc type '{name}' not offered (skipping)")
            continue
        lbl.first.click()
        time.sleep(0.3)

    ok = modal.locator('[data-testid="ok-btn"]')
    if ok.get_attribute("aria-disabled") == "true":
        page.screenshot(path=str(LOGS / f"fail_{span}_okdisabled.png"))
        log(f"[{span}] Download button stayed disabled (no doc type selected?)")
        return False
    ok.click()
    time.sleep(2.5)

    # After submit, a warning modal may appear (too many orders)
    txt = active_modal_text(page).lower()
    if "too many" in txt or "fewer than" in txt:
        log(f"[{span}] TOO MANY ORDERS after submit: {txt[:160]}")
        return "TOO_MANY"
    return True


def wait_and_download(page, span, submit_dt, timeout_s=420):
    """Poll history until the export created at/after submit_dt is ready, then download it.
    Identifies the new export by its 'Created on' timestamp (no pre-submit nav needed)."""
    deadline = time.time() + timeout_s
    login_strikes = 0
    while time.time() < deadline:
        page.goto(HISTORY_URL, wait_until="domcontentloaded", timeout=60000)
        settle(page, idle_ms=10000, pause=2)

        if is_login_wall(page):
            login_strikes += 1
            log(f"[{span}] login wall during poll (strike {login_strikes}/3)")
            if login_strikes >= 3:
                return "LOGIN_WALL"
            time.sleep(8)
            continue
        login_strikes = 0

        row = page.locator(TOP_ROW)
        if row.count() == 0:
            log(f"[{span}] history poll: no rows yet")
            time.sleep(12)
            continue

        rowtext = row.first.inner_text()
        created = parse_created_on(rowtext)
        is_mine = created is not None and created >= (submit_dt - timedelta(seconds=120))
        btn = row.locator(DL_BTN)
        ready = is_mine and btn.count() > 0 and btn.first.is_visible()
        state = "READY" if ready else ("mine/in-progress" if is_mine else "waiting-for-my-row")
        log(f"[{span}] history poll: {state} (top row created {created})")

        if ready:
            fname = ""
            try:
                fname = row.locator("span:has-text('.zip')").first.inner_text().strip()
            except Exception:
                pass
            stamp = datetime.now().strftime("%Y%m%d")
            safe_span = re.sub(r"[^A-Za-z0-9_]", "-", span)
            out = DOWNLOADS / f"AmazonOrders_{safe_span}_{stamp}.zip"
            try:
                with page.expect_download(timeout=120000) as di:
                    btn.first.click()
                di.value.save_as(str(out))
            except PWTimeout:
                page.screenshot(path=str(LOGS / f"fail_{span}_dlclick.png"))
                log(f"[{span}] download did not start after clicking 'Download documents'")
                return None
            size = out.stat().st_size if out.exists() else 0
            log(f"[{span}] saved -> {out.name} ({size:,} bytes; amazon name: '{fname}')")
            return out
        time.sleep(14)

    log(f"[{span}] timed out waiting for export to finish")
    page.screenshot(path=str(LOGS / f"fail_{span}_historytimeout.png"))
    return None


def set_custom_range(page, start_str, end_str):
    """Fill the two Custom Range date inputs (MM/DD/YYYY) and click Submit."""
    inputs = page.locator("input[type='text']")
    date_idxs = []
    for i in range(inputs.count()):
        v = inputs.nth(i).input_value() or ""
        if re.match(r"^\d{2}/\d{2}/\d{4}$", v):
            date_idxs.append(i)
    if len(date_idxs) < 2:
        log("custom range: could not find the two date inputs")
        return False
    for idx, val in zip(date_idxs[:2], [start_str, end_str]):
        inp = inputs.nth(idx)
        inp.click()
        inp.fill("")
        inp.fill(val)
        inp.press("Tab")
        time.sleep(0.4)
    b = page.get_by_role("button", name="Submit", exact=True)
    if not (b.count() and b.first.is_visible()):
        log("custom range: Submit button not found")
        return False
    b.first.click()
    settle(page, idle_ms=15000, pause=3)
    return True


def has_no_records(page):
    """True if the orders list shows the 'no records for the selected time period' notice."""
    try:
        return "no records for the selected time period" in page.inner_text("body").lower()
    except Exception:
        return False


def navigate_range(page, span):
    """Navigate/configure the requested range. Returns True, 'LOGIN_WALL', or None."""
    if span == "YESTERDAY":
        d = (datetime.now() - timedelta(days=1)).strftime("%m/%d/%Y")
        url_span, custom = "CUSTOM_RANGE", (d, d)
    elif span.startswith("CUSTOM:"):
        _, s, e = span.split(":")
        url_span, custom = "CUSTOM_RANGE", (s, e)
    else:
        url_span, custom = span, None

    log(f"[{span}] navigating (urlspan={url_span}, custom={custom})...")
    if not goto_reports(page, url_span):
        return "LOGIN_WALL"
    try:
        shown = page.locator("#date_range_selector__range").inner_text(timeout=15000).strip()
        log(f"[{span}] date range shows: '{shown}'")
    except PWTimeout:
        page.screenshot(path=str(LOGS / f"fail_{span}_nodatesel.png"))
        log(f"[{span}] reports page did not load the date selector")
        return None
    if custom:
        if not set_custom_range(page, *custom):
            return None
        log(f"[{span}] custom range applied: {custom[0]} -> {custom[1]}")
    return True


def download_span(page, span):
    nav = navigate_range(page, span)
    if nav == "LOGIN_WALL":
        return "LOGIN_WALL"
    if nav is not True:
        return None
    time.sleep(2)

    if has_no_records(page):
        log(f"[{span}] no orders in this range - nothing to download")
        return "NO_ORDERS"

    res = submit_export(page, span)
    if res == "TOO_MANY":
        return "TOO_MANY"
    if not res:
        return None
    submit_dt = datetime.now()
    log(f"[{span}] export submitted at {submit_dt:%H:%M:%S}; waiting in download history...")
    return wait_and_download(page, span, submit_dt)


def parse_args(argv):
    """Split argv into (spans, cdp_port). `--cdp <port>` (or env EDGE_CDP_PORT)
    makes the downloader ATTACH to an already-running Edge over the DevTools
    protocol (opening a new tab in your real, logged-in window) instead of
    launching its own dedicated-profile browser."""
    cdp_port = os.environ.get("EDGE_CDP_PORT")
    spans = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--cdp":
            cdp_port = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
            continue
        spans.append(a.upper())
        i += 1
    return (spans or ["PAST_7_DAYS"]), (int(cdp_port) if cdp_port else None)


def main():
    spans, cdp_port = parse_args(sys.argv[1:])

    def valid(s):
        return s in VALID_SPANS or s == "YESTERDAY" or s.startswith("CUSTOM:")

    bad = [s for s in spans if not valid(s)]
    if bad:
        log(f"Invalid span(s): {bad}. Valid: presets {sorted(VALID_SPANS)}, "
            f"or YESTERDAY, or CUSTOM:MM/DD/YYYY:MM/DD/YYYY")
        sys.exit(1)

    results = {}
    login_wall = False
    with sync_playwright() as p:
        attached = False
        browser = None
        if cdp_port:
            # Attach to your real, already-signed-in Edge and open a new tab.
            log(f"Attaching to running Edge over CDP at localhost:{cdp_port} ...")
            try:
                browser = p.chromium.connect_over_cdp(
                    f"http://localhost:{cdp_port}", timeout=30000)
            except Exception as e:
                log(f"ERROR: could not attach to Edge on port {cdp_port}: {e}")
                log("Start Edge with the debug port first (run start_edge.ps1).")
                # Write a manifest so the orchestrator can react cleanly.
                (LOGS / "last_run.json").write_text(json.dumps({
                    "timestamp": datetime.now().isoformat(timespec="seconds"),
                    "login_wall": False, "cdp_error": True, "doc_types": DOC_TYPES,
                    "results": {s: {"status": "FAILED", "path": None} for s in spans},
                }, indent=2), encoding="utf-8")
                sys.exit(3)
            ctx = browser.contexts[0] if browser.contexts else browser.new_context(
                accept_downloads=True)
            ctx.set_default_timeout(30000)
            page = ctx.new_page()
            attached = True
        else:
            ctx = p.chromium.launch_persistent_context(
                user_data_dir=str(PROFILE), channel="msedge", headless=True,
                accept_downloads=True, downloads_path=str(DOWNLOADS),
                args=["--disable-blink-features=AutomationControlled"],
                viewport={"width": 1600, "height": 1000},
            )
            page = ctx.pages[0] if ctx.pages else ctx.new_page()

        try:
            for span in spans:
                r = download_span(page, span)
                if r == "LOGIN_WALL":
                    login_wall = True
                    break
                results[span] = r
        finally:
            if attached:
                # Close only OUR tab; leave the user's Edge window running.
                try:
                    page.close()
                except Exception:
                    pass
                try:
                    browser.close()  # detaches Playwright; does NOT close Edge
                except Exception:
                    pass
            else:
                ctx.close()

    print("\n===== SUMMARY =====")
    for span in spans:
        r = results.get(span)
        if isinstance(r, Path):
            print(f"  {span}: OK -> {r}")
        elif r == "TOO_MANY":
            print(f"  {span}: TOO_MANY_ORDERS (range too large for Download all)")
        elif r == "NO_ORDERS":
            print(f"  {span}: NO_ORDERS (no orders in this range)")
        else:
            print(f"  {span}: FAILED")

    # Write a machine-readable manifest for the orchestrator
    manifest = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "login_wall": login_wall,
        "doc_types": DOC_TYPES,
        "results": {
            span: ({"status": "OK", "path": str(results[span])}
                   if isinstance(results.get(span), Path)
                   else {"status": results.get(span) or "FAILED", "path": None})
            for span in spans
        },
    }
    (LOGS / "last_run.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    if login_wall:
        print("RESULT: LOGIN_WALL")
        sys.exit(2)
    statuses = [results.get(s) for s in spans]
    if any(r == "TOO_MANY" for r in statuses):
        sys.exit(4)
    if any(r is None for r in statuses):   # FAILED (NO_ORDERS is non-fatal)
        sys.exit(3)
    sys.exit(0)   # all OK and/or NO_ORDERS


if __name__ == "__main__":
    main()
