<#
    Re-authenticate the Amazon Business automation profile.
    Opens a visible Edge window; sign in (tick "Keep me signed in"), then it
    auto-detects success and saves the session for the daily job.
#>
$root = "$env:USERPROFILE\AmazonReportBot"  # TODO: set this to your AmazonReportBot install folder
$py = Join-Path $root ".venv\Scripts\python.exe"
$env:PYTHONIOENCODING = "utf-8"
Write-Host "Opening the automation Edge window for sign-in..." -ForegroundColor Cyan
& $py (Join-Path $root "login.py")
