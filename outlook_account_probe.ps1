$ol = New-Object -ComObject Outlook.Application
$sess = $ol.Session
Write-Output "DefaultStore=$($sess.DefaultStore.DisplayName)"
Write-Output "DefaultStoreID=$($sess.DefaultStore.StoreID)"
$sentFolder = $sess.GetDefaultFolder(5)
Write-Output "SentFolder=$($sentFolder.FolderPath)"
Write-Output "SentFolderStoreID=$($sentFolder.Store.StoreID)"
foreach ($a in $sess.Accounts) {
    Write-Output "Account=$($a.DisplayName) <$($a.SmtpAddress)>"
    if ($a.DeliveryStore -ne $null) { Write-Output "  DeliveryStore=$($a.DeliveryStore.DisplayName) ID=$($a.DeliveryStore.StoreID)" }
}
