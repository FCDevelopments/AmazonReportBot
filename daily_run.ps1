<#
    Daily 8 AM entry point (called by the AmazonBusinessDailyReport task).

    1. Ensure Edge is running WITH the debug port (restart it if needed; tabs are
       restored). If the port is already live, Edge is left untouched.
    2. Run the report for YESTERDAY and email it to the receipt-upload address,
       attaching via CDP to your real, signed-in Edge.

    Edit $To / $Spans below to change the daily recipient or range.
#>
$root = "$env:USERPROFILE\AmazonReportBot"  # TODO: set this to your AmazonReportBot install folder
$UploadServiceEmail = "receipts@example.com"    # TODO: set your report/expense-upload destination email
$AlertRecipientEmail = "alerts@example.com"     # TODO: set the address that should receive failure/re-login alerts
$To      = $UploadServiceEmail
$AlertTo = $AlertRecipientEmail

# On Mondays cover the full weekend (Fri + Sat + Sun); otherwise just yesterday.
if ((Get-Date).DayOfWeek -eq 'Monday') {
    $friday = (Get-Date).AddDays(-3).ToString("MM/dd/yyyy")
    $sunday = (Get-Date).AddDays(-1).ToString("MM/dd/yyyy")
    $Spans  = "CUSTOM:$($friday):$($sunday)"
} else {
    $Spans  = "YESTERDAY"
}

# 1. Make Edge attachable (only restarts if the port isn't already up).
& "$root\start_edge.ps1" -Force
Start-Sleep -Seconds 8   # let restored tabs / Amazon session settle

# 2. Download yesterday's orders and email each order summary PDF on its own
#    (1 receipt = 1 email) for the expense-matching system.
& "$root\run_report.ps1" -Spans $Spans -To $To -AlertTo $AlertTo -PerReceipt
exit $LASTEXITCODE
