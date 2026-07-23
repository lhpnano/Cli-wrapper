<#
.SYNOPSIS
Synchronizes the per-user WinINET proxy with the route selected for one CLI call.

.DESCRIPTION
The CLI child process can clear HTTP_PROXY, but Codex reqwest and CodeBuddy may
also read the Windows WinINET proxy. This script updates that setting immediately
before launch so stale ProxyEnable=1 cannot route a direct/VPN call to a dead
127.0.0.1:10808 listener.
#>
[CmdletBinding()]
param(
  [ValidateSet('Auto', 'V2rayN', 'Surfshark', 'Direct')]
  [string]$Network = 'Auto',
  [string]$V2rayEndpoint = 'http://127.0.0.1:10808'
)

$ErrorActionPreference = 'Stop'
$resolver = Join-Path $PSScriptRoot 'agy-mode.ps1'
$resolved = @(& $resolver -Network $Network -V2rayEndpoint $V2rayEndpoint 2>$null)
$route = if ($resolved.Count -gt 0) { ([string]$resolved[-1]).Trim() } else { '' }
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($route)) {
  Write-Error 'network resolver returned no route'
  exit 9
}
if ($route -like 'ERROR:*') {
  Write-Error $route.Substring(6)
  exit 9
}

$keyPath = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($keyPath, $true)
if ($null -eq $key) { throw 'WinINET Internet Settings key is unavailable' }
try {
  if ($route -eq 'DIRECT') {
    $key.SetValue('ProxyEnable', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
  } else {
    $proxyUri = [System.Uri]::new($route)
    $key.SetValue('ProxyServer', ($proxyUri.Host + ':' + $proxyUri.Port), [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('ProxyEnable', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
  }
} finally { $key.Dispose() }

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinInetNotify {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
}
'@ -ErrorAction SilentlyContinue
$result = [IntPtr]::Zero
[WinInetNotify]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'Internet Settings', 0x0002, 3000, [ref]$result) | Out-Null
Write-Output $route
exit 0
