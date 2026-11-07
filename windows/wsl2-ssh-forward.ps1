#requires -Version 5.1
<#
.SYNOPSIS
  Keep WSL SSH reachable from the LAN. Uses portproxy for NAT and direct access for mirrored mode.

.USAGE
  .\wsl2-ssh-forward.ps1 Install [-Distro Ubuntu-24.04] [-AllowedRemoteAddress 192.168.0.0/24]
  .\wsl2-ssh-forward.ps1 Refresh
  .\wsl2-ssh-forward.ps1 Status
  .\wsl2-ssh-forward.ps1 Remove
  .\wsl2-ssh-forward.ps1 InstallTask [-Distro Ubuntu-24.04] [-AllowedRemoteAddress 192.168.0.0/24]
  .\wsl2-ssh-forward.ps1 RemoveTask
  StartSsh is an internal Scheduled Task action.
  Install and InstallTask save -Distro and -AllowedRemoteAddress; later runs without them
  reuse the saved values (%ProgramFiles%\wsl-vmware-lab\wsl2-ssh-forward.settings.json).
  InstallTask copies this script to %ProgramFiles%\wsl-vmware-lab and the tasks run that copy;
  re-run InstallTask after updating the repository.

.STRUCTURE
  NAT: Windows 0.0.0.0:22 -> current WSL IPv4:22 -> sshd
  Mirrored: Windows and WSL share an IP; sshd is reached directly and no portproxy is used.
    A Hyper-V firewall rule for the WSL VM allows TCP 22 from the allowed range.
  InstallTask creates tasks for this Windows account that run at Windows boot without logon (S4U)
  and again at logon: one refreshes forwarding, one keeps the WSL sshd running.
  The keep-alive task is the only thing that starts sshd once it is installed.
  No sleep process is used.
  This script manages TCP 22 only and does not change RDP's TCP 3306 settings.

.NOTES
  WSL2 NAT IP may change after `wsl --shutdown` or a Windows restart; run Refresh.
  The tasks start at boot, before anyone logs on, and again at logon.
  Only the 0.0.0.0:22 portproxy rule is managed; other :22 rules are reported and left alone.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Install', 'Refresh', 'Status', 'Remove', 'InstallTask', 'RemoveTask', 'StartSsh', 'Keepalive')]
    [string]$Action = 'Status',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Distro = 'Ubuntu-24.04',

    # LAN range allowed to reach TCP 22. Change it to your own subnet.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AllowedRemoteAddress = '192.168.0.0/24'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

$script:InstalledScript = Join-Path $script:ProtectedDir 'wsl2-ssh-forward.ps1'
$script:SettingsPath = Join-Path $script:ProtectedDir 'wsl2-ssh-forward.settings.json'
# Older versions kept settings here, where any user can write; no longer read.
$script:LegacySettingsPath = Join-Path $env:ProgramData 'wsl2-ssh-forward\settings.json'
if ($Action -notin @('Install', 'InstallTask') -and (Test-Path -LiteralPath $script:SettingsPath)) {
    try {
        $saved = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $PSBoundParameters.ContainsKey('Distro') -and $saved.Distro) { $Distro = [string]$saved.Distro }
        if (-not $PSBoundParameters.ContainsKey('AllowedRemoteAddress') -and $saved.AllowedRemoteAddress) {
            $AllowedRemoteAddress = [string]$saved.AllowedRemoteAddress
        }
    }
    catch {
        Write-Host "[WARN] Could not read saved settings ($($script:SettingsPath)): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$script:ListenAddress = '0.0.0.0'
$script:SshPort = 22
$script:FirewallRuleName = 'WSL2 SSH 22'
$script:FirewallRuleMarker = 'Managed by wsl2-ssh-forward.ps1'
$script:HyperVRuleName = 'WSL-SSH-Inbound-TCP22-LAN'
$script:WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$script:AllowedRemoteAddress = $AllowedRemoteAddress
$script:TaskName = 'WSL2 SSH Port Forward Refresh'
$script:KeepaliveTaskName = 'WSL2 SSH Keepalive'
$script:SshStartTaskName = 'WSL2 SSH Service Start'
$script:ErrorLogPath = Join-Path $env:LOCALAPPDATA 'wsl2-ssh-forward.log'

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw 'Administrator rights are required. Reopen PowerShell with "Run as administrator" and retry.'
    }
}

function Invoke-Netsh {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& netsh.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (@($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "exit code $exitCode"
        }
        throw "netsh failed: $detail"
    }
    return @($output | ForEach-Object { $_.ToString() })
}

function Get-PortProxyEntries {
    # Parse only the numeric v4tov4 table rows; headings vary with Windows language.
    $lines = Invoke-Netsh -Arguments @('interface', 'portproxy', 'show', 'v4tov4')
    $entries = @()
    foreach ($line in $lines) {
        if ([string]$line -match '^\s*(?<ListenAddress>[^\s]+)\s+(?<ListenPort>\d+)\s+(?<ConnectAddress>[^\s]+)\s+(?<ConnectPort>\d+)\s*$') {
            $listenAddress = $Matches['ListenAddress']
            $connectAddress = $Matches['ConnectAddress']
            $listenPort = [int]$Matches['ListenPort']
            $connectPort = [int]$Matches['ConnectPort']
            if ($listenAddress -match '^[A-Za-z0-9_.-]+$' -and
                $connectAddress -match '^[A-Za-z0-9_.-]+$' -and
                $listenPort -ge 1 -and $listenPort -le 65535 -and
                $connectPort -ge 1 -and $connectPort -le 65535) {
                $entries += [pscustomobject]@{
                    ListenAddress  = $listenAddress
                    ListenPort     = $listenPort
                    ConnectAddress = $connectAddress
                    ConnectPort    = $connectPort
                }
            }
        }
    }
    return $entries
}

function Get-WslIPv4 {
    # At boot WSL may not have an address yet; retry for up to about 30 seconds.
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try { return (Get-WslIPv4Once) }
        catch {
            if ($attempt -eq 6) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Get-WslIPv4Once {
    $output = @(& wsl.exe -d $Distro hostname -I 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (@($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "wsl.exe exited with code $exitCode"
        }
        throw "Could not query WSL distribution '$Distro': $detail"
    }

    $text = (@($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
    foreach ($candidate in ($text -split '\s+')) {
        if ($candidate -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') {
            continue
        }
        $parsedAddress = $null
        if ([System.Net.IPAddress]::TryParse($candidate, [ref]$parsedAddress) -and
            $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $candidate
        }
    }
    throw "No valid IPv4 address was found in: wsl.exe -d $Distro hostname -I"
}

function Test-WslMirroredAddress {
    param([Parameter(Mandatory = $true)][string]$WslIPv4)

    $hostAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -eq $WslIPv4 })
    return ($hostAddresses.Count -gt 0)
}

function Get-WslSshStatus {
    try {
        $output = @(& wsl.exe -d $Distro -- ss -lnt 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $detail = (@($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
            return [pscustomobject]@{
                Available = $false
                Listening = $false
                Detail    = $detail
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            Listening = $false
            Detail    = $_.Exception.Message
        }
    }

    foreach ($line in $output) {
        $columns = @(([string]$line).Trim() -split '\s+')
        if ($columns.Count -ge 5 -and $columns[0] -eq 'LISTEN' -and $columns[3] -match ':22$') {
            return [pscustomobject]@{
                Available = $true
                Listening = $true
                Detail    = ''
            }
        }
    }
    return [pscustomobject]@{
        Available = $true
        Listening = $false
        Detail    = ''
    }
}

function Show-SshInstallInstructions {
    Write-Host '       In WSL, run:'
    Write-Host '       sudo apt update'
    Write-Host '       sudo apt install -y openssh-server'
    Write-Host '       sudo systemctl enable --now ssh'
}

function Start-WslSshService {
    $wslExe = Join-Path $env:WINDIR 'System32\wsl.exe'
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& $wslExe -d $Distro -u root -- /usr/bin/systemctl enable --now ssh 2>&1)
    $ErrorActionPreference = $savedPreference
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (@($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
        if ($detail) { Write-Warn $detail }
        Show-SshInstallInstructions
        throw "Could not start the SSH service in '$Distro'."
    }

    $sshStatus = Get-WslSshStatus
    if (-not $sshStatus.Available -or -not $sshStatus.Listening) {
        if ($sshStatus.Detail) { Write-Warn $sshStatus.Detail }
        Show-SshInstallInstructions
        throw "SSH did not start listening on TCP 22 in '$Distro'."
    }
    Write-Ok "WSL SSH service active: TCP :22 LISTEN ($Distro)"
}

function Save-Settings {
    # The elevated refresh task reads these values, so they live in the
    # administrator-only folder too.
    New-Item -ItemType Directory -Force -Path $script:ProtectedDir | Out-Null
    Assert-AdminOnlyWritable -Path $script:ProtectedDir
    $json = [ordered]@{ Distro = $Distro; AllowedRemoteAddress = $script:AllowedRemoteAddress } | ConvertTo-Json
    [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Assert-AdminOnlyWritable -Path $script:SettingsPath
    Write-Ok "Saved settings: Distro=$Distro, AllowedRemoteAddress=$($script:AllowedRemoteAddress)"
    if (Test-Path -LiteralPath $script:LegacySettingsPath) {
        Remove-Item -LiteralPath $script:LegacySettingsPath -Force
        $legacyDir = Split-Path -Parent $script:LegacySettingsPath
        if (-not (Get-ChildItem -LiteralPath $legacyDir -Force)) { Remove-Item -LiteralPath $legacyDir -Force }
        Write-Ok "Removed old settings file: $($script:LegacySettingsPath)"
    }
}

function Wait-WslSshListening {
    param([int]$TimeoutSeconds = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $status = Get-WslSshStatus
        if ($status.Available -and $status.Listening) { return $true }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Ensure-WslSshRunning {
    # Once the keep-alive task exists it owns sshd; do not start a second (systemd) sshd next to it.
    $task = Get-ScheduledTask -TaskName $script:SshStartTaskName -ErrorAction SilentlyContinue
    if ($task) {
        if ($task.State -ne 'Running') {
            Start-ScheduledTask -TaskName $script:SshStartTaskName -ErrorAction Stop
            Write-Ok "Started Scheduled Task: $($script:SshStartTaskName)"
        }
        if (-not (Wait-WslSshListening)) {
            Show-SshInstallInstructions
            throw "SSH did not start listening on TCP 22 in '$Distro' (task '$($script:SshStartTaskName)')."
        }
        $task = Get-ScheduledTask -TaskName $script:SshStartTaskName -ErrorAction Stop
        if ($task.State -ne 'Running') {
            throw "Task '$($script:SshStartTaskName)' is not running although :22 is open; another sshd may own the port."
        }
        Write-Ok "WSL SSH active: TCP :22 LISTEN, kept running by '$($script:SshStartTaskName)' ($Distro)"
        return
    }
    Start-WslSshService
}

function Test-HyperVFirewallSupported {
    return [bool](Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)
}

function Ensure-HyperVFirewallRule {
    if (-not (Test-HyperVFirewallSupported)) {
        Write-Warn 'Hyper-V firewall cmdlets are not available on this Windows build; only the Windows firewall rule was set.'
        return
    }
    $rule = Get-NetFirewallHyperVRule -Name $script:HyperVRuleName -ErrorAction SilentlyContinue
    if ($rule) {
        Set-NetFirewallHyperVRule -Name $script:HyperVRuleName -Enabled True -Action Allow `
            -Protocol TCP -LocalPorts $script:SshPort -RemoteAddresses $script:AllowedRemoteAddress -ErrorAction Stop
        Write-Ok "Hyper-V firewall rule updated: TCP :22 from $($script:AllowedRemoteAddress) to WSL"
        return
    }
    New-NetFirewallHyperVRule -Name $script:HyperVRuleName -DisplayName 'WSL SSH inbound TCP 22 (LAN)' `
        -Direction Inbound -VMCreatorId $script:WslVmCreatorId -Protocol TCP -LocalPorts $script:SshPort `
        -RemoteAddresses $script:AllowedRemoteAddress -Action Allow -ErrorAction Stop | Out-Null
    Write-Ok "Hyper-V firewall rule created: TCP :22 from $($script:AllowedRemoteAddress) to WSL"
}

function Remove-HyperVFirewallRule {
    if (-not (Test-HyperVFirewallSupported)) { return }
    if (Get-NetFirewallHyperVRule -Name $script:HyperVRuleName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallHyperVRule -Name $script:HyperVRuleName -ErrorAction Stop
        Write-Ok "Hyper-V firewall rule removed: $($script:HyperVRuleName)"
    }
}

function Get-ProcessInfoForId {
    param([int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return [pscustomobject]@{
            Name = $process.ProcessName
            Path = [string]$process.Path
        }
    }
    catch {
        return [pscustomobject]@{
            Name = 'unknown process'
            Path = ''
        }
    }
}

function Get-ProcessNameForId {
    param([int]$ProcessId)
    return (Get-ProcessInfoForId -ProcessId $ProcessId).Name
}

function Test-WslLoopbackForwarder {
    param(
        [string]$ProcessName,
        [string]$ProcessPath,
        [string]$LocalAddress
    )

    if ($LocalAddress -notin @('127.0.0.1', '::1') -or
        $ProcessName -notin @('wslrelay', 'wslhost') -or
        [string]::IsNullOrWhiteSpace($ProcessPath)) {
        return $false
    }

    $executableName = [System.IO.Path]::GetFileName($ProcessPath)
    return $executableName -ieq ($ProcessName + '.exe')
}

function Assert-Port22Available {
    param([object[]]$ExistingProxyEntries)

    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $script:SshPort -ErrorAction SilentlyContinue)
    }
    catch {
        throw "Could not inspect Windows TCP port 22: $($_.Exception.Message)"
    }

    foreach ($listener in $listeners) {
        $processId = [int]$listener.OwningProcess
        $processInfo = Get-ProcessInfoForId -ProcessId $processId
        $processName = $processInfo.Name
        $isExistingPortProxy = $false
        if ($null -ne $ExistingProxyEntries) {
            foreach ($entry in $ExistingProxyEntries) {
                if ($entry.ListenPort -eq $script:SshPort -and $entry.ListenAddress -eq $listener.LocalAddress) {
                    if ($processId -eq 4) {
                        $isExistingPortProxy = $true
                        break
                    }
                    if ($processName -ieq 'svchost') {
                        $ipHelperService = @(Get-CimInstance -ClassName Win32_Service `
                            -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -eq 'iphlpsvc' })
                        if ($ipHelperService.Count -gt 0) {
                            $isExistingPortProxy = $true
                            break
                        }
                    }
                }
            }
        }

        if ($isExistingPortProxy) {
            continue
        }

        # WSL's built-in localhost forwarding uses a relay on loopback; it is distinct from Windows sshd.
        if (Test-WslLoopbackForwarder -ProcessName $processInfo.Name -ProcessPath $processInfo.Path -LocalAddress $listener.LocalAddress) {
            Write-Ok "WSL localhost forwarder detected on $($listener.LocalAddress):22; continuing"
            continue
        }

        if ($processName -ieq 'sshd') {
            throw "Windows OpenSSH Server (sshd.exe, PID $processId) is using $($listener.LocalAddress):22. Stop it manually or choose another port; this script will not stop the service."
        }
        throw "Windows TCP port 22 is already in use by $processName (PID $processId) at $($listener.LocalAddress):22. No portproxy or firewall changes were made."
    }
}

function Get-FirewallRules {
    return @(Get-NetFirewallRule -ErrorAction Stop |
        Where-Object { $_.DisplayName -ceq $script:FirewallRuleName })
}

function Ensure-FirewallRule {
    $existingRules = @(Get-FirewallRules)
    if ($existingRules.Count -gt 0) {
        $ownedRules = @($existingRules | Where-Object { $_.Description -ceq $script:FirewallRuleMarker })
        if ($ownedRules.Count -eq 0) {
            Write-Warn "Same-name firewall rule is not managed by this script; left unchanged."
            return
        }

        foreach ($rule in $ownedRules) {
            Set-NetFirewallRule -InputObject $rule -Enabled True -Profile Any -ErrorAction Stop | Out-Null
            $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter `
                -RemoteAddress $script:AllowedRemoteAddress -ErrorAction Stop | Out-Null
        }
        if ($existingRules.Count -gt 1) {
            Write-Warn "Multiple '$($script:FirewallRuleName)' rules exist; managed rule updated without adding another."
        }
        Write-Ok "Firewall rule allows TCP :22 from $($script:AllowedRemoteAddress)"
        return
    }

    New-NetFirewallRule -DisplayName $script:FirewallRuleName `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $script:SshPort `
        -Profile Any -RemoteAddress $script:AllowedRemoteAddress `
        -Description $script:FirewallRuleMarker | Out-Null
    Write-Ok "Firewall rule created for TCP :22 from $($script:AllowedRemoteAddress)"
}

function Remove-PortProxy22 {
    # Only the rule this script manages (0.0.0.0:22); report others instead of deleting them.
    $all = @(Get-PortProxyEntries | Where-Object { $_.ListenPort -eq $script:SshPort })
    foreach ($other in @($all | Where-Object { $_.ListenAddress -ne $script:ListenAddress })) {
        Write-Warn "Other :22 portproxy left unchanged: $($other.ListenAddress):22 -> $($other.ConnectAddress):$($other.ConnectPort)"
    }
    $entries = @($all | Where-Object { $_.ListenAddress -eq $script:ListenAddress })
    foreach ($entry in $entries) {
        Invoke-Netsh -Arguments @(
            'interface', 'portproxy', 'delete', 'v4tov4',
            "listenport=$($entry.ListenPort)", "listenaddress=$($entry.ListenAddress)"
        ) | Out-Null
    }
    return $entries.Count
}

function Set-SshPortProxy {
    $wslIp = Get-WslIPv4
    Write-Ok "WSL IP: $wslIp"

    $existingEntries = @(Get-PortProxyEntries)
    Assert-Port22Available -ExistingProxyEntries $existingEntries

    if (Test-WslMirroredAddress -WslIPv4 $wslIp) {
        $removedCount = Remove-PortProxy22
        if ($removedCount -gt 0) {
            Write-Ok 'Removed stale :22 portproxy (mirrored mode shares the Windows IP)'
        }
        Write-Ok 'Mirrored mode: WSL SSH is reached directly; no portproxy is needed'
        Ensure-FirewallRule
        Ensure-HyperVFirewallRule
        return
    }

    Remove-PortProxy22 | Out-Null

    Invoke-Netsh -Arguments @(
        'interface', 'portproxy', 'add', 'v4tov4',
        "listenport=$($script:SshPort)", "listenaddress=$($script:ListenAddress)",
        "connectport=$($script:SshPort)", "connectaddress=$wslIp"
    ) | Out-Null

    $finalEntry = @(Get-PortProxyEntries | Where-Object {
        $_.ListenAddress -eq $script:ListenAddress -and
        $_.ListenPort -eq $script:SshPort -and
        $_.ConnectAddress -eq $wslIp -and
        $_.ConnectPort -eq $script:SshPort
    })
    if ($finalEntry.Count -ne 1) {
        throw 'Could not verify the Windows :22 -> WSL :22 portproxy after creation.'
    }

    Ensure-FirewallRule
    Write-Ok "Windows :22 -> WSL $($wslIp):22"
}

function Show-Status {
    Write-Host "WSL distribution : $Distro"
    if (Test-Path -LiteralPath $script:InstalledScript) {
        $installedHash = (Get-FileHash -LiteralPath $script:InstalledScript -Algorithm SHA256).Hash
        if ($PSCommandPath -and $PSCommandPath -ne $script:InstalledScript -and
            (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -ne $installedHash) {
            Write-Warn "Task script $($script:InstalledScript) differs from $PSCommandPath; re-run InstallTask (elevated) to update it"
        }
        else {
            Write-Ok "Task script: $($script:InstalledScript)"
        }
    }
    else {
        Write-Warn "Task script not installed ($($script:InstalledScript)); run InstallTask (elevated)"
    }

    $mirrored = $false
    try {
        $wslIp = Get-WslIPv4
        Write-Ok "WSL IP: $wslIp"
        $mirrored = Test-WslMirroredAddress -WslIPv4 $wslIp
        if ($mirrored) {
            Write-Ok 'WSL networking: mirrored (shares a Windows IPv4 address)'
        }
    }
    catch {
        $wslIp = $null
        Write-Warn "WSL IP unavailable: $($_.Exception.Message)"
    }

    try {
        $entries = @(Get-PortProxyEntries | Where-Object { $_.ListenPort -eq $script:SshPort })
        if ($entries.Count -eq 0 -and $mirrored) {
            Write-Ok 'Windows portproxy :22 not required in mirrored mode'
        }
        elseif ($entries.Count -eq 0) {
            Write-Warn 'Windows portproxy :22 not found'
        }
        else {
            foreach ($entry in $entries) {
                Write-Ok "Windows portproxy: $($entry.ListenAddress):22 -> $($entry.ConnectAddress):$($entry.ConnectPort)"
            }
        }
    }
    catch {
        Write-Warn "Could not read Windows portproxy: $($_.Exception.Message)"
    }

    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $script:SshPort -ErrorAction SilentlyContinue)
        if ($listeners.Count -eq 0) {
            Write-Warn 'Windows TCP :22 is not LISTENing'
        }
        else {
            foreach ($listener in $listeners) {
                $name = Get-ProcessNameForId -ProcessId ([int]$listener.OwningProcess)
                Write-Ok "Windows :22 LISTEN on $($listener.LocalAddress) (process: $name, PID $($listener.OwningProcess))"
            }
        }
    }
    catch {
        Write-Warn "Could not inspect Windows TCP :22: $($_.Exception.Message)"
    }

    try {
        $rules = @(Get-FirewallRules)
        if ($rules.Count -eq 0) {
            Write-Warn "Firewall rule '$($script:FirewallRuleName)' not found"
        }
        else {
            foreach ($rule in $rules) {
                if ($rule.Enabled -eq 'True') {
                    Write-Ok "Firewall rule: $($rule.DisplayName) (enabled)"
                }
                else {
                    Write-Warn "Firewall rule: $($rule.DisplayName) (disabled)"
                }
            }
            if ($rules.Count -gt 1) {
                Write-Warn 'Duplicate firewall rules with this name already exist'
            }
        }
    }
    catch {
        Write-Warn "Could not inspect firewall rule: $($_.Exception.Message)"
    }

    if ($mirrored -and (Test-HyperVFirewallSupported)) {
        $hvRule = Get-NetFirewallHyperVRule -Name $script:HyperVRuleName -ErrorAction SilentlyContinue
        if ($hvRule -and $hvRule.Enabled -eq 'True') { Write-Ok "Hyper-V firewall rule: $($script:HyperVRuleName) (enabled)" }
        else { Write-Warn "Hyper-V firewall rule '$($script:HyperVRuleName)' not found or disabled" }
    }

    $sshStatus = Get-WslSshStatus
    if (-not $sshStatus.Available) {
        $detail = if ($sshStatus.Detail) { ": $($sshStatus.Detail)" } else { '' }
        Write-Warn "Could not verify WSL SSH :22$detail"
        Show-SshInstallInstructions
    }
    elseif ($sshStatus.Listening) {
        Write-Ok 'WSL SSH :22 LISTEN'
    }
    else {
        Write-Warn 'WSL SSH :22 is not LISTENing'
        Show-SshInstallInstructions
    }

    foreach ($taskName in @($script:TaskName, $script:SshStartTaskName)) {
        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            if ($task.State -eq 'Running') {
                Write-Ok "Scheduled Task: $taskName (running)"
            }
            elseif ($task.Settings.Enabled) {
                Write-Ok "Scheduled Task: $taskName (enabled)"
            }
            else {
                Write-Warn "Scheduled Task: $taskName (disabled)"
            }
        }
        catch {
            Write-Warn "Scheduled Task '$taskName' not found"
        }
    }

    $legacyTask = Get-ScheduledTask -TaskName $script:KeepaliveTaskName -ErrorAction SilentlyContinue
    if ($legacyTask) {
        Write-Warn "Old sleep task still installed: $($script:KeepaliveTaskName)"
    }
}

function Remove-SshForwarding {
    Assert-Administrator
    $removedProxyCount = Remove-PortProxy22
    if ($removedProxyCount -gt 0) {
        Write-Ok "Removed $removedProxyCount Windows TCP :22 portproxy rule(s)"
    }
    else {
        Write-Warn 'No Windows TCP :22 portproxy rule found'
    }

    $rules = @(Get-FirewallRules)
    $ownedRules = @($rules | Where-Object { $_.Description -ceq $script:FirewallRuleMarker })
    if ($ownedRules.Count -gt 0) {
        $ownedRules | Remove-NetFirewallRule -ErrorAction Stop
        Write-Ok 'Script-created firewall rule removed'
    }
    elseif ($rules.Count -gt 0) {
        Write-Warn 'Same-name firewall rule was not created by this script; left unchanged'
    }
    else {
        Write-Warn 'No script-created firewall rule found'
    }
    Remove-HyperVFirewallRule
}

function Install-SshServiceTask {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    Assert-AdminOnlyWritable -Path $ScriptPath
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = $ScriptPath.Replace('"', '""')
    $distroArg = $Distro.Replace('"', '""')
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '" StartSsh -Distro "' + $distroArg + '"'
    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    # Boot trigger + S4U: WSL and sshd start before anyone logs on, without storing a password.
    # The logon trigger restarts it if WSL was shut down; IgnoreNew keeps a single instance.
    $trigger = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn -User $currentUser)
    )
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)

    $oldTask = Get-ScheduledTask -TaskName $script:KeepaliveTaskName -ErrorAction SilentlyContinue
    if ($oldTask) {
        if ($oldTask.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $script:KeepaliveTaskName -ErrorAction SilentlyContinue
        }
        Unregister-ScheduledTask -TaskName $script:KeepaliveTaskName -Confirm:$false -ErrorAction Stop
        Write-Ok "Removed old sleep task: $($script:KeepaliveTaskName)"
    }

    Register-ScheduledTask -TaskName $script:SshStartTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description "Start the WSL SSH service at boot (S4U, no logon needed) and at $currentUser logon." -Force | Out-Null
    Write-Ok "Scheduled Task created: $($script:SshStartTaskName)"
    Write-Host "       Trigger: Windows boot (runs as $currentUser without logon, S4U) and $currentUser logon"
    Write-Host "       Action: $powershellExe $arguments"
}

function Install-RefreshTask {
    Assert-Administrator
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Save and run this script from a .ps1 file before installing the Scheduled Task.'
    }

    $existingRefreshTask = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($existingRefreshTask -and $existingRefreshTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
    }

    $installed = Install-ProtectedScript -Source $PSCommandPath
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = $installed.Replace('"', '""')
    $distroArg = $Distro.Replace('"', '""')
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '" Refresh -Distro "' + $distroArg + '" -AllowedRemoteAddress "' + $script:AllowedRemoteAddress.Replace('"', '""') + '"'

    $taskAction = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $taskTrigger = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn -User $currentUser)
    )
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $script:TaskName -Action $taskAction -Trigger $taskTrigger `
        -Principal $taskPrincipal -Settings $taskSettings -Description 'Refresh the WSL2 SSH TCP 22 portproxy at boot and at user logon.' -Force | Out-Null

    Write-Ok "Scheduled Task created: $($script:TaskName)"
    Write-Host "       Trigger: Windows boot (S4U) and $currentUser logon"
    Write-Host "       Action: $powershellExe $arguments"
    Install-SshServiceTask -ScriptPath $installed
    Save-Settings
    Start-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
    Ensure-WslSshRunning
    Write-Ok 'Port forwarding and SSH service are ready (tasks also run at boot without logon)'
}

function Remove-RefreshTask {
    Assert-Administrator
    foreach ($taskName in @($script:TaskName, $script:SshStartTaskName, $script:KeepaliveTaskName)) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            Write-Warn "Scheduled Task '$taskName' not found"
            continue
        }
        if ($task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Ok "Scheduled Task removed: $taskName"
    }
    foreach ($file in @($script:InstalledScript, $script:SettingsPath)) {
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force
            Write-Ok "Removed $file"
        }
    }
    if ((Test-Path -LiteralPath $script:ProtectedDir) -and -not (Get-ChildItem -LiteralPath $script:ProtectedDir -Force)) {
        Remove-Item -LiteralPath $script:ProtectedDir -Force
    }
}

function Upgrade-LegacyKeepaliveTask {
    $legacyTask = Get-ScheduledTask -TaskName $script:KeepaliveTaskName -ErrorAction SilentlyContinue
    if ($legacyTask -or (Get-ScheduledTask -TaskName $script:SshStartTaskName -ErrorAction SilentlyContinue).Settings.ExecutionTimeLimit -ne 'PT0S') {
        if (Test-Path -LiteralPath $script:InstalledScript) {
            Install-SshServiceTask -ScriptPath $script:InstalledScript
        }
        else {
            Write-Warn "SSH service task needs an update; run InstallTask (elevated) to install $($script:InstalledScript)"
        }
    }
}

try {
    switch ($Action) {
        'Install' {
            Assert-Administrator
            Set-SshPortProxy
            Save-Settings
            Ensure-WslSshRunning
        }
        'Refresh' {
            Assert-Administrator
            Set-SshPortProxy
            Upgrade-LegacyKeepaliveTask
            Ensure-WslSshRunning
        }
        'Status' {
            Show-Status
        }
        'Remove' {
            Remove-SshForwarding
        }
        'InstallTask' {
            Install-RefreshTask
        }
        'RemoveTask' {
            Remove-RefreshTask
        }
        'StartSsh' {
            & wsl.exe -d $Distro -u root -- /bin/sh -c 'systemctl stop ssh.socket ssh.service; mkdir -p /run/sshd; exec /usr/sbin/sshd -D -e'
            if ($LASTEXITCODE -ne 0) { throw 'Foreground SSH server exited with an error.' }
        }
        'Keepalive' {
            # Compatibility for a previously registered action; replace sleep with starting sshd.
            Ensure-WslSshRunning
        }
    }
}
catch {
    $message = $_.Exception.Message
    try {
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Action] $message" |
            Add-Content -LiteralPath $script:ErrorLogPath -Encoding UTF8 -ErrorAction Stop
        Write-Host "[ERROR] $message (details: $script:ErrorLogPath)" -ForegroundColor Red
    }
    catch {
        Write-Host "[ERROR] $message" -ForegroundColor Red
    }
    exit 1
}

exit 0



