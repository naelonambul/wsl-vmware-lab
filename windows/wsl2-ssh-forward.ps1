#requires -Version 5.1
<#
.SYNOPSIS
  Keep WSL SSH reachable from the LAN. Uses portproxy for NAT and direct access for mirrored mode.

.USAGE
  .\wsl2-ssh-forward.ps1 Install [-Distro Ubuntu-24.04] [-AllowedRemoteAddress 192.168.0.0/24]
  .\wsl2-ssh-forward.ps1 Refresh [-Distro Ubuntu-24.04]
  .\wsl2-ssh-forward.ps1 Status [-Distro Ubuntu-24.04]
  .\wsl2-ssh-forward.ps1 Remove [-Distro Ubuntu-24.04]
  .\wsl2-ssh-forward.ps1 InstallTask [-Distro Ubuntu-24.04] [-AllowedRemoteAddress 192.168.0.0/24]
  .\wsl2-ssh-forward.ps1 RemoveTask
  StartSsh is an internal Scheduled Task action.

.STRUCTURE
  NAT: Windows 0.0.0.0:22 -> current WSL IPv4:22 -> sshd
  Mirrored: Windows and WSL share an IP; sshd is reached directly and no portproxy is used.
  InstallTask creates logon tasks for this Windows account: one refreshes forwarding
  and one starts the WSL ssh service. No sleep process is used.
  This script manages TCP 22 only and does not change RDP's TCP 3306 settings.

.NOTES
  WSL2 NAT IP may change after `wsl --shutdown` or a Windows restart; run Refresh.
  InstallTask runs after this Windows user logs on. It refreshes NAT forwarding and starts ssh.
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

$script:ListenAddress = '0.0.0.0'
$script:SshPort = 22
$script:FirewallRuleName = 'WSL2 SSH 22'
$script:FirewallRuleMarker = 'Managed by wsl2-ssh-forward.ps1'
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
    $entries = @(Get-PortProxyEntries | Where-Object { $_.ListenPort -eq $script:SshPort })
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
        return
    }

    foreach ($entry in @($existingEntries | Where-Object { $_.ListenPort -eq $script:SshPort })) {
        Invoke-Netsh -Arguments @(
            'interface', 'portproxy', 'delete', 'v4tov4',
            "listenport=$($entry.ListenPort)", "listenaddress=$($entry.ListenAddress)"
        ) | Out-Null
    }

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
}

function Install-SshServiceTask {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = $PSCommandPath.Replace('"', '""')
    $distroArg = $Distro.Replace('"', '""')
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '" StartSsh -Distro "' + $distroArg + '"'
    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

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
        -Description "Start the WSL SSH service at $currentUser logon." -Force | Out-Null
    Write-Ok "Scheduled Task created: $($script:SshStartTaskName)"
    Write-Host "       Trigger: $currentUser logs on"
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

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = $PSCommandPath.Replace('"', '""')
    $distroArg = $Distro.Replace('"', '""')
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '" Refresh -Distro "' + $distroArg + '" -AllowedRemoteAddress "' + $script:AllowedRemoteAddress.Replace('"', '""') + '"'

    $taskAction = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:TaskName -Action $taskAction -Trigger $taskTrigger `
        -Principal $taskPrincipal -Settings $taskSettings -Description 'Refresh the WSL2 SSH TCP 22 portproxy at user logon.' -Force | Out-Null

    Write-Ok "Scheduled Task created: $($script:TaskName)"
    Write-Host "       Trigger: $currentUser logs on"
    Write-Host "       Action: $powershellExe $arguments"
    Install-SshServiceTask
    Start-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
    Start-WslSshService
    Write-Ok 'Port forwarding and SSH service are ready'
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
}

function Upgrade-LegacyKeepaliveTask {
    $legacyTask = Get-ScheduledTask -TaskName $script:KeepaliveTaskName -ErrorAction SilentlyContinue
    if ($legacyTask -or (Get-ScheduledTask -TaskName $script:SshStartTaskName -ErrorAction SilentlyContinue).Settings.ExecutionTimeLimit -ne 'PT0S') {
        Install-SshServiceTask
        Start-ScheduledTask -TaskName $script:SshStartTaskName
    }
}

try {
    switch ($Action) {
        'Install' {
            Assert-Administrator
            Set-SshPortProxy
            Start-WslSshService
        }
        'Refresh' {
            Assert-Administrator
            Set-SshPortProxy
            Start-WslSshService
            Upgrade-LegacyKeepaliveTask
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
            Start-WslSshService
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



