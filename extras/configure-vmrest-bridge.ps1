#Requires -RunAsAdministrator
<#
Purpose: Let Terraform inside WSL2 NAT reach VMware Workstation's vmrest API.
vmrest itself remains bound to Windows loopback (127.0.0.1:8697).
This adds a host-only proxy on the current WSL gateway and limits inbound
firewall traffic to the current WSL NAT subnet. It does not modify port 22.
#>
[CmdletBinding()]
param(
    # Legacy WSL NAT mode only. Use your WSL gateway IP and NAT subnet,
    # e.g. from `ip route` inside WSL. Not needed with mirrored networking.
    [Parameter(Mandatory = $true)][string]$ListenAddress,
    [Parameter(Mandatory = $true)][string]$WslSubnet,
    [int]$Port = 8697
)

$ErrorActionPreference = 'Stop'
$ruleName = 'WSL NAT vmrest API 8697'
$targetAddress = '127.0.0.1'
$targetPort = 8697

Write-Host "WSL NAT API bridge: ${ListenAddress}:$Port -> ${targetAddress}:$targetPort"
Write-Host "Firewall source scope: $WslSubnet"

$existingText = (& netsh.exe interface portproxy show v4tov4 2>&1 | Out-String)
$existingPattern = '(?m)^\s*' + [regex]::Escape($ListenAddress) + '\s+' + $Port + '\s+(\S+)\s+(\d+)\s*$'
$existingMatch = [regex]::Match($existingText, $existingPattern)
if ($existingMatch.Success) {
    if ($existingMatch.Groups[1].Value -ne $targetAddress -or
        [int]$existingMatch.Groups[2].Value -ne $targetPort) {
        throw "A different portproxy already uses ${ListenAddress}:$Port. No changes made."
    }
} else {
    & netsh.exe interface portproxy add v4tov4 listenaddress=$ListenAddress listenport=$Port connectaddress=$targetAddress connectport=$targetPort | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'netsh could not add the vmrest portproxy.' }
}

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
    -LocalAddress $ListenAddress -LocalPort $Port -RemoteAddress $WslSubnet -Profile Any | Out-Null

Write-Host '[OK] WSL-only vmrest bridge configured.'
Write-Host '[OK] Existing Windows port 22 mapping was left untouched.'
