$outlook = New-Object -ComObject Outlook.Application
$sess = $outlook.Session
Write-Output "CurrentUser=$($sess.CurrentUser.Name)"
Write-Output "DefaultStore=$($sess.DefaultStore.DisplayName)"
$accounts = $sess.Accounts
for ($i = 1; $i -le $accounts.Count; $i++) {
    $a = $accounts.Item($i)
    Write-Output "Account=$($a.DisplayName) <$($a.SmtpAddress)>"
}
$sent = $sess.GetDefaultFolder(5)
Write-Output "SentFolder=$($sent.FolderPath)"
