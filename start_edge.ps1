<#
    Make your REAL Edge browser attachable by the report automation.

    Why: the automation now opens a new tab in YOUR everyday Edge window (which is
    already signed in to Amazon) instead of a separate profile that keeps forcing
    a re-login. To allow that, Edge must be started with a DevTools debug port.

    A normal Edge launch does NOT expose the port, and you cannot add it to an
    already-running Edge -- so if Edge is open without the port, this script must
    restart it (your tabs are restored on relaunch). Pass -Force to allow that.

    Usage:
      .\start_edge.ps1            # check / start; will NOT kill a running Edge
      .\start_edge.ps1 -Force     # restart Edge with the debug port if needed
#>
param(
    [int]    $Port = 9222,
    [switch] $Force
)

function Test-DebugPort([int]$p) {
    try {
        $r = Invoke-WebRequest "http://localhost:$p/json/version" -UseBasicParsing -TimeoutSec 2
        return $r.StatusCode -eq 200
    } catch { return $false }
}

if (Test-DebugPort $Port) {
    Write-Host "Edge debug port $Port is already live. You're ready to run the report." -ForegroundColor Green
    return
}

$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $edge)) { $edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
if (-not (Test-Path $edge)) {
    $edge = (Get-Command msedge.exe -ErrorAction SilentlyContinue).Source
}
if (-not $edge) { Write-Error "Could not find msedge.exe."; exit 1 }

$running = Get-Process msedge -ErrorAction SilentlyContinue
if ($running -and -not $Force) {
    Write-Host ""
    Write-Host "Edge is running WITHOUT the debug port." -ForegroundColor Yellow
    Write-Host "It must be restarted to expose the port (your tabs will be restored)."
    Write-Host "Re-run with -Force to restart it:" -ForegroundColor Yellow
    Write-Host "    .\start_edge.ps1 -Force" -ForegroundColor Cyan
    exit 2
}

if ($running) {
    Write-Host "Closing Edge (tabs will be restored on relaunch)..." -ForegroundColor Yellow
    $running | Stop-Process -Force
    Start-Sleep -Seconds 3
}

Write-Host "Starting Edge with debug port $Port (your normal Default profile)..." -ForegroundColor Cyan
Start-Process $edge -ArgumentList @(
    "--remote-debugging-port=$Port",
    "--profile-directory=Default",
    "--restore-last-session"
)

# Wait for the port to come up.
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    if (Test-DebugPort $Port) {
        Write-Host "Edge debug port $Port is live. You're ready to run the report." -ForegroundColor Green
        return
    }
}
Write-Warning "Edge started but the debug port did not come up within 15s. Try again."
exit 3
