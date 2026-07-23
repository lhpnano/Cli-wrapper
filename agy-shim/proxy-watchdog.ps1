$port = 10808
$proxyUrl = 'http://127.0.0.1:10808'
$noProxy = '127.0.0.1,localhost'

$alive = $false
try {
  $tcp = New-Object System.Net.Sockets.TcpClient
  $tcp.Connect('127.0.0.1', $port)
  $alive = $true
  $tcp.Close()
} catch {}

$current = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')

if ($alive -and $current -ne $proxyUrl) {
  [Environment]::SetEnvironmentVariable('HTTP_PROXY', $proxyUrl, 'User')
  [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxyUrl, 'User')
  [Environment]::SetEnvironmentVariable('NO_PROXY', $noProxy, 'User')
} elseif (-not $alive -and $null -ne $current -and $current -ne '') {
  [Environment]::SetEnvironmentVariable('HTTP_PROXY', $null, 'User')
  [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, 'User')
  [Environment]::SetEnvironmentVariable('NO_PROXY', $null, 'User')
}
