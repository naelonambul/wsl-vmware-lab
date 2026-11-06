# Start the VMware Workstation REST API (vmrest) for this Windows user.
# Run by the "VMware vmrest API" startup task (see install-vmrest-task.ps1):
# it stays running while vmrest runs, so the task's restart-on-failure policy
# brings vmrest back if it exits. The API stays on loopback; the existing
# vmrest account (vmrest.exe -C, vmrest.cfg in this user's profile) is reused.
# Manual one-off start that returns immediately:
#   powershell.exe -NoProfile -File .\start-vmrest.ps1 -NoWait
#requires -Version 5.1
param(
    # Change if Workstation is installed elsewhere.
    [string]$VmrestPath = (Join-Path $env:ProgramFiles 'VMware\VMware Workstation\vmrest.exe'),
    # Return after starting instead of waiting for vmrest to exit.
    [switch]$NoWait
)
$ErrorActionPreference = 'Stop'
$exe = $VmrestPath
if (-not (Test-Path -LiteralPath $exe)) { throw "vmrest not found: $exe" }
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$existing = @(Get-CimInstance Win32_Process -Filter "Name = 'vmrest.exe'" -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
    $proc = $existing[0]
    $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction SilentlyContinue
    $ownerName = if ($owner -and $owner.User) { "$($owner.Domain)\$($owner.User)" } else { '' }
    if ($ownerName -and $ownerName -ne $me) {
        throw "vmrest (PID $($proc.ProcessId)) runs as $ownerName, not $me; it uses another vmrest.cfg and VM inventory. Stop it first."
    }
    if ($proc.ExecutablePath -and ($proc.ExecutablePath -ne (Resolve-Path -LiteralPath $exe).Path)) {
        Write-Warning "Running vmrest is $($proc.ExecutablePath), expected $exe."
    }
    if ($NoWait) { exit 0 }
    # Supervise the vmrest that is already running: when it exits, report failure so the task restarts it.
    Wait-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
    Write-Error "vmrest (PID $($proc.ProcessId), started before this task) exited."
    exit 1
}
$logDirectory = Join-Path $env:LOCALAPPDATA 'WSL-VMware'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$process = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) `
    -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $logDirectory 'vmrest.log') `
    -RedirectStandardError (Join-Path $logDirectory 'vmrest-error.log')
Start-Sleep -Seconds 2
if ($process.HasExited) {
    throw "vmrest exited. Check logs: $logDirectory"
}
if ($NoWait) { exit 0 }
# Supervised mode: a vmrest exit is reported as failure so the task restarts it.
$process.WaitForExit()
Write-Error "vmrest exited with code $($process.ExitCode). Check logs: $logDirectory"
exit 1
