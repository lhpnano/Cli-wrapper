# Resolves which network path agy should use and prints ONE line:
#   <proxy url>   use this proxy
#   DIRECT        clear proxy variables, route at the network layer
#   ERROR:<msg>   the requested mode is unavailable
#
# It deliberately does not launch agy. The .cmd shims hand %* straight to agy.exe so
# that no layer re-parses the prompt -- routing agy's own flags through PowerShell
# parameter binding mangles both -p and --long-flags.
param(
  [ValidateSet('Auto', 'V2rayN', 'Surfshark', 'Direct')]
  [string]$Network = 'Auto',

  [string]$V2rayEndpoint = 'http://127.0.0.1:10808'
)

$ErrorActionPreference = 'Stop'

function Test-ProxyListening {
  param([string]$Url)
  try {
    $uri = [System.Uri]::new($Url)
    $client = New-Object System.Net.Sockets.TcpClient
    $listening = $client.ConnectAsync($uri.Host, $uri.Port).Wait(500)
    $client.Close()
    return $listening
  } catch { return $false }
}

# The Surfshark service runs whether or not the tunnel is up, so the process list proves
# nothing. Resolve the VPN interface index and confirm that it owns a covering route.
# netsh avoids the multi-second NetAdapter/NetTCPIP PowerShell module startup on each CLI
# invocation.
function Test-VpnRouteUp {
  try {
    $interfaceLines = @(& netsh.exe interface ipv4 show interfaces 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }

    $adapterIndexes = @($interfaceLines | ForEach-Object {
      if ($_ -match '^\s*(\d+)\s+\d+\s+\d+\s+\S+\s+(.+?)\s*$') {
        $interfaceIndex = [int]$Matches[1]
        $interfaceName = $Matches[2]
        if ($interfaceName -match 'Surfshark|WireGuard|OpenVPN|TAP-Windows') {
          $interfaceIndex
        }
      }
    })
    if ($adapterIndexes.Count -eq 0) { return $false }

    # Surfshark's OpenVPN DCO does not replace 0.0.0.0/0. It installs the more specific
    # pair 0.0.0.0/1 + 128.0.0.0/1, which together cover all of IPv4 and outrank the
    # physical adapter's default route. Testing only for 0.0.0.0/0 reported the tunnel
    # as down while it was in fact carrying every packet.
    $routeLines = @(& netsh.exe interface ipv4 show route 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }

    foreach ($line in $routeLines) {
      if ($line -match '^\s*\S+\s+\S+\s+\d+\s+(?:0\.0\.0\.0/[01]|128\.0\.0\.0/1)\s+(\d+)\s+' -and
          $adapterIndexes -contains [int]$Matches[1]) {
        return $true
      }
    }
    return $false
  } catch { return $false }
}

$mode = $Network
if ($mode -eq 'Auto') {
  # Surfshark wins a tie: network-layer routing also covers traffic that ignores proxy
  # variables.
  $mode = if (Test-VpnRouteUp) { 'Surfshark' }
          elseif (Test-ProxyListening -Url $V2rayEndpoint) { 'V2rayN' }
          else { 'Direct' }
}

switch ($mode) {
  'V2rayN' {
    if (-not (Test-ProxyListening -Url $V2rayEndpoint)) {
      Write-Output "ERROR:V2rayN requested but nothing is listening on $V2rayEndpoint"
      exit 9
    }
    Write-Output $V2rayEndpoint
  }
  'Surfshark' {
    if (-not (Test-VpnRouteUp)) {
      Write-Output 'ERROR:Surfshark requested but no VPN adapter owns a default route'
      exit 9
    }
    Write-Output 'DIRECT'
  }
  default { Write-Output 'DIRECT' }
}
exit 0
