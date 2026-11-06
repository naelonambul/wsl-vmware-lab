# Undo configure-vmrest-bridge.ps1 (legacy WSL NAT mode).
param([Parameter(Mandatory = $true)][string]$ListenAddress, [int]$Port = 8697)
netsh.exe interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$Port
Get-NetFirewallRule -DisplayName 'WSL NAT vmrest API 8697' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
