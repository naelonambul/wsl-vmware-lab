# Save beside start-vmrest.ps1, then run in Windows PowerShell.
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'start-vmrest.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw 'Save start-vmrest.ps1 in the same folder first.' }
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $launcher + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'VMware vmrest API' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'VMware vmrest API'
Write-Host '[OK] VMware vmrest API: starts at this user logon; existing process is reused.'
