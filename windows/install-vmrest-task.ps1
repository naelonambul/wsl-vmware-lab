# Register "VMware vmrest API": starts vmrest at Windows BOOT, before anyone
# logs on, as the current Windows user (the owner of vmrest.cfg and the VM
# inventory). Run from an elevated PowerShell, with start-vmrest.ps1 beside it:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-vmrest-task.ps1
# start-vmrest.ps1 is copied to %ProgramFiles%\wsl-vmware-lab and the task runs
# that copy; re-run this script after updating the repository.
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
$source = Join-Path $PSScriptRoot 'start-vmrest.ps1'
if (-not (Test-Path -LiteralPath $source)) { throw 'Save start-vmrest.ps1 in the same folder first.' }
if (-not (Test-Path -LiteralPath $VmrestPath)) { throw "vmrest not found: $VmrestPath (pass -VmrestPath)" }

# Scheduled tasks must not run a script that a non-administrator can change:
# the task would run the edited code with the task's rights. Tasks therefore
# run a copy in %ProgramFiles%\wsl-vmware-lab, writable only by SYSTEM,
# Administrators and TrustedInstaller. Re-run the install after updating the
# repository to refresh the copy.
$script:ProtectedDir = Join-Path $env:ProgramFiles 'wsl-vmware-lab'

function Assert-AdminOnlyWritable {
    param([Parameter(Mandatory = $true)][string]$Path)
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    # Specific write rights plus GENERIC_ALL (0x10000000) and GENERIC_WRITE (0x40000000).
    $mask = [int][Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership' -bor 0x50000000
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($trusted -notcontains $owner) {
        throw "$Path is owned by $owner, not Administrators/SYSTEM; refusing to use it for a scheduled task."
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ((([int]$rule.FileSystemRights) -band $mask) -and ($trusted -notcontains $rule.IdentityReference.Value)) {
            $name = $rule.IdentityReference.Value
            try { $name = $rule.IdentityReference.Translate([Security.Principal.NTAccount]).Value } catch { }
            throw "$Path can be changed by $name; refusing to use it for a scheduled task."
        }
    }
}

function Install-ProtectedScript {
    param([Parameter(Mandatory = $true)][string]$Source)
    $dest = Join-Path $script:ProtectedDir (Split-Path -Leaf $Source)
    New-Item -ItemType Directory -Path $script:ProtectedDir -Force | Out-Null
    Assert-AdminOnlyWritable -Path $script:ProtectedDir
    if ((Resolve-Path -LiteralPath $Source).Path -ne $dest) {
        Copy-Item -LiteralPath $Source -Destination $dest -Force
    }
    Assert-AdminOnlyWritable -Path $dest
    $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
    Write-Host "[OK] Installed $dest (SHA-256 $hash)" -ForegroundColor Green
    return $dest
}

$launcher = Install-ProtectedScript -Source $source

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
