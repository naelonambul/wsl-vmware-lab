# Keep this PC reachable while it hosts the lab. A Windows PC that sleeps or
# hibernates drops WSL SSH, vmrest and the VMs; from another PC this looks like
# an SSH timeout on port 22. Turning the display off is harmless and not touched.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\configure-power.ps1                  # Status: read only
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\configure-power.ps1 -Action Apply    # on AC power: never sleep, never hibernate, closing the lid does nothing
#   ... -Action Apply -IncludeBattery   # the same on battery too
#   ... -Action Restore                 # put back the values saved by the first Apply
#   ... -Action Apply -WhatIf           # show the changes without making them
#   ... -Machine                        # one key=value line for preflight.sh
#
# Settings are read and written by GUID (powercfg /qh), so localized powercfg
# output does not matter. Only the active power plan is changed; switching to
# another plan later brings that plan's own values back. A Group Policy power
# setting overrides these values.
#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Status', 'Apply', 'Restore')]
    [string]$Action = 'Status',
    # Apply to battery (DC) values as well as AC. Without it only AC is changed.
    [switch]$IncludeBattery,
    # Status as a single key=value line (n/a = setting not present on this PC).
    [switch]$Machine
)
$ErrorActionPreference = 'Stop'
# Load it before any -WhatIf run, or its alias setup is reported as WhatIf noise.
$wi = $WhatIfPreference; $WhatIfPreference = $false
Import-Module CimCmdlets
$WhatIfPreference = $wi

# Value 0 means "never" for the two timeouts (seconds) and "do nothing" for the lid.
$settings = [ordered]@{
    sleep     = @{ Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Id = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Text = 'sleep after (seconds)' }       # SUB_SLEEP / STANDBYIDLE
    hibernate = @{ Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Id = '9d7815a6-7ee4-497e-8888-515a05f02364'; Text = 'hibernate after (seconds)' }   # SUB_SLEEP / HIBERNATEIDLE
    lid       = @{ Sub = '4f971e89-eebd-4455-a8de-9e59040e7347'; Id = '5ca83367-6e45-459f-a27b-476b1d01c936'; Text = 'lid close action' }            # SUB_BUTTONS / LIDACTION (hidden setting)
}
$lidNames = @{ 0 = 'do nothing'; 1 = 'sleep'; 2 = 'hibernate'; 3 = 'shut down' }
$effectivelyNever = 31536000   # one year in seconds
$backupFile = Join-Path $env:LOCALAPPDATA 'wsl-vmware-lab\power-backup.json'

function Get-ActiveScheme {
    $out = (& powercfg.exe /getactivescheme) -join ' '
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
    throw 'Could not read the active power plan (powercfg /getactivescheme).'
}

# Returns @{AC=..; DC=..} or $null when the setting does not exist (no lid, for example).
# /qh also lists hidden settings such as the lid action; the last two hex values
# printed are always the current AC and DC values.
function Get-PowerValue([string]$Scheme, [hashtable]$S) {
    $out = & powercfg.exe /qh $Scheme $S.Sub $S.Id 2>$null
    if ($LASTEXITCODE -ne 0) { $out = & powercfg.exe /q $Scheme $S.Sub $S.Id 2>$null }
    $hex = @([regex]::Matches(($out -join "`n"), '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }
    @{ AC = [Convert]::ToUInt32($hex[-2].Substring(2), 16); DC = [Convert]::ToUInt32($hex[-1].Substring(2), 16) }
}

function Set-PowerValue([string]$Scheme, [hashtable]$S, [string]$Kind, [uint32]$Value) {
    $verb = if ($Kind -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
    & powercfg.exe $verb $Scheme $S.Sub $S.Id $Value
    if ($LASTEXITCODE -ne 0) { throw "powercfg $verb failed (exit $LASTEXITCODE). Run PowerShell as administrator, or check whether Group Policy manages power settings." }
}

function Read-All([string]$Scheme) {
    $r = [ordered]@{}
    foreach ($k in $settings.Keys) { $r[$k] = Get-PowerValue $Scheme $settings[$k] }
    $r
}

function Format-Value([string]$Key, $V) {
    if ($null -eq $V) { return 'n/a' }
    if ($Key -eq 'lid') { if ($lidNames.ContainsKey([int]$V)) { return $lidNames[[int]$V] } return "$V" }
    if ($V -eq 0) { return 'never' }
    if ($V -ge $effectivelyNever) { return 'never (> 1 year)' }
    "$([math]::Round($V / 60, 1)) min"
}

# A timeout of a year or more (some PCs ship 0x7fffffff seconds) never fires in practice.
function Test-RemoteSafe([string]$Key, $V) {
    if ($null -eq $V -or $V -eq 0) { return $true }
    ($Key -ne 'lid') -and ($V -ge $effectivelyNever)
}

function Show-Status([string]$Scheme, $Values, [bool]$HasBattery) {
    if ($Machine) {
        $parts = @()
        foreach ($k in $Values.Keys) {
            $v = $Values[$k]
            if ($null -eq $v) { $parts += "${k}_ac=n/a"; $parts += "${k}_dc=n/a" }
            else { $parts += "${k}_ac=$($v.AC)"; $parts += "${k}_dc=$($v.DC)" }
        }
        $parts += "battery=$HasBattery"
        $parts += "backup=$(Test-Path -LiteralPath $backupFile)"
        $parts -join ' '
        return
    }
    Write-Host "Active power plan: $Scheme  battery: $HasBattery"
    foreach ($k in $Values.Keys) {
        $v = $Values[$k]
        $ac = if ($v) { $v.AC } else { $null }
        $dc = if ($v) { $v.DC } else { $null }
        $mark = if (-not (Test-RemoteSafe $k $ac)) { '[WARN]' }
                elseif ($HasBattery -and -not (Test-RemoteSafe $k $dc)) { '[NOTE]' }
                else { '[OK]  ' }
        Write-Host ("{0} {1,-26} AC: {2,-12} battery: {3}" -f $mark, $settings[$k].Text, (Format-Value $k $ac), (Format-Value $k $dc))
    }
    Write-Host '[WARN] = this PC can stop answering SSH on AC power; [NOTE] = only on battery.'
    if (Test-Path -LiteralPath $backupFile) { Write-Host "Saved original values: $backupFile (-Action Restore puts them back)" }
}

$scheme = Get-ActiveScheme
$hasBattery = [bool](@(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue).Count)
$values = Read-All $scheme

switch ($Action) {
    'Status' {
        Show-Status $scheme $values $hasBattery
    }
    'Apply' {
        if (Test-Path -LiteralPath $backupFile) {
            Write-Host "Keeping the existing backup of the original values: $backupFile"
        } elseif ($PSCmdlet.ShouldProcess($backupFile, 'Save current power values')) {
            $save = [ordered]@{ scheme = $scheme; saved = (Get-Date).ToString('o'); values = [ordered]@{} }
            foreach ($k in $values.Keys) { if ($values[$k]) { $save.values[$k] = [ordered]@{ AC = $values[$k].AC; DC = $values[$k].DC } } }
            New-Item -ItemType Directory -Force -Path (Split-Path $backupFile) | Out-Null
            $save | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupFile -Encoding ASCII
            Write-Host "Saved original values: $backupFile"
        }
        $kinds = @('AC'); if ($IncludeBattery) { $kinds += 'DC' }
        $changed = 0
        foreach ($k in $values.Keys) {
            if ($null -eq $values[$k]) { continue }
            foreach ($kind in $kinds) {
                if (Test-RemoteSafe $k $values[$k][$kind]) { continue }
                $what = "$($settings[$k].Text) on $kind`: $(Format-Value $k $values[$k][$kind]) -> $(Format-Value $k 0)"
                if ($PSCmdlet.ShouldProcess("power plan $scheme", $what)) { Set-PowerValue $scheme $settings[$k] $kind 0; $changed++ }
            }
        }
        if ($WhatIfPreference) { Write-Host 'WhatIf: nothing was changed' }
        elseif ($changed) { & powercfg.exe /setactive $scheme; Write-Host "[OK] changed $changed value(s)" }
        else { Write-Host '[OK] nothing to change' }
        if (-not $IncludeBattery -and $hasBattery) { Write-Host 'Battery values left as they are (add -IncludeBattery to change them too).' }
        Show-Status $scheme (Read-All $scheme) $hasBattery
    }
    'Restore' {
        if (-not (Test-Path -LiteralPath $backupFile)) { throw "No saved values: $backupFile (Apply was not run, or Restore already ran)." }
        $saved = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
        $target = $saved.scheme
        if ($target -ne $scheme) { Write-Warning "Values were saved from power plan $target; the active plan is now $scheme. Restoring into $target." }
        foreach ($k in $settings.Keys) {
            $v = $saved.values.$k
            if ($null -eq $v) { continue }
            foreach ($kind in 'AC', 'DC') {
                if ($PSCmdlet.ShouldProcess("power plan $target", "$($settings[$k].Text) on $kind -> $(Format-Value $k ([uint32]$v.$kind))")) {
                    Set-PowerValue $target $settings[$k] $kind ([uint32]$v.$kind)
                }
            }
        }
        if ($PSCmdlet.ShouldProcess($backupFile, 'Activate plan and remove the backup')) {
            & powercfg.exe /setactive $scheme
            Remove-Item -LiteralPath $backupFile
            Write-Host '[OK] original power values restored'
        }
        Show-Status $scheme (Read-All $scheme) $hasBattery
    }
}
