"""
One-time / re-auth sign-in for the Amazon Business automation profile.

Opens a VISIBLE Edge window using the dedicated automation profile and waits
until you are signed in to the Business analytics reports page. The session is
saved in the profile and reused by the daily job.

IMPORTANT: tick "Keep me signed in" during sign-in for a long-lived session.
"""
import sys
import time
from pathlib import Path
from playwright.sync_api import sync_playwright

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).parent
PROFILE = ROOT / "edge-profile"
DOWNLOADS = ROOT / "downloads"
REPORTS_URL = ("https://www.amazon.com/b2b/aba/reports"
               "?reportType=items_report_1&dateSpanSelection=MONTH_TO_DATE&ref=hpr_redirect_report")
WAIT_MINUTES = 12


def logged_in(page):
    try:
        url = page.url.lower()
        if "/ap/signin" in url:
            return False
        return page.locator("#date_range_selector__range").count() > 0
    except Exception:
        return False


def main():
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            user_data_dir=str(PROFILE), channel="msedge", headless=False,
            accept_downloads=True, downloads_path=str(DOWNLOADS),
            args=["--start-maximized", "--disable-blink-features=AutomationControlled"],
            no_viewport=True,
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(REPORTS_URL, wait_until="domcontentloaded", timeout=60000)
        time.sleep(4)

        if logged_in(page):
            print("Already signed in. Session is valid.")
            ctx.close()
            return

        print("=" * 64)
        print("  Please SIGN IN in the Edge window that just opened.")
        print("  --> Tick 'Keep me signed in' for a long-lived session.")
        print("  Get all the way to the Business analytics > Orders report page.")
        print(f"  Waiting up to {WAIT_MINUTES} minutes for sign-in to complete...")
        print("=" * 64)

        deadline = time.time() + WAIT_MINUTES * 60
        while time.time() < deadline:
            if logged_in(page):
                print("\nSIGN-IN DETECTED. Session saved. You're all set.")
                time.sleep(3)
                ctx.close()
                return
            time.sleep(5)

        print("\nTimed out waiting for sign-in. Re-run login.ps1 to try again.")
        ctx.close()


if __name__ == "__main__":
    main()
