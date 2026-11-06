# Start VMware Workstation REST API after this Windows user logs on.
# The existing vmrest credentials are reused. The API stays on loopback.
# Manual use: powershell.exe -NoProfile -File .\start-vmrest.ps1
#requires -Version 5.1
param(
    # Change if Workstation is installed elsewhere.
    [string]$VmrestPath = (Join-Path $env:ProgramFiles 'VMware\VMware Workstation\vmrest.exe')
)
$ErrorActionPreference = 'Stop'
$exe = $VmrestPath
if (-not (Test-Path -LiteralPath $exe)) { throw "vmrest not found: $exe" }
if (Get-Process -Name vmrest -ErrorAction SilentlyContinue) { exit 0 }
$logDirectory = Join-Path $env:LOCALAPPDATA 'WSL-VMware'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logDirectory 'vmrest.log') `
    -RedirectStandardError (Join-Path $logDirectory 'vmrest-error.log')
Start-Sleep -Seconds 2
if (-not (Get-Process -Name vmrest -ErrorAction SilentlyContinue)) {
    throw "vmrest exited. Check logs: $logDirectory"
}
