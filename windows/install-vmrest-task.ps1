# Register "VMware vmrest API": starts vmrest at Windows BOOT, before anyone
# logs on, as the current Windows user (the owner of vmrest.cfg and the VM
# inventory). Run from an elevated PowerShell, with start-vmrest.ps1 beside it:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-vmrest-task.ps1
# Keep this folder in place afterwards; the task runs start-vmrest.ps1 from here.
#requires -Version 5.1
#requires -RunAsAdministrator
param(
    # Windows account that owns the vmrest account and VMs. Default: current user.
    [string]$User = [Security.Principal.WindowsIdentity]::GetCurrent().Name,
    # vmrest.exe location, passed to start-vmrest.ps1. Change if Workstation is installed elsewhere.
    [string]$VmrestPath = (Join-Path $env:ProgramFiles 'VMware\VMware Workstation\vmrest.exe')
)
$ErrorActionPreference = 'Stop'
$taskName = 'VMware vmrest API'
$launcher = Join-Path $PSScriptRoot 'start-vmrest.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw 'Save start-vmrest.ps1 in the same folder first.' }
if (-not (Test-Path -LiteralPath $VmrestPath)) { throw "vmrest not found: $VmrestPath (pass -VmrestPath)" }

$action = New-ScheduledTaskAction `
    -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $launcher + '" -VmrestPath "' + $VmrestPath + '"')
$trigger = New-ScheduledTaskTrigger -AtStartup
# S4U: runs whether or not the user is logged on, without storing a password.
# Limited: vmrest needs no administrator rights.
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited
# No time limit; restart up to 5 times, 1 minute apart, if vmrest exits.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

# Other tasks that also launch vmrest would compete with this one; report them.
Get-ScheduledTask | Where-Object {
    $_.TaskName -ne $taskName -and $_.Settings.Enabled -and
    ($_.Actions | Where-Object { "$($_.Execute) $($_.Arguments)" -match 'vmrest' })
} | ForEach-Object { Write-Warning "Another enabled task also starts vmrest: $($_.TaskName). Disable it to avoid two launchers." }

Start-ScheduledTask -TaskName $taskName
Write-Host "[OK] $taskName : starts at boot as $User (S4U) with $VmrestPath; an already running vmrest of this user is supervised and restarted if it exits."
