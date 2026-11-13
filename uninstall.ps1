# uninstall.ps1 - removes the "Monitor Refresh Fix" scheduled task. The log folder is left alone.

$TaskName = 'Monitor Refresh Fix'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed '$TaskName'"
} else {
    Write-Host "'$TaskName' is not installed"
}
