<#
    Orchestrator: download Amazon Business order documents for the given date
    range(s), then email the resulting zip(s) via Outlook.

    Examples:
      # First run (7-day + 30-day) to the test address:
      .\run_report.ps1 -Spans PAST_7_DAYS,PAST_4_WEEKS -To "recipient@example.com"

      # Daily run (single day) — see CUSTOM_RANGE note below:
      .\run_report.ps1 -Spans PAST_7_DAYS -To "recipient@example.com"

    Behavior:
      - Runs download_reports.py, reads logs\last_run.json manifest.
      - If the Amazon session expired (login wall), emails an ALERT and exits 2.
      - Emails the downloaded zip(s). By default all attachments go in ONE email;
        use -SeparateEmails to send one email per zip.
      - Everything is logged to logs\run_<date>.log.
#>
param(
    [string[]] $Spans = @("PAST_7_DAYS"),
    [Parameter(Mandatory = $true)] [string] $To,
    [string]   $Cc = "",
    [switch]   $SeparateEmails,
    [string]   $AlertTo = "",       # where to send failure alerts (defaults to $To)
    [int]      $MaxTries = 3,        # retries when a transient login wall is hit
    [int]      $RetryDelaySec = 150, # wait between login-wall retries
    [int]      $CdpPort = 9222,      # attach to your real Edge via this debug port
    [switch]   $NoCdp,               # use the old dedicated-profile browser instead
    [switch]   $PerReceipt           # extract zip -> send each order PDF as its own email
)

$ErrorActionPreference = "Stop"
$root = "$env:USERPROFILE\AmazonReportBot"  # TODO: set this to your AmazonReportBot install folder
$py   = Join-Path $root ".venv\Scripts\python.exe"
$dl   = Join-Path $root "download_reports.py"
$mailer = Join-Path $root "send_email.ps1"
$manifestPath = Join-Path $root "logs\last_run.json"
if (-not $AlertTo) { $AlertTo = $To }

$today = Get-Date -Format "yyyyMMdd"
$log = Join-Path $root "logs\run_$today.log"
function Log($m) {
    $line = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $m
    Write-Output $line
    Add-Content -Path $log -Value $line -Encoding utf8
}

Log "================ RUN START ================"
Log "Spans=$($Spans -join ',')  To=$To  Cc=$Cc  Separate=$($SeparateEmails.IsPresent)"

# --- 1. Download (with retry on transient login walls) ---
$env:PYTHONIOENCODING = "utf-8"

# Build the downloader args. By default we ATTACH to your real Edge (CDP) so the
# script opens a tab in your already-signed-in window (no separate re-login).
$dlArgs = @($Spans)
if (-not $NoCdp) {
    # Pre-flight: is the Edge debug port live?
    $portUp = $false
    try {
        $r = Invoke-WebRequest "http://localhost:$CdpPort/json/version" -UseBasicParsing -TimeoutSec 2
        $portUp = ($r.StatusCode -eq 200)
    } catch { $portUp = $false }

    if (-not $portUp) {
        Log "Edge debug port $CdpPort is not up. Cannot attach to your Edge."
        $body = @"
The Amazon automation is set to attach to your real Edge window, but Edge is not
exposing the debug port ($CdpPort).

To fix: run this once, then re-run the report:
    cd $root
    .\start_edge.ps1 -Force

(Or run the report with -NoCdp to use the old dedicated-profile browser.)
"@
        & $mailer -To $AlertTo -Subject "ALERT: Amazon automation - Edge debug port not available" -Body $body
        Write-Output $body
        exit 5
    }
    $dlArgs += @("--cdp", "$CdpPort")
    Log "Attaching to your Edge via CDP on port $CdpPort."
}

$manifest = $null
$attempt = 0
while ($true) {
    $attempt++
    Log "Download attempt $attempt of $MaxTries ..."
    $pyOut = & $py $dl @dlArgs
    $code = $LASTEXITCODE
    foreach ($l in $pyOut) { Add-Content -Path $log -Value "  [py] $l" -Encoding utf8 }
    Log "download_reports.py exit code = $code"

    if (-not (Test-Path $manifestPath)) {
        Log "ERROR: manifest not found; aborting."
        & $mailer -To $AlertTo -Subject "ALERT: Amazon report automation failed (no manifest)" `
            -Body "download_reports.py produced no manifest. Exit code $code. See $log." -Attachments @($log)
        exit 3
    }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

    if ($manifest.login_wall) {
        if ($attempt -lt $MaxTries) {
            Log "LOGIN WALL (likely transient). Waiting $RetryDelaySec s, then retrying..."
            Start-Sleep -Seconds $RetryDelaySec
            continue
        }
        Log "LOGIN WALL persisted after $MaxTries attempts. Sending re-login alert."
        $body = @"
The Amazon Business automation could not download today's reports because the
saved login session appears to have expired (login wall persisted after $MaxTries tries).

To fix: re-run the one-time sign-in for the automation Edge profile
($root\login.ps1), then the daily job will resume.

Time: $(Get-Date)
Log:  $log
"@
        & $mailer -To $AlertTo -Subject "ALERT: Amazon automation needs re-login" -Body $body -Attachments @($log)
        exit 2
    }
    break  # got a usable (non-login-wall) result
}

# --- 4. Collect produced zips ---
$ok = @()
$problems = @()
$noOrders = @()
foreach ($span in $Spans) {
    $prop = $manifest.results.PSObject.Properties | Where-Object { $_.Name -eq $span } | Select-Object -First 1
    $r = if ($prop) { $prop.Value } else { $null }
    if ($r -and $r.status -eq "OK" -and $r.path -and (Test-Path $r.path)) {
        $ok += [PSCustomObject]@{ Span = $span; Path = $r.path }
        Log "  $span -> OK ($([math]::Round((Get-Item $r.path).Length/1KB)) KB)"
    } elseif ($r -and $r.status -eq "NO_ORDERS") {
        $noOrders += $span
        Log "  $span -> NO_ORDERS (no orders in range)"
    } else {
        $status = if ($r) { $r.status } else { "MISSING" }
        $problems += "$span=$status"
        Log "  $span -> PROBLEM ($status)"
    }
}

if ($ok.Count -eq 0) {
    if ($problems.Count -eq 0 -and $noOrders.Count -gt 0) {
        # Nothing to send, but it's a clean 'no orders' day -> notify the operator only.
        Log "No orders for: $($noOrders -join ', '). Sending heads-up to $AlertTo (not $To)."
        & $mailer -To $AlertTo -Subject "Amazon automation: no orders for $($noOrders -join ', ') ($(Get-Date -Format 'yyyy-MM-dd'))" `
            -Body "The job ran successfully but there were no orders in the requested range(s): $($noOrders -join ', '). Nothing was sent to the report recipient." -Attachments @($log)
        Log "================ RUN END (no orders) ================"
        exit 0
    }
    Log "ERROR: no zips produced. Problems: $($problems -join ', ')"
    & $mailer -To $AlertTo -Subject "ALERT: Amazon automation produced no files" `
        -Body "No reports were downloaded. Problems: $($problems -join ', '). See attached log." -Attachments @($log)
    exit 3
}

# --- 5. Email ---
$dateLabel = Get-Date -Format "yyyy-MM-dd"
$problemNote = ""
if ($problems.Count -gt 0) { $problemNote = "`r`nNote: some ranges did not download: $($problems -join ', ')." }

if ($PerReceipt) {
    # Expense-matching mode: unzip each range and email every order PDF on its own
    # (1 receipt = 1 email = 1 matchable expense). Dedupes identical order PDFs
    # across overlapping ranges (e.g. 7-day inside 30-day) so a receipt is sent once.
    $extractRoot = Join-Path $root "downloads\receipts"
    $sent = 0; $failed = 0
    $seen = @{}
    foreach ($item in $ok) {
        $safeSpan = $item.Span -replace '[:/\\]', '-'
        $dest = Join-Path $extractRoot ("{0}_{1}" -f $safeSpan, $dateLabel)
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Expand-Archive -Path $item.Path -DestinationPath $dest -Force
        $pdfs = Get-ChildItem $dest -Filter *.pdf | Sort-Object Name
        Log "  $($item.Span): $($pdfs.Count) receipt PDF(s)"
        foreach ($pdf in $pdfs) {
            if ($seen.ContainsKey($pdf.Name)) {
                Log "    skip duplicate: $($pdf.Name)"
                continue
            }
            $seen[$pdf.Name] = $true
            $parts = $pdf.BaseName -split '_'
            $oid = $parts[-1]
            $d = $parts[0]
            $dFmt = if ($d -match '^\d{8}$') { "{0}/{1}/{2}" -f $d.Substring(4, 2), $d.Substring(6, 2), $d.Substring(0, 4) } else { $d }
            $subj = "Amazon order $oid - $dFmt"
            $body = "Amazon order summary receipt. Order $oid, order date $dFmt."
            Log "    emailing receipt $oid ($dFmt) -> $To"
            & $mailer -To $To -Cc $Cc -Subject $subj -Body $body -Attachments @($pdf.FullName)
            if ($LASTEXITCODE -eq 0) { $sent++ } else { $failed++; Log "ERROR: send failed for $($pdf.Name)" }
        }
    }
    Log "Per-receipt: sent $sent email(s), $failed failed."
    if ($sent -eq 0) {
        & $mailer -To $AlertTo -Subject "ALERT: Amazon automation - no receipts emailed" `
            -Body "PerReceipt mode produced no successful sends ($failed failed). See $log." -Attachments @($log)
        exit 3
    }
    if ($failed -gt 0) { Log "================ RUN END (per-receipt, sent=$sent, failed=$failed) ================"; exit 4 }
    Log "================ RUN END (per-receipt, sent=$sent) ================"
    exit 0
}
elseif ($SeparateEmails) {
    foreach ($item in $ok) {
        $subj = "Amazon Orders ($($item.Span)) - $dateLabel"
        $body = "Attached: Amazon Business order documents for $($item.Span), generated $dateLabel.$problemNote"
        Log "Emailing $($item.Span) -> $To"
        & $mailer -To $To -Cc $Cc -Subject $subj -Body $body -Attachments @($item.Path)
        if ($LASTEXITCODE -ne 0) { Log "ERROR: send failed for $($item.Span)" }
    }
} else {
    $attachments = $ok | ForEach-Object { $_.Path }
    $spanList = ($ok | ForEach-Object { $_.Span }) -join ", "
    $subj = "Amazon Orders ($spanList) - $dateLabel"
    $body = "Attached: Amazon Business order documents for: $spanList. Generated $dateLabel.$problemNote"
    Log "Emailing $($attachments.Count) attachment(s) -> $To"
    & $mailer -To $To -Cc $Cc -Subject $subj -Body $body -Attachments $attachments
    if ($LASTEXITCODE -ne 0) { Log "ERROR: send failed" }
}

Log "================ RUN END (ok=$($ok.Count), problems=$($problems.Count)) ================"
if ($problems.Count -gt 0) { exit 4 }
exit 0
