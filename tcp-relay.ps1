# Per-connection stdio relay. No listening port, firewall or system settings.
param([Parameter(Mandatory=$true)][string]$TargetHost,
      [Parameter(Mandatory=$true)][int]$TargetPort)
$ErrorActionPreference = 'Stop'
$client = New-Object System.Net.Sockets.TcpClient
try {
    $client.Connect($TargetHost, $TargetPort)
    $stream = $client.GetStream()
    $up = [Console]::OpenStandardInput().CopyToAsync($stream)
    $down = $stream.CopyToAsync([Console]::OpenStandardOutput())
    [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($up,$down)) | Out-Null
} finally { $client.Dispose() }
