# Amazon Business Daily Report Automation

Automatically downloads **Amazon Business → Business Analytics → Orders report →
"Download order documents → Download all"** (Printable order summary PDFs, zipped)
for a date range, then emails the zip via the classic Outlook desktop app.
Runs daily at **8:00 AM** via Windows Task Scheduler.

## How it works
1. `download_reports.py` launches **Edge** with a dedicated, already-signed-in
   automation profile (`edge-profile/`), sets the Order Date range, triggers the
   async export, waits in **Download history** until ready, and saves the zip to
   `downloads/`.
2. `send_email.ps1` emails the zip(s) via Outlook COM.
3. `run_report.ps1` orchestrates download → email, logs to `logs/run_<date>.log`,
   retries transient login walls, and emails an alert if re-login is needed.

## Files
| File | Purpose |
|------|---------|
| `download_reports.py` | Browser automation that downloads the order-document zips |
| `send_email.ps1` | Sends email + attachments via Outlook |
| `run_report.ps1` | Orchestrator (download + email + logging + retry/alert) |
| `login.ps1` / `login.py` | One-time / re-auth sign-in for the Edge profile |
| `edge-profile/` | Dedicated Edge profile holding the Amazon session (do not delete) |
| `downloads/` | Saved report zips |
| `logs/` | Run logs, `last_run.json` manifest, failure screenshots |

## Setup
Before running this for the first time, fill in the placeholder values that were
left for you:
- `daily_run.ps1`: set `$root` to your install folder (defaults to
  `%USERPROFILE%\AmazonReportBot`), and set `$UploadServiceEmail` /
  `$AlertRecipientEmail` to your real report-delivery and alert addresses.
- `login.ps1` / `run_report.ps1`: set `$root` to your install folder if it isn't
  `%USERPROFILE%\AmazonReportBot`.
- Anywhere you invoke `run_report.ps1` or `send_email.ps1` directly, pass your own
  `-To` (and optionally `-AlertTo`) email address(es) — see examples below.

## Common commands
Run from your install folder (e.g. `%USERPROFILE%\AmazonReportBot`):

```powershell
# Re-authenticate the automation profile (do this if you get a re-login alert)
.\login.ps1

# Daily run (yesterday only) -> test address
.\run_report.ps1 -Spans YESTERDAY -To "recipient@example.com"

# First-run style pull: last 7 days + last ~30 days (Past 4 weeks)
.\run_report.ps1 -Spans PAST_7_DAYS,PAST_4_WEEKS -To "recipient@example.com"

# Arbitrary exact range
.\run_report.ps1 -Spans "CUSTOM:06/01/2026:06/30/2026" -To "recipient@example.com"
```

### Date range tokens (`-Spans`)
`YESTERDAY`, `PAST_7_DAYS`, `WEEK_TO_DATE`, `MONTH_TO_DATE`, `PAST_4_WEEKS`,
`LAST_MONTH`, `QUARTER_TO_DATE`, `PAST_12_WEEKS`, `YEAR_TO_DATE`, `PAST_12_MONTHS`,
or `CUSTOM:MM/DD/YYYY:MM/DD/YYYY`.

## The scheduled task
- Name: **AmazonBusinessDailyReport** — daily 8:00 AM, runs as the logged-on user.
- Sends `YESTERDAY` to whatever address is configured in `$UploadServiceEmail`
  (see `daily_run.ps1`) — set this to your own report-delivery/test address.
- To change recipient/range, edit the task's `-To` / `-Spans` arguments:
  ```powershell
  # View
  (Get-ScheduledTask AmazonBusinessDailyReport).Actions.Arguments
  ```

## Important notes / limitations
- **Machine must be logged on at 8:00 AM** (task uses the interactive user session
  so Outlook COM + the Edge profile work). If the PC is off/asleep, it runs at the
  next opportunity (`StartWhenAvailable`).
- **Session longevity:** the automation profile keeps a saved Amazon login. If it
  expires, the job retries, then emails a re-login alert; run `.\login.ps1` to fix.
  Tick **"Keep me signed in"** when signing in for the longest-lived session.
- **Order limit:** very large ranges can exceed Amazon's "Download all" order cap;
  the job reports `TOO_MANY_ORDERS` for that range (use narrower ranges).
- Document type is **Printable order summary** (set via `DOC_TYPES` in
  `download_reports.py`).
