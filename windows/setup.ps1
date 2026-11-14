<#
Windows side of the lab, for WSL mirrored networking. Run from an elevated
PowerShell in this folder (Status/Network need no elevation). setup.cmd runs this
script past the default execution policy (for that run only):

  .\setup.cmd Install                                         # tasks, firewall, power, then checks
  .\setup.cmd Status                                          # read only
  .\setup.cmd Network                                         # read-only JSON evidence
  .\setup.cmd Remove                                          # tasks and firewall rules (power values stay)

Install sets up, idempotently:
- task "WSL2 SSH Service Start": at boot (S4U, no logon needed) and logon, runs
  sshd in the foreground inside WSL, which also keeps WSL running
- task "VMware vmrest API": at boot (S4U), runs vmrest.exe (loopback :8697, account from vmrest.exe -C)
- inbound TCP 22 from the LAN: Windows firewall + Hyper-V firewall (WSL). The
  LAN is detected from the default route (the network other PCs reach this one
  on, and WSL shares it in mirrored mode); -AllowedRemoteAddress overrides it
- power on AC (and battery with -IncludeBattery): no sleep, no hibernation,
  closing the lid does nothing (-SkipPower leaves power settings alone)
- VMware's bridged network (VMnet0, "Automatic", used by VMs with lan = true)
  only on physical adapters: the VMware Bridge Protocol is unbound from
  virtual ones such as WSL's Hyper-V vEthernet, which "Automatic" could pick
Both tasks run system executables (wsl.exe, vmrest.exe), not scripts from
this folder, so the repository can move. It removes what older versions installed (portproxy-era tasks, copies in
%ProgramFiles%\wsl-vmware-lab) and reports ready only after WSL listens on
:22 and vmrest on 127.0.0.1:8697.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('Install', 'Status', 'Network', 'Remove')][string]$Action = 'Status',
    [string]$Distro = 'Ubuntu-24.04',
    [string]$AllowedRemoteAddress,
    [string]$VmrestPath = (Join-Path $env:ProgramFiles 'VMware\VMware Workstation\vmrest.exe'),
    [switch]$IncludeBattery,
    [switch]$SkipPower
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$SshTask = 'WSL2 SSH Service Start'
$VmrestTask = 'VMware vmrest API'
$LegacyTasks = @('WSL2 SSH Port Forward Refresh', 'WSL2 SSH Keepalive')
$LegacyDir = Join-Path $env:ProgramFiles 'wsl-vmware-lab'
$FwRule = 'WSL2 SSH 22'
$FwMarker = 'Managed by wsl-vmware-lab'
$HvRule = 'WSL-SSH-Inbound-TCP22-LAN'
$WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$Wsl = Join-Path $env:WINDIR 'System32\wsl.exe'
$Me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
# Power settings by GUID (powercfg output is localized): value 0 = never / do nothing.
$Power = [ordered]@{
    sleep     = @('SUB_SLEEP', 'STANDBYIDLE')
    hibernate = @('SUB_SLEEP', 'HIBERNATEIDLE')
    lid       = @('4f971e89-eebd-4455-a8de-9e59040e7347', '5ca83367-6e45-459f-a27b-476b1d01c936')
}

function Ok([string]$m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell.' }
}

function Test-Mirrored {
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    return [bool]((Test-Path -LiteralPath $cfg) -and (Select-String -LiteralPath $cfg -Pattern '^\s*networkingMode\s*=\s*mirrored\s*$' -Quiet))
}

function Test-WslSshListening {
    $out = & $Wsl -d $Distro -- ss -Hlnt 2>$null
    return [bool]($LASTEXITCODE -eq 0 -and ($out | Where-Object { $_ -match '\s\S*:22\s' }))
}

function Test-VmrestListening {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort 8697 -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') })
}

function Wait-Until([scriptblock]$Check, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do { if (& $Check) { return $true }; Start-Sleep -Seconds 3 } while ((Get-Date) -lt $deadline)
    return $false
}

function Register-BootTask([string]$Name, [string]$Execute, [string]$Arguments, [string]$Description, [switch]$AtLogon) {
    $taskAction = if ($Arguments) { New-ScheduledTaskAction -Execute $Execute -Argument $Arguments } else { New-ScheduledTaskAction -Execute $Execute -WorkingDirectory (Split-Path -Parent $Execute) }
    $triggers = @(New-ScheduledTaskTrigger -AtStartup)
    if ($AtLogon) { $triggers += New-ScheduledTaskTrigger -AtLogOn -User $Me }
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $Name -Action $taskAction `
        -Trigger $triggers -Principal (New-ScheduledTaskPrincipal -UserId $Me -LogonType S4U -RunLevel Limited) `
        -Settings $settings -Description $Description -Force | Out-Null
    Ok "task '$Name': boot (S4U$(if ($AtLogon) { ' + logon' }))"
}

function Remove-Legacy {
    foreach ($name in $LegacyTasks) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Ok "removed old task '$name'"
        }
    }
    foreach ($file in 'start-vmrest.ps1', 'wsl2-ssh-forward.ps1', 'wsl2-ssh-forward.settings.json') {
        $path = Join-Path $LegacyDir $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Ok "removed old copy $path" }
    }
    if ((Test-Path -LiteralPath $LegacyDir) -and -not (Get-ChildItem -LiteralPath $LegacyDir -Force)) { Remove-Item -LiteralPath $LegacyDir -Force }
    $proxy = (& netsh.exe interface portproxy show v4tov4) -match '^\s*0\.0\.0\.0\s+22\s'
    if ($proxy) { Warn 'a portproxy rule listens on 0.0.0.0:22 (NAT-era); in mirrored mode it collides with WSL sshd: netsh interface portproxy delete v4tov4 listenport=22 listenaddress=0.0.0.0' }
}

function Set-Firewall {
    $rule = @(Get-NetFirewallRule -DisplayName $FwRule -ErrorAction SilentlyContinue)
    if ($rule.Count -eq 0) {
        New-NetFirewallRule -DisplayName $FwRule -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 `
            -Profile Any -RemoteAddress $AllowedRemoteAddress -Description $FwMarker | Out-Null
    } else {
        foreach ($r in $rule) {
            Set-NetFirewallRule -InputObject $r -Enabled True -Profile Any -Description $FwMarker | Out-Null
            $r | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $AllowedRemoteAddress | Out-Null
        }
    }
    Ok "Windows firewall: TCP 22 from $AllowedRemoteAddress"
    if (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        if (Get-NetFirewallHyperVRule -Name $HvRule -ErrorAction SilentlyContinue) {
            Set-NetFirewallHyperVRule -Name $HvRule -Enabled True -Action Allow -Protocol TCP -LocalPorts 22 -RemoteAddresses $AllowedRemoteAddress
        } else {
            New-NetFirewallHyperVRule -Name $HvRule -DisplayName 'WSL SSH inbound TCP 22 (LAN)' -Direction Inbound `
                -VMCreatorId $WslVmCreatorId -Protocol TCP -LocalPorts 22 -RemoteAddresses $AllowedRemoteAddress -Action Allow | Out-Null
        }
        Ok "Hyper-V firewall (WSL): TCP 22 from $AllowedRemoteAddress"
    } else {
        Warn 'Hyper-V firewall cmdlets not available on this build; only the Windows firewall rule was set'
    }
}

function Get-PowerValues {
    $scheme = if (((& powercfg.exe /getactivescheme) -join ' ') -match '([0-9a-fA-F-]{36})') { $Matches[1] } else { throw 'powercfg /getactivescheme failed' }
    $result = [ordered]@{}
    foreach ($k in $Power.Keys) {
        $out = (& powercfg.exe /qh $scheme $Power[$k][0] $Power[$k][1] 2>$null) -join "`n"
        $hex = @([regex]::Matches($out, '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToUInt32($_.Value.Substring(2), 16) })
        $result[$k] = if ($hex.Count -ge 2) { @{ AC = $hex[-2]; DC = $hex[-1] } } else { $null }   # null: no such setting (no lid)
    }
    return $result
}

function Set-Power {
    foreach ($k in $Power.Keys) {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT $Power[$k][0] $Power[$k][1] 0 2>$null | Out-Null
        if ($IncludeBattery) { & powercfg.exe /setdcvalueindex SCHEME_CURRENT $Power[$k][0] $Power[$k][1] 0 2>$null | Out-Null }
    }
    & powercfg.exe /setactive SCHEME_CURRENT
    if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive failed (exit $LASTEXITCODE); Group Policy may manage power settings" }
    Ok "power on AC$(if ($IncludeBattery) { ' and battery' }): no sleep, no hibernation, lid does nothing"
}

# Bindings are candidates for bridging, not proof of Automatic's selection.
# Keep Install's existing policy of removing bindings from virtual adapters.
function Get-BridgeAdapters {
    $physical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -notmatch 'Bluetooth' } | ForEach-Object { $_.Name })
    foreach ($b in @(Get-NetAdapterBinding -ComponentID vmware_bridge -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })) {
        [pscustomobject]@{ Name = $b.Name; Physical = ($physical -contains $b.Name) }
    }
}

function Set-Bridge {
    foreach ($a in @(Get-BridgeAdapters | Where-Object { -not $_.Physical })) {
        Disable-NetAdapterBinding -Name $a.Name -ComponentID vmware_bridge
        Ok "VMware bridge removed from virtual adapter '$($a.Name)'"
    }
    $left = @(Get-BridgeAdapters | ForEach-Object { $_.Name })
    if ($left) { Ok "VMware Bridge Protocol bound to: $($left -join ', ')" }
    else { Warn 'no physical adapter has the VMware Bridge Protocol; VMs with lan = true cannot reach the LAN' }
}

# The IPv4 network of the adapter that carries the default route, e.g.
# 192.168.1.0/24: the LAN other PCs use to reach this one (and WSL, mirrored).
function Get-Lan {
    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if (-not $route) { return $null }
    $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $ip) { return $null }
    $b = ([Net.IPAddress]$ip.IPAddress).GetAddressBytes(); [Array]::Reverse($b)
    $all = [uint64]4294967295   # 0xFFFFFFFF would be read as the Int32 -1
    $mask = ($all -shl (32 - $ip.PrefixLength)) -band $all
    $net = [BitConverter]::GetBytes([uint32]([uint64][BitConverter]::ToUInt32($b, 0) -band $mask)); [Array]::Reverse($net)
    [pscustomobject]@{ Cidr = "$(([Net.IPAddress]$net).IPAddressToString)/$($ip.PrefixLength)"; Address = $ip.IPAddress; Adapter = $ip.InterfaceAlias }
}

# Every evidence item has data + reason. Missing and denied evidence stays
# null, rather than becoming a guessed default. Registry views are explicit:
# Registry64 is primary; Registry32 is supplementary evidence only.
function Read-Evidence([scriptblock]$Read) {
    try {
        $data = & $Read
        if ([object]::ReferenceEquals($data, [System.Management.Automation.Internal.AutomationNull]::Value)) { $data = $null }
        [pscustomobject]@{ data = $data; reason = $null }
    }
    catch { [pscustomobject]@{ data = $null; reason = $_.Exception.Message } }
}

function Read-RegistryTree($Root, [string]$Path) {
    $key = $Root.OpenSubKey($Path, $false)
    if ($null -eq $key) { throw "Registry key missing: $Path" }
    try {
        $values = [ordered]@{}
        foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) }
        # Flat path records retain all subkeys without growing JSON nesting.
        # Registry GetValue returns only strings, numeric values or byte/string arrays.
        [pscustomobject]@{ path = $Path; values = $values; reason = $null }
        foreach ($name in $key.GetSubKeyNames()) {
            $childPath = "$Path\$name"
            try { Read-RegistryTree $Root $childPath }
            catch { [pscustomobject]@{ path = $childPath; values = $null; reason = [string]$_.Exception.Message } }
        }
    } finally { $key.Dispose() }
}

function Read-RegistryValue($Root, [string]$Path, [string]$Name) {
    $key = $Root.OpenSubKey($Path, $false)
    if ($null -eq $key) { throw "Registry key missing: $Path" }
    try {
        if ($key.GetValueNames() -notcontains $Name) { throw "Registry value missing: $Path\$Name" }
        $key.GetValue($Name)
    } finally { $key.Dispose() }
}

function Get-NetworkEvidence {
    $views = [ordered]@{}
    foreach ($view in 'Registry64', 'Registry32') {
        $views[$view] = Read-Evidence {
            $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
            try {
                $config = 'SOFTWARE\VMware, Inc.\VMnetLib\VMnetConfig'
                $vmnets = [ordered]@{}
                # Default numbers first for comparison, never inferred types.
                # Workstation supports VMnet0-19; absent keys retain reasons.
                foreach ($number in @(0, 1, 8) + @(2..7) + @(9..19)) {
                    $path = "$config\vmnet$number"
                    $vmnets["VMnet$number"] = [ordered]@{
                        raw = Read-Evidence { ,@(Read-RegistryTree $root $path) }
                        subnet = Read-Evidence { Read-RegistryValue $root $path 'IPSubnetAddress' }
                        subnetMask = Read-Evidence { Read-RegistryValue $root $path 'IPSubnetMask' }
                        useAdapter = Read-Evidence { Read-RegistryValue $root "$path\Adapter" 'UseAdapter' }
                        useDHCP = Read-Evidence { Read-RegistryValue $root "$path\DHCP" 'UseDHCP' }
                        useNAT = Read-Evidence { Read-RegistryValue $root "$path\NAT" 'UseNAT' }
                        natTCPForwardCount = Read-Evidence {
                            $tcp = $root.OpenSubKey("$path\NAT\TCP", $false)
                            if ($null -eq $tcp) { throw "Registry key missing: $path\NAT\TCP" }
                            try { @($tcp.GetValueNames() | Where-Object { $_ -ne '' }).Count }
                            finally { $tcp.Dispose() }
                        }
                    }
                }
                [pscustomobject]@{
                    vmnets = $vmnets
                    bridgeAdapters = Read-Evidence {
                        ,@(Read-RegistryTree $root 'SYSTEM\CurrentControlSet\Services\VMnetBridge\Parameters\Adapters')
                    }
                }
            } finally { $root.Dispose() }
        }
    }
    [pscustomobject]@{
        # File API returns a plain string, without provider ETS PS* properties.
        netmap = Read-Evidence { [System.IO.File]::ReadAllText((Join-Path $env:ProgramData 'VMware\netmap.conf')) }
        registry = $views
        adapters = Read-Evidence {
            ,@(Get-NetAdapter -IncludeHidden -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name = [string]$_.Name; InterfaceDescription = [string]$_.InterfaceDescription
                    Status = [string]$_.Status; Virtual = [bool]$_.Virtual; HardwareInterface = [bool]$_.HardwareInterface
                }
            })
        }
        physicalAdapters = Read-Evidence {
            ,@(Get-NetAdapter -Physical -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name = [string]$_.Name; InterfaceDescription = [string]$_.InterfaceDescription; Status = [string]$_.Status
                }
            })
        }
        ipConfiguration = Read-Evidence {
            ,@(Get-NetIPConfiguration -All -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    InterfaceAlias = [string]$_.InterfaceAlias
                    InterfaceIndex = [int]$_.InterfaceIndex
                    IPv4Address = @(if ($_.IPv4Address) { $_.IPv4Address | ForEach-Object { [pscustomobject]@{ IPAddress = [string]$_.IPAddress; PrefixLength = [int]$_.PrefixLength } } })
                    IPv6Address = @(if ($_.IPv6Address) { $_.IPv6Address | ForEach-Object { [pscustomobject]@{ IPAddress = [string]$_.IPAddress; PrefixLength = [int]$_.PrefixLength } } })
                    IPv4DefaultGateway = @(if ($_.IPv4DefaultGateway) { $_.IPv4DefaultGateway | ForEach-Object { [pscustomobject]@{ NextHop = [string]$_.NextHop } } })
                    IPv6DefaultGateway = @(if ($_.IPv6DefaultGateway) { $_.IPv6DefaultGateway | ForEach-Object { [pscustomobject]@{ NextHop = [string]$_.NextHop } } })
                    DNSServer = @(if ($_.DNSServer) { $_.DNSServer | ForEach-Object { [pscustomobject]@{ AddressFamily = [int]$_.AddressFamily; ServerAddresses = [string[]]$_.ServerAddresses } } })
                }
            })
        }
        bridgeBindings = Read-Evidence {
            ,@(Get-NetAdapterBinding -IncludeHidden -ComponentID vmware_bridge -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name = [string]$_.Name; InterfaceDescription = [string]$_.InterfaceDescription
                    ComponentID = [string]$_.ComponentID; Enabled = [bool]$_.Enabled
                }
            })
        }
    }
}

function Show-Status {
    $ok = $true
    $lan = Get-Lan
    if ($lan) { Ok "LAN: $($lan.Cidr) ($($lan.Adapter), this PC $($lan.Address))" } else { Warn 'no IPv4 default route: LAN unknown' }
    if (Test-Mirrored) { Ok 'WSL networkingMode=mirrored' } else { Warn 'WSL is not in mirrored mode (.wslconfig: [wsl2] networkingMode=mirrored)'; $ok = $false }
    foreach ($name in $SshTask, $VmrestTask) {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if (-not $t) { Warn "task '$name' absent (run .\setup.cmd Install, elevated)"; $ok = $false; continue }
        $boot = [bool]($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
        $exe = "$($t.Actions[0].Execute) $($t.Actions[0].Arguments)"
        if ($boot -and $t.Principal.LogonType -eq 'S4U' -and $exe -notmatch [regex]::Escape($LegacyDir)) { Ok "task '$name': $($t.State), boot without logon" }
        else { Warn "task '$name' is from an older setup or does not start at boot; run .\setup.cmd Install (elevated)"; $ok = $false }
    }
    foreach ($name in $LegacyTasks) { if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Warn "old task '$name' present; .\setup.cmd Install removes it" } }
    if (Get-NetFirewallRule -DisplayName $FwRule -ErrorAction SilentlyContinue) { Ok "firewall rule '$FwRule' present" } else { Warn "firewall rule '$FwRule' absent"; $ok = $false }
    if (Test-WslSshListening) { Ok 'WSL sshd listens on :22' } else { Warn 'WSL sshd is not listening on :22'; $ok = $false }
    if (Test-VmrestListening) { Ok 'vmrest listens on 127.0.0.1:8697' } else { Warn 'vmrest is not listening on loopback :8697'; $ok = $false }
    $risks = @()
    foreach ($e in (Get-PowerValues).GetEnumerator()) { if ($e.Value -and $e.Value.AC -ne 0) { $risks += $e.Key } }
    if ($risks) { Warn "power on AC still allows: $($risks -join ', ') (Install fixes it unless -SkipPower)" } else { Ok 'power on AC: no sleep, no hibernation, lid does nothing' }
    $bridge = @(Get-BridgeAdapters)
    $virtual = @($bridge | Where-Object { -not $_.Physical } | ForEach-Object { $_.Name })
    if ($virtual) { Warn "VMware bridge also on virtual adapters: $($virtual -join ', ') (VMnet0 Automatic may pick one; Install fixes it)" }
    elseif ($bridge) { Ok "VMware Bridge Protocol bound to: $(($bridge | ForEach-Object { $_.Name }) -join ', ')" }
    return $ok
}

switch ($Action) {
    'Network' {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        # Deepest container: registry/view/data/vmnets/VMnetN/raw/data/[record]/values/[array].
        # Root is depth 0; depth 10 retains registry byte/string arrays. Subkeys are flat path records.
        Get-NetworkEvidence | ConvertTo-Json -Depth 10
        exit 0
    }
    'Status' { if (Show-Status) { exit 0 } else { exit 1 } }
    'Remove' {
        Assert-Admin
        foreach ($name in @($SshTask, $VmrestTask) + $LegacyTasks) {
            if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false; Ok "removed task '$name'" }
        }
        Get-NetFirewallRule -DisplayName $FwRule -ErrorAction SilentlyContinue | Where-Object { $_.Description -in @($FwMarker, 'Managed by wsl2-ssh-forward.ps1') } | Remove-NetFirewallRule
        if (Get-Command Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue) { Remove-NetFirewallHyperVRule -Name $HvRule -ErrorAction SilentlyContinue }
        Ok 'firewall rules removed (power settings left as they are)'
    }
    'Install' {
        Assert-Admin
        if (-not $AllowedRemoteAddress) {
            $lan = Get-Lan
            if (-not $lan) { throw 'Could not detect the LAN (no IPv4 default route); pass -AllowedRemoteAddress, e.g. 192.168.1.0/24.' }
            $script:AllowedRemoteAddress = $lan.Cidr
            Ok "LAN detected: $($lan.Cidr) ($($lan.Adapter), this PC $($lan.Address)); SSH allowed from it (-AllowedRemoteAddress to change)"
        }
        if (-not (Test-Mirrored)) { throw 'WSL must use mirrored networking: add networkingMode=mirrored under [wsl2] in %USERPROFILE%\.wslconfig, then wsl --shutdown.' }
        if (-not (Test-Path -LiteralPath $VmrestPath)) { throw "vmrest not found: $VmrestPath (pass -VmrestPath)" }
        $winSshd = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue |
            Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name -eq 'sshd' }
        if ($winSshd) { throw 'Windows OpenSSH Server holds port 22; stop or move it first (this script does not touch it).' }
        Remove-Legacy
        $sshd = "systemctl stop ssh.socket ssh.service; mkdir -p /run/sshd; exec /usr/sbin/sshd -D -e"
        Register-BootTask -Name $SshTask -Execute $Wsl -Arguments "-d $Distro -u root -- /bin/sh -c `"$sshd`"" -AtLogon `
            -Description 'Run WSL sshd in the foreground (keeps WSL running). wsl-vmware-lab windows\setup.ps1'
        Register-BootTask -Name $VmrestTask -Execute $VmrestPath -Arguments '' `
            -Description 'VMware vmrest on 127.0.0.1:8697 (restarted if it exits). wsl-vmware-lab windows\setup.ps1'
        Set-Firewall
        if (-not $SkipPower) { Set-Power }
        Set-Bridge
        Start-ScheduledTask -TaskName $SshTask
        Start-ScheduledTask -TaskName $VmrestTask
        # Ready means the ports answer, not that a task was started (#18).
        if (-not (Wait-Until { Test-WslSshListening } 45)) { throw "WSL sshd did not listen on :22 within 45 s; check openssh-server in $Distro" }
        Ok 'WSL sshd listens on :22'
            if (-not (Wait-Until { Test-VmrestListening } 30)) { throw 'vmrest did not listen on 127.0.0.1:8697 within 30 s; run vmrest.exe by hand to see its error (account set with vmrest.exe -C?)' }
        Ok 'vmrest listens on 127.0.0.1:8697'
        Ok "ready: tasks also start at boot without logon. Next, from another PC: ssh <wsl-user>@<this PC's IP>"
    }
}
