<#
    Sends an email with attachment(s) via the classic Outlook desktop app (COM).
    Uses the user's default Outlook profile/account.

    Example:
      .\send_email.ps1 -To "recipient@example.com" `
                       -Subject "Amazon Orders - Past 7 days" `
                       -Body "See attached." `
                       -Attachments "C:\path\a.zip","C:\path\b.zip"

    Exit codes: 0 = sent, 1 = error.
#>
param(
    [Parameter(Mandatory = $true)] [string]   $To,
    [string]   $Subject = "Amazon Business Report",
    [string]   $Body    = "",
    [Parameter(Mandatory = $true)] [string[]] $Attachments,
    [string]   $Cc = ""
)

$ErrorActionPreference = "Stop"

# Validate attachments exist
$missing = @($Attachments | Where-Object { -not (Test-Path $_) })
if ($missing.Count -gt 0) {
    Write-Error "Attachment(s) not found: $($missing -join ', ')"
    exit 1
}

try {
    $outlook = New-Object -ComObject Outlook.Application
    $session = $outlook.Session
    $mail = $outlook.CreateItem(0)   # 0 = olMailItem
    $store = $session.DefaultStore
    $sentFolder = $null
    if ($store) { $sentFolder = $store.GetDefaultFolder(5) }
    if ($sentFolder) { $mail.SaveSentMessageFolder = $sentFolder }

    $account = $null
    foreach ($acc in $session.Accounts) {
        if ($acc.DeliveryStore -ne $null -and $store -ne $null -and $acc.DeliveryStore.StoreID -eq $store.StoreID) {
            $account = $acc
            break
        }
    }
    if (-not $account -and $session.Accounts.Count -gt 0) {
        $account = $session.Accounts.Item(1)
    }
    if ($account) { $mail.SendUsingAccount = $account }

    $mail.To = $To
    if ($Cc) { $mail.CC = $Cc }
    $mail.Subject = $Subject
    $mail.Body = $Body
    foreach ($a in $Attachments) {
        $full = (Resolve-Path $a).Path
        [void]$mail.Attachments.Add($full)
    }
    $mail.Send()

    $savedFolderPath = if ($sentFolder) { $sentFolder.FolderPath } else { '<none>' }
    $usedAccount = if ($account) { $account.DisplayName + ' <' + $account.SmtpAddress + '>' } else { '<none>' }
    Write-Output "SENT to '$To' | subject='$Subject' | attachments=$($Attachments.Count) | saved_to='$savedFolderPath' | account='$usedAccount'"
    exit 0
}
catch {
    Write-Error "Outlook send failed: $($_.Exception.Message)"
    exit 1
}
