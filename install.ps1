# install.ps1 - registers the "Monitor Refresh Fix" scheduled task for the current user.
# No admin needed. Re-run any time (e.g. after moving the folder) to update it.

$ErrorActionPreference = 'Stop'
$TaskName = 'Monitor Refresh Fix'
$script   = Join-Path $PSScriptRoot 'fix-refresh.ps1'
$user     = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$xml = Get-Content (Join-Path $PSScriptRoot 'task.xml') -Raw
$xml = $xml.Replace('__SCRIPT__', [Security.SecurityElement]::Escape($script)).Replace('__USER__', [Security.SecurityElement]::Escape($user))

Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
Write-Host "Installed '$TaskName' for $user"
Write-Host "  Runs: 1 min and 3 min after logon, and 30 s after waking from sleep"
Write-Host "  Log:  $env:LOCALAPPDATA\monitor-refresh-fix\log.txt"
