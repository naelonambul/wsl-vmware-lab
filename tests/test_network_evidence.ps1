# Offline PS 5.1 regression checks: parse setup.ps1 only; never invoke it or collectors.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\windows\setup.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

# Closed command list rejects Get-Content, Get-Item*, Get-ChildItem, aliases,
# module-qualified provider commands and any new collector pending review.
$allowed = @('Read-Evidence', 'Read-RegistryTree', 'Read-RegistryValue',
    'Join-Path', 'Where-Object', 'ForEach-Object',
    'Get-NetAdapter', 'Get-NetIPConfiguration', 'Get-NetAdapterBinding')
$collectors = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Read-Evidence', 'Read-RegistryTree', 'Read-RegistryValue', 'Get-NetworkEvidence')
}, $true))
if ($collectors.Count -ne 4) { throw 'Evidence collector boundary changed; review the safety check.' }
foreach ($collector in $collectors) {
    foreach ($command in $collector.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)) {
        # Read-Evidence invokes its supplied scriptblock; no dynamic command elsewhere.
        if ($collector.Name -eq 'Read-Evidence' -and $command.Extent.Text -eq '& $Read') { continue }
        if ($command.GetCommandName() -notin $allowed) {
            throw "Unreviewed evidence command: $($command.Extent.Text)"
        }
    }
}
$network = ($collectors | Where-Object Name -eq 'Get-NetworkEvidence').Extent.Text
if ($network -notmatch '\[System\.IO\.File\]::ReadAllText\(') { throw 'netmap must be a plain File API string.' }
if ($network -notmatch [regex]::Escape("'SOFTWARE\VMware, Inc.\VMnetLib\VMnetConfig'")) { throw 'Wrong VMnetConfig root.' }
if ($network -notmatch "'Registry64', 'Registry32'") { throw 'Keep primary 64-bit and supplementary 32-bit evidence.' }

$json = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'ConvertTo-Json'
}, $true))
if ($json.Count -ne 1 -or $json[0].Extent.Text -notmatch '^ConvertTo-Json -Depth 10$') {
    throw 'JSON depth must remain bounded at the reviewed depth 10.'
}

# Synthetic deepest branch matches the collector shape, including registry arrays.
# No production functions, registry/provider APIs or networking are executed.
$record = [pscustomobject]@{ path = 'fixture\NAT\TCP'; values = @{ bytes = [byte[]](1, 2); names = [string[]]('a', 'b') }; reason = $null }
$fixture = [pscustomobject]@{ registry = @{ Registry64 = [pscustomobject]@{
    data = [pscustomobject]@{ vmnets = @{ VMnet8 = @{ raw = [pscustomobject]@{ data = @($record); reason = $null } } } }; reason = $null
} } }
$depth = [int]($json[0].CommandElements[-1].Extent.Text)
$encoded = $fixture | ConvertTo-Json -Depth $depth
$decoded = $encoded | ConvertFrom-Json
$values = $decoded.registry.Registry64.data.vmnets.VMnet8.raw.data[0].values
if (($values.bytes -join ',') -ne '1,2' -or ($values.names -join ',') -ne 'a,b') { throw 'Depth truncates registry arrays.' }
# Depth 9 turns the depth-10 arrays into strings on PS 5.1: 10 is minimal.
$shallow = $fixture | ConvertTo-Json -Depth ($depth - 1) -WarningAction SilentlyContinue | ConvertFrom-Json
if ($shallow.registry.Registry64.data.vmnets.VMnet8.raw.data[0].values.names -is [array]) {
    throw 'Depth justification changed; review the minimum.'
}
Write-Output '[OK] PowerShell parser; collector command allowlist; registry views/root; depth 10 round-trip (9 truncates arrays)'
