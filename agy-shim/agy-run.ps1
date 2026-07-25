<#
.SYNOPSIS
Runs Agy non-interactively with timeout, diagnostics, and product validation.

.DESCRIPTION
Wraps agy.exe print mode for reliable automation. The wrapper preserves the
underlying exit code, treats empty stdout as failure, emits progress heartbeats
to stderr, and can validate JSON or required output paths. Transient retries are
opt-in because an Agy task may have side effects.

.PARAMETER Prompt
Prompt text passed to Agy. Keep it below 24000 characters.

.PARAMETER PromptFile
UTF-8 text file containing the prompt. This improves prompt maintenance but
does not bypass the Windows command-line length limit.

.PARAMETER Manifest
Runs a low-risk long task from an agy-batch JSON manifest. The batch runner
splits work, retries once, bisects failed batches, resumes, and merges results.

.PARAMETER Timeout
Agy print-mode timeout in seconds. Default: 540.

.PARAMETER GraceSeconds
Additional time before the wrapper forcibly stops agy.exe. Default: 15.

.PARAMETER HeartbeatSeconds
Progress interval written to stderr. Use 0 to disable. Default: 30.

.PARAMETER TransientRetries
Retries for network, timeout, or empty-output failures. Default: 0.

.PARAMETER RequireJson
Fails with exit code 4 unless stdout is valid JSON.

.PARAMETER RequirePath
Exact file or directory paths that must exist after Agy completes.

.PARAMETER OutputFile
Writes successful stdout to this UTF-8 file without a BOM.

.PARAMETER SkipPerms
Passes --dangerously-skip-permissions. Use only in a controlled directory.

.EXAMPLE
agy-run -Prompt "Reply with PONG only." -AddDir . -Timeout 30

.EXAMPLE
agy-run -PromptFile .\task.txt -RequireJson -OutputFile .\result.json

.EXAMPLE
agy-run -Prompt "Create output.txt" -AddDir . -RequirePath .\output.txt -SkipPerms

.NOTES
Wrapper exit codes: 2 empty stdout; 3 output too short; 4 invalid JSON;
5 required path missing; 6 output write failed; 7 rejected by region;
8 quota exhausted; 9 no usable network path; 64 invalid input;
124 wrapper hard timeout; 127 agy.exe missing. Other nonzero codes come from Agy.

.PARAMETER Network
Auto, V2rayN, Surfshark or Direct. Auto picks Surfshark when a VPN adapter owns a
default route, else V2rayN when the proxy port is listening, else Direct. Proxy
variables are set on the agy child process only; user and machine environments are
never modified.

.PARAMETER AllowAccountSwitch
Permits falling back to the other Antigravity account after a failed AUTH retry.
Off by default because auth is normally fixed by re-minting the active account's
token, and hopping changes which account the work is billed to.

.PARAMETER QuotaRetries
Account switches allowed after a QUOTA failure. Default 1, and deliberately not
gated by -AllowAccountSwitch: an exhausted account cannot be fixed by retrying,
so switching is the only useful response. Set to 0 to fail fast instead.
#>
[CmdletBinding(DefaultParameterSetName = 'Prompt')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Prompt', Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$Prompt,

  [Parameter(Mandatory = $true, ParameterSetName = 'PromptFile')]
  [ValidateNotNullOrEmpty()]
  [string]$PromptFile,

  [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
  [ValidateNotNullOrEmpty()]
  [string]$Manifest,

  [Parameter(ParameterSetName = 'Manifest')]
  [switch]$ValidateOnly,

  [string]$Model,

  [ValidateRange(1, 86400)]
  [int]$Timeout = 540,

  [ValidateRange(0, 300)]
  [int]$GraceSeconds = 15,

  [ValidateRange(0, 3600)]
  [int]$HeartbeatSeconds = 30,

  [ValidateRange(0, 5)]
  [int]$AuthRetries = 2,

  [ValidateRange(0, 5)]
  [int]$TransientRetries = 0,

  [ValidateRange(0, 5)]
  [int]$QuotaRetries = 1,

  [ValidateRange(1, 2147483647)]
  [int]$MinOutputChars = 1,

  [switch]$RequireJson,

  [string[]]$RequirePath,

  [string]$OutputFile,

  [switch]$SkipPerms,

  [string[]]$AddDir,

  [switch]$Sandbox,

  [ValidateSet('accept-edits', 'plan')]
  [string]$Mode,

  [string]$AgyLogFile,

  [string]$Proxy = 'http://127.0.0.1:10808',

  [ValidateSet('Auto', 'V2rayN', 'Clash', 'Surfshark', 'Direct')]
  [string]$Network = 'Auto',

  [switch]$Direct,

  [switch]$AllowAccountSwitch,

  [switch]$NoNetworkCheck,

  [switch]$NoPreflight
)

$ErrorActionPreference = 'Stop'
$agy = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
$authPattern = 'Authentication required|authentication timed out|authentication failed|Please visit the URL to log in|not authenticated'
$transientPattern = 'network|connection|connection reset|connection refused|EOF|timed? out|timeout|temporarily unavailable|rate limit|HTTP\s+(429|502|503|504)'
# agy collapses every backend failure into one opaque line on stderr:
#   "Error: Agent execution terminated due to error."
# Matching that as an auth failure made the wrapper burn account switches on errors that
# had nothing to do with auth (a geo block, for one). The real cause only shows up in
# --log-file, so we always capture one and classify from it.
$opaqueFailure = 'Agent execution terminated due to error'
# Classification order matters and is deliberate: a dead proxy makes every later symptom
# look like an auth or model failure, so the transport is ruled out first.
$logNetworkPattern = 'proxyconnect|dial tcp|no such host|connection refused|actively refused|TLS handshake|context deadline exceeded'
$logLocationPattern = 'User location is not supported|FAILED_PRECONDITION.*location'
$logAuthPattern = 'not authenticated|silent auth failed|keyring.*(failed|error)|invalid_grant|token.*expired'
$logQuotaPattern = 'RESOURCE_EXHAUSTED|quota exceeded|429'

function Write-AgyDiagnostic {
  param([string]$Message)
  [Console]::Error.WriteLine("[agy-run] $Message")
}

# One machine-readable line per account-switch decision. agy-batch.ps1 greps these out of
# the worker's stderr into run_state.json, so the shape must stay stable. Labels arrive
# already masked from Get-AmAccountLabel; tokens and API keys never pass through here.
function Write-AgySwitchEvent {
  param(
    [bool]$Performed,
    [string]$From = '',
    [string]$To = '',
    [string]$Reason = '',
    [string]$Trigger = 'quota'
  )
  $fields = @("performed=$($Performed.ToString().ToLowerInvariant())", "trigger=$Trigger")
  if ($From) { $fields += "from=$From" }
  if ($To) { $fields += "to=$To" }
  if ($Reason) { $fields += "reason=$Reason" }
  Write-AgyDiagnostic ('account-switch: ' + ($fields -join ' '))
}

function Exit-AgyRun {
  param(
    [int]$Code,
    [string]$Message
  )
  if (-not [string]::IsNullOrWhiteSpace($Message)) {
    Write-AgyDiagnostic $Message
  }
  exit $Code
}

function Resolve-ExistingPath {
  param(
    [string]$Path,
    [string]$Description
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    Exit-AgyRun -Code 64 -Message "$Description does not exist: $Path"
  }
  (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-OutputPath {
  param([string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $parent = Split-Path -Parent $fullPath
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $fullPath
}

function ConvertTo-WindowsArgumentString {
  param([string[]]$Arguments)
  ($Arguments | ForEach-Object {
    $arg = [string]$_
    if ($arg -eq '') {
      '""'
    } elseif ($arg -notmatch '[\s"]') {
      $arg
    } else {
      $quoted = '"'
      $slashes = 0
      foreach ($ch in $arg.ToCharArray()) {
        if ($ch -eq '\') {
          $slashes++
        } elseif ($ch -eq '"') {
          $quoted += ('\' * (($slashes * 2) + 1)) + '"'
          $slashes = 0
        } else {
          if ($slashes -gt 0) {
            $quoted += ('\' * $slashes)
            $slashes = 0
          }
          $quoted += $ch
        }
      }
      if ($slashes -gt 0) { $quoted += ('\' * ($slashes * 2)) }
      $quoted += '"'
      $quoted
    }
  }) -join ' '
}

# Credential freshness. agy reads its access token from Windows Credential Manager
# (target gemini:antigravity, TTL 3599s) and never refreshes it in -p mode. AM's own
# copy under ~/.antigravity_tools is a SEPARATE store and can be fresh while the
# credential is stale, so only the credential's LastWritten is a valid signal.
# We read metadata only and never touch the credential blob.
if (-not ('AgyCredMeta' -as [type])) {
  Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class AgyCredMeta {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct CREDENTIAL {
    public uint Flags; public uint Type; public IntPtr TargetName; public IntPtr Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
    public uint AttributeCount; public IntPtr Attributes; public IntPtr TargetAlias; public IntPtr UserName;
  }
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr cred);
  [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr cred);
  public static long LastWritten(string target) {
    IntPtr p;
    if (!CredReadW(target, 1, 0, out p)) return -1;
    try {
      CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
      return ((long)c.LastWritten.dwHighDateTime << 32) | (uint)c.LastWritten.dwLowDateTime;
    } finally { CredFree(p); }
  }
}
'@
}

$script:CredentialTarget = 'gemini:antigravity'
$script:TokenTtlSeconds = 3599

function Get-CredentialWriteTicks {
  try { return [AgyCredMeta]::LastWritten($script:CredentialTarget) } catch { return -1 }
}

function Get-CredentialAgeSeconds {
  $ticks = Get-CredentialWriteTicks
  # Unreadable credential counts as stale so we refresh rather than walk into an auth prompt.
  if ($ticks -le 0) { return [int]::MaxValue }
  $age = ([DateTime]::UtcNow - [DateTime]::FromFileTimeUtc($ticks)).TotalSeconds
  if ($age -lt 0) { return 0 }
  return [int]$age
}

function Get-AmContext {
  $configPath = Join-Path $env:USERPROFILE '.antigravity_tools\gui_config.json'
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
  try {
    $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $port = [int]$cfg.proxy.port
    $key = [string]$cfg.proxy.api_key
    if ($port -lt 1 -or [string]::IsNullOrWhiteSpace($key)) { return $null }
    $headers = @{ 'Authorization' = "Bearer $key"; 'Content-Type' = 'application/json' }
    # Always query live: the user may have switched accounts in the GUI.
    $list = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/accounts" -Headers $headers -TimeoutSec 10
    [pscustomobject]@{
      Base = "http://127.0.0.1:$port"
      Headers = $headers
      CurrentId = [string]$list.current_account_id
      Accounts = @($list.accounts)
    }
  } catch {
    Write-AgyDiagnostic "AM API unreachable: $($_.Exception.Message)"
    return $null
  }
}

# Rebuilds the trusted silent-switch manifest if it is missing or stale.
# This keeps the file present across wrapper edits and updates, rather than
# requiring a one-time manual deployment step to recreate it.
function Ensure-AmSilentSwitchManifest {
  $manifestPath = Join-Path $env:LOCALAPPDATA 'agy-shim\am-silent-switch.json'
  $candidatePaths = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'),
    (Join-Path $env:LOCALAPPDATA 'Antigravity Tools\antigravity_tools.exe')
  )
  $exePath = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (-not $exePath) {
    Write-AgyDiagnostic 'AM silent switch manifest could not be rebuilt: no Antigravity executable found'
    return $false
  }
  try {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exePath).Hash.ToUpperInvariant()
    $payload = [ordered]@{
      executable_path = $exePath
      sha256 = $hash
      updated_at = [DateTime]::UtcNow.ToString('o')
    }
    $directory = Split-Path -Parent $manifestPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = $payload | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($manifestPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-AgyDiagnostic "AM silent switch manifest refreshed: $exePath"
    return $true
  } catch {
    Write-AgyDiagnostic "AM silent switch manifest rebuild failed: $($_.Exception.Message)"
    return $false
  }
}

# AM's HTTP schema has no capability-negotiation endpoint. Trust only an AM binary
# explicitly recorded by the deployment step; an update must fail closed instead of
# silently ignoring targetIde and launching the desktop client.
function Test-AmSilentSwitchSupport {
  $manifestPath = Join-Path $env:LOCALAPPDATA 'agy-shim\am-silent-switch.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    if (-not (Ensure-AmSilentSwitchManifest)) {
      Write-AgyDiagnostic 'AM silent agy switch is not trusted; refusing account switch to prevent Antigravity.exe launch'
      return $false
    }
  }
  try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedHash = ([string]$manifest.sha256).Trim().ToUpperInvariant()
    $expectedPath = ([string]$manifest.executable_path).Trim()
    if ($expectedHash -notmatch '^[A-F0-9]{64}$' -or [string]::IsNullOrWhiteSpace($expectedPath)) {
      Write-AgyDiagnostic 'AM silent switch manifest is invalid; refusing account switch'
      return $false
    }
    if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
      Write-AgyDiagnostic 'AM silent switch executable from manifest is missing; refusing account switch'
      return $false
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $expectedPath).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) {
      if (Ensure-AmSilentSwitchManifest) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $expectedHash = ([string]$manifest.sha256).Trim().ToUpperInvariant()
        $expectedPath = ([string]$manifest.executable_path).Trim()
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $expectedPath).Hash.ToUpperInvariant() -eq $expectedHash) {
          return $true
        }
      }
      Write-AgyDiagnostic 'AM executable hash changed; update may have removed silent agy switch, refusing account switch'
      return $false
    }
    return $true
  } catch {
    Write-AgyDiagnostic "AM silent switch capability check failed: $($_.Exception.Message)"
    return $false
  }
}

# Switching to an account -- including the one already active -- makes AM mint a fresh
# token and write it to Credential Manager. /api/accounts/refresh does NOT write it.
# A 2xx response is not proof of anything, so the caller verifies LastWritten advanced.
function Invoke-AmSwitch {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [Parameter(Mandatory = $true)][string]$AccountId,
    [string]$Label
  )
  if (-not (Test-AmSilentSwitchSupport)) { return $false }
  $before = Get-CredentialWriteTicks
  try {
    # The AM HTTP API must receive targetIde=agy so its desktop integration writes the
    # Windows credential and returns without closing or launching Antigravity IDE.
    $body = ConvertTo-Json @{ accountId = $AccountId; targetIde = 'agy' }
    $null = Invoke-RestMethod -Uri "$($Context.Base)/api/accounts/switch" -Method POST `
      -Headers $Context.Headers -Body $body -TimeoutSec 60
  } catch {
    Write-AgyDiagnostic "AM switch failed: $($_.Exception.Message)"
    return $false
  }
  Start-Sleep -Milliseconds 1500
  $after = Get-CredentialWriteTicks
  $afterContext = Get-AmContext
  $accountChanged = $null -ne $afterContext -and [string]$afterContext.CurrentId -eq $AccountId
  if ($after -gt $before -and $accountChanged) {
    Write-AgyDiagnostic "AM switch to $Label wrote a fresh credential"
    return $true
  }
  if (-not $accountChanged) {
    Write-AgyDiagnostic "AM switch to $Label returned OK but the active account did not change"
  } else {
    Write-AgyDiagnostic "AM switch to $Label returned OK but the credential was not rewritten"
  }
  return $false
}

function Get-AmAccountLabel {
  param($Context, [string]$AccountId)
  $match = $Context.Accounts | Where-Object { [string]$_.id -eq $AccountId } | Select-Object -First 1
  $label = if ($match) { [string]$match.email } else { $AccountId }
  # Keep three characters, not one. Both of this user's accounts start with "l", so a
  # single-character mask rendered them identically and a switch log could not say which
  # account it moved between -- which is the only reason the label is logged at all.
  if ($label -match '^([^@]+)(@.+)$') {
    $localPart = $Matches[1]
    $head = if ($localPart.Length -le 3) { $localPart } else { $localPart.Substring(0, 3) }
    return "$head***$($Matches[2])"
  }
  if ($label.Length -gt 8) { return "...$($label.Substring($label.Length - 6))" }
  return $label
}

# Re-mints the credential for the ACTIVE account. Cross-process mutex keeps a fan-out of
# batch workers from stampeding AM; whoever loses the race sees the fresh credential and skips.
function Invoke-AmSelfRefresh {
  param([int]$MaxAgeSeconds = 0)
  $mutex = New-Object System.Threading.Mutex($false, 'Global\agy-shim-token-refresh')
  $held = $false
  try {
    try { $held = $mutex.WaitOne(60000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) {
      Write-AgyDiagnostic 'timed out waiting for the token refresh lock; continuing without refresh'
      return $false
    }
    if ($MaxAgeSeconds -gt 0 -and (Get-CredentialAgeSeconds) -le $MaxAgeSeconds) {
      Write-AgyDiagnostic 'another process already refreshed the credential; skipping'
      return $true
    }
    $context = Get-AmContext
    if (-not $context) { return $false }
    if ([string]::IsNullOrWhiteSpace($context.CurrentId)) {
      Write-AgyDiagnostic 'AM reported no active account'
      return $false
    }
    return Invoke-AmSwitch -Context $context -AccountId $context.CurrentId `
      -Label (Get-AmAccountLabel -Context $context -AccountId $context.CurrentId)
  } finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

# Second line of defence: hop to the other Pro account. Only helps when the active
# account is quota-exhausted or blocked, so it is not the first thing we try.
function Invoke-AmOtherAccountSwitch {
  param([switch]$TrackQuotaAttempts)
  $context = Get-AmContext
  if (-not $context) {
    if ($TrackQuotaAttempts) { Write-AgySwitchEvent -Performed $false -Reason 'am-api-unreachable' }
    return $false
  }
  if ($TrackQuotaAttempts -and -not [string]::IsNullOrWhiteSpace($context.CurrentId)) {
    # Mark the account we are leaving as tried, so a later hop can never come back to it.
    $script:QuotaAttemptedAccountIds[[string]$context.CurrentId] = $true
  }
  $candidates = @($context.Accounts | Where-Object {
    $candidateId = [string]$_.id
    -not $_.disabled -and $candidateId -ne $context.CurrentId -and
      (-not $TrackQuotaAttempts -or -not $script:QuotaAttemptedAccountIds.ContainsKey($candidateId))
  })
  if ($candidates.Count -eq 0) {
    Write-AgyDiagnostic 'AM API: no other enabled account to switch to'
    return $false
  }
  $target = $candidates[0]
  $targetId = [string]$target.id
  $fromLabel = Get-AmAccountLabel -Context $context -AccountId $context.CurrentId
  $toLabel = Get-AmAccountLabel -Context $context -AccountId $targetId
  $switched = Invoke-AmSwitch -Context $context -AccountId $targetId -Label $toLabel
  if ($switched -and $TrackQuotaAttempts) { $script:QuotaAttemptedAccountIds[$targetId] = $true }
  if ($TrackQuotaAttempts) {
    if ($switched) {
      Write-AgySwitchEvent -Performed $true -From $fromLabel -To $toLabel
    } else {
      Write-AgySwitchEvent -Performed $false -From $fromLabel -To $toLabel -Reason 'switch-not-verified'
    }
  }
  return $switched
}

function Invoke-AgyRefresh {
  param([int]$AttemptIndex = 1)
  # Hopping accounts is opt-in: it changes which account the work is billed to and only
  # helps when the active one is quota-blocked, so it must never happen by surprise.
  if ($AttemptIndex -gt 1 -and $AllowAccountSwitch) {
    if (Invoke-AmOtherAccountSwitch) { return }
  } else {
    if (Invoke-AmSelfRefresh) { return }
  }
  Write-AgyDiagnostic 'AM refresh did not take; skipping interactive fallback to avoid auth popup'
}

function Invoke-AgyOnce {
  param(
    [string[]]$Arguments,
    [int]$Attempt
  )

  $stdoutFile = New-TemporaryFile
  $stderrFile = New-TemporaryFile
  $process = $null
  $timedOut = $false
  $hardTimeoutSeconds = $Timeout + $GraceSeconds

  try {
    $argumentLine = ConvertTo-WindowsArgumentString -Arguments $Arguments
    $process = Start-Process -FilePath $agy -ArgumentList $argumentLine `
      -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile `
      -NoNewWindow -PassThru

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextHeartbeat = $HeartbeatSeconds

    while (-not $process.WaitForExit(1000)) {
      $elapsedSeconds = [int][Math]::Floor($stopwatch.Elapsed.TotalSeconds)
      if ($hardTimeoutSeconds -gt 0 -and $elapsedSeconds -ge $hardTimeoutSeconds) {
        $timedOut = $true
        Write-AgyDiagnostic "hard timeout after ${hardTimeoutSeconds}s; stopping PID $($process.Id)"
        try { $process.Kill() } catch {}
        try { $process.WaitForExit(5000) | Out-Null } catch {}
        break
      }
      if ($HeartbeatSeconds -gt 0 -and $elapsedSeconds -ge $nextHeartbeat) {
        Write-AgyDiagnostic "running attempt $Attempt, elapsed ${elapsedSeconds}s, PID $($process.Id)"
        $nextHeartbeat += $HeartbeatSeconds
      }
    }

    if (-not $timedOut) {
      $process.WaitForExit()
    }
    $stopwatch.Stop()

    $stdout = Get-Content -LiteralPath $stdoutFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath $stderrFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $exitCode = if ($timedOut) { 124 } else { [int]$process.ExitCode }

    [pscustomobject]@{
      Stdout = [string]$stdout
      Stderr = [string]$stderr
      ExitCode = $exitCode
      TimedOut = $timedOut
      ElapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    }
  } catch {
    [pscustomobject]@{
      Stdout = ''
      Stderr = $_.Exception.Message
      ExitCode = 1
      TimedOut = $false
      ElapsedSeconds = 0
    }
  } finally {
    if ($process) { $process.Dispose() }
    Remove-Item -LiteralPath $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
  }
}

if (-not (Test-Path -LiteralPath $agy -PathType Leaf)) {
  Exit-AgyRun -Code 127 -Message "agy executable not found: $agy"
}

if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
  $batchRunner = Join-Path $PSScriptRoot 'agy-batch.ps1'
  if (-not (Test-Path -LiteralPath $batchRunner -PathType Leaf)) {
    Exit-AgyRun -Code 127 -Message "batch runner not found: $batchRunner"
  }
  & $batchRunner -Manifest $Manifest -ValidateOnly:$ValidateOnly
  exit $LASTEXITCODE
}

if ($PSCmdlet.ParameterSetName -eq 'PromptFile') {
  $resolvedPromptFile = Resolve-ExistingPath -Path $PromptFile -Description 'prompt file'
  $Prompt = Get-Content -LiteralPath $resolvedPromptFile -Raw -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($Prompt)) {
  Exit-AgyRun -Code 64 -Message 'prompt is empty'
}

if ($Prompt.Length -gt 24000) {
  Exit-AgyRun -Code 64 -Message "prompt is $($Prompt.Length) characters; split the task below 24000 characters to avoid the Windows command-line limit"
}

# Network routing. Proxy variables are set here and inherited by the agy.exe child only --
# nothing is written to HKCU, so Claude, Codex and the desktop clients are never touched.
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

# Surfshark's background service runs whether or not the tunnel is up, so the process list
# proves nothing. An adapter that is Up AND owns a default route does.
function Test-VpnRouteUp {
  try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
      $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Surfshark|WireGuard|OpenVPN|TAP-Windows'
    })
    if ($adapters.Count -eq 0) { return $false }
    $adapterIndexes = @($adapters | ForEach-Object { $_.ifIndex })
    # Surfshark's OpenVPN DCO does not replace 0.0.0.0/0. It installs the more specific
    # pair 0.0.0.0/1 + 128.0.0.0/1, which together cover all of IPv4 and outrank the
    # physical adapter's default route. Testing only for 0.0.0.0/0 reported the tunnel
    # as down while it was in fact carrying every packet.
    $tunnelPrefixes = @('0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/1')
    $tunnelRoutes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object { $adapterIndexes -contains $_.ifIndex -and $tunnelPrefixes -contains $_.DestinationPrefix })
    return $tunnelRoutes.Count -gt 0
  } catch { return $false }
}

# Probes with curl because curl honours HTTP_PROXY exactly like agy does; .NET would read
# the Windows system proxy instead and report on a path agy never takes.
function Test-NetworkPath {
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (-not (Test-Path -LiteralPath $curl)) { return $true }
  $null = & $curl --silent --output NUL --max-time 15 'https://www.googleapis.com/generate_204' 2>$null
  return ($LASTEXITCODE -eq 0)
}

$networkMode = if ($Direct) { 'Direct' } else { $Network }
$routeResolver = Join-Path $PSScriptRoot 'agy-mode.ps1'
if (-not (Test-Path -LiteralPath $routeResolver -PathType Leaf)) {
  Exit-AgyRun -Code 9 -Message "network resolver missing: $routeResolver"
}
$resolvedRoute = @(& $routeResolver -Network $networkMode -V2rayEndpoint $Proxy 2>$null)
$route = if ($resolvedRoute.Count -gt 0) { ([string]$resolvedRoute[-1]).Trim() } else { '' }
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($route)) {
  Exit-AgyRun -Code 9 -Message "network resolver returned no route for $networkMode"
}
if ($route -like 'ERROR:*') {
  Exit-AgyRun -Code 9 -Message $route.Substring(6)
}

if ($route -eq 'DIRECT') {
  $env:HTTP_PROXY = $null
  $env:HTTPS_PROXY = $null
  $env:ALL_PROXY = $null
} else {
  $env:HTTP_PROXY = $route
  $env:HTTPS_PROXY = $route
  $env:ALL_PROXY = $null
}
$env:NO_PROXY = '127.0.0.1,localhost'
if ($networkMode -eq 'Auto') {
  try {
    $uri = [System.Uri]::new($route)
    $networkMode = if ($uri.Port -eq 10809) { 'Clash' } elseif ($uri.Port -eq 10808) { 'V2rayN' } else { "Proxy:$($uri.Port)" }
  } catch {
    $networkMode = 'Direct'
  }
}
Write-AgyDiagnostic "network: $networkMode$(if ($route -ne 'DIRECT') { " via $route" })"

if (-not $NoNetworkCheck) {
  if (-not (Test-NetworkPath)) {
    Exit-AgyRun -Code 9 -Message "no usable network path in $networkMode mode; this is a routing problem, not a token or agy failure"
  }
}

$resolvedAddDirs = @()
foreach ($directory in $AddDir) {
  $resolvedAddDirs += Resolve-ExistingPath -Path $directory -Description 'add-dir'
}

$resolvedRequiredPaths = @()
foreach ($required in $RequirePath) {
  $resolvedRequiredPaths += [System.IO.Path]::GetFullPath($required)
}

$resolvedOutputFile = $null
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
  $resolvedOutputFile = Resolve-OutputPath -Path $OutputFile
}

$agyArguments = @('-p', $Prompt, '--print-timeout', ("{0}s" -f $Timeout))
if ($Model) { $agyArguments += @('--model', $Model) }
foreach ($directory in $resolvedAddDirs) { $agyArguments += @('--add-dir', $directory) }
if ($SkipPerms) { $agyArguments += '--dangerously-skip-permissions' }
if ($Sandbox) { $agyArguments += '--sandbox' }
if ($Mode) { $agyArguments += @('--mode', $Mode) }
$script:DiagnosticLogIsTemp = [string]::IsNullOrWhiteSpace($AgyLogFile)
$script:DiagnosticLog = if ($script:DiagnosticLogIsTemp) { [System.IO.Path]::GetTempFileName() } else { Resolve-OutputPath -Path $AgyLogFile }
$agyArguments += @('--log-file', $script:DiagnosticLog)

# Pulls the real cause out of agy's log when stderr only carries the opaque line.
function Get-AgyFailureCause {
  if (-not (Test-Path -LiteralPath $script:DiagnosticLog)) { return $null }
  try {
    $errorLines = @(Get-Content -LiteralPath $script:DiagnosticLog -Encoding UTF8 -ErrorAction Stop |
      Where-Object { $_ -match '^[EW]\d{4}' } | Select-Object -Last 12)
  } catch { return $null }
  if ($errorLines.Count -eq 0) { return $null }
  $joined = $errorLines -join "`n"
  $kind = if ($joined -match $logNetworkPattern) { 'network' }
          elseif ($joined -match $logLocationPattern) { 'location' }
          elseif ($joined -match $logAuthPattern) { 'auth' }
          elseif ($joined -match $logQuotaPattern) { 'quota' }
          else { 'other' }
  # Report the line that drove the classification, not the last one. agy's final log line
  # is always the same opaque "run ended with error" summary, which explains nothing.
  $classifyingPattern = switch ($kind) {
    'network'  { $logNetworkPattern }
    'location' { $logLocationPattern }
    'auth'     { $logAuthPattern }
    'quota'    { $logQuotaPattern }
    default    { $null }
  }
  $headline = @()
  if ($classifyingPattern) {
    $headline = @($errorLines | Where-Object { $_ -match $classifyingPattern } | Select-Object -First 1)
  }
  if ($headline.Count -eq 0) {
    $headline = @($errorLines | Where-Object { $_ -match '^E\d{4}' } | Select-Object -Last 1)
  }
  [pscustomobject]@{
    Kind = $kind
    Headline = if ($headline.Count -gt 0) { $headline[0] } else { $errorLines[-1] }
  }
}

# Pre-flight: token freshness is per-call, so refresh right before dispatch rather than
# on a timer. The credential must survive this whole run, so the budget shrinks with
# -Timeout: a 9-minute task needs a much younger credential than a 30-second one.
if (-not $NoPreflight) {
  $safetyMarginSeconds = 300
  $freshnessBudget = $script:TokenTtlSeconds - $Timeout - $safetyMarginSeconds
  if ($freshnessBudget -lt 60) { $freshnessBudget = 60 }
  $credentialAge = Get-CredentialAgeSeconds
  if ($credentialAge -gt $freshnessBudget) {
    $ageText = if ($credentialAge -eq [int]::MaxValue) { 'unreadable' } else { "$([int]($credentialAge / 60))m old" }
    Write-AgyDiagnostic "preflight: credential is $ageText, budget is $([int]($freshnessBudget / 60))m; refreshing"
    if (-not (Invoke-AmSelfRefresh -MaxAgeSeconds $freshnessBudget)) {
      Write-AgyDiagnostic 'preflight refresh failed; dispatching anyway and relying on auth retries'
    }
  } else {
    Write-AgyDiagnostic "preflight: credential is $([int]($credentialAge / 60))m old, within the $([int]($freshnessBudget / 60))m budget"
  }
}

$authRetriesUsed = 0
$transientRetriesUsed = 0
$quotaRetriesUsed = 0
$script:QuotaAttemptedAccountIds = @{}
$attempt = 0

while ($true) {
  $attempt++
  if ($script:DiagnosticLogIsTemp) {
    Remove-Item -LiteralPath $script:DiagnosticLog -Force -ErrorAction SilentlyContinue
  }
  Write-AgyDiagnostic "starting attempt $attempt; timeout=${Timeout}s; hard-timeout=$($Timeout + $GraceSeconds)s"
  $result = Invoke-AgyOnce -Arguments $agyArguments -Attempt $attempt
  $combinedDiagnostics = "$($result.Stdout)`n$($result.Stderr)"

  # stderr alone cannot tell auth apart from a region block or a quota wall, so ask the
  # log whenever agy failed. Guessing here used to cost two pointless account switches
  # and then reported "authentication failed" for something that was never about auth.
  $failureCause = $null
  if ($result.ExitCode -ne 0 -or $combinedDiagnostics -match $opaqueFailure) {
    $failureCause = Get-AgyFailureCause
  }

  if ($null -ne $failureCause -and $failureCause.Kind -eq 'network') {
    Write-AgyDiagnostic "the transport failed in $networkMode mode; retrying or switching accounts cannot fix a dead route"
    Exit-AgyRun -Code 9 -Message $failureCause.Headline
  }

  if ($null -ne $failureCause -and $failureCause.Kind -eq 'location') {
    Write-AgyDiagnostic 'the backend rejected this request by region, which no retry or account switch can fix'
    Write-AgyDiagnostic 'check the proxy exit: some hosting providers are refused even in a supported country'
    Exit-AgyRun -Code 7 -Message $failureCause.Headline
  }

  # Quota is the ONLY failure a different account fixes. Region (7) and transport (9)
  # exit above this point, and auth is handled below by re-minting the active token --
  # so no other path can reach an account hop.
  if ($null -ne $failureCause -and $failureCause.Kind -eq 'quota') {
    if (-not $AllowAccountSwitch) {
      Write-AgySwitchEvent -Performed $false -Reason 'not-allowed'
      Exit-AgyRun -Code 8 -Message $failureCause.Headline
    }
    if ($quotaRetriesUsed -ge $QuotaRetries) {
      # Second quota hit: the replacement account is exhausted too. Stopping here is what
      # prevents ping-pong between two accounts that are both out of budget.
      Write-AgySwitchEvent -Performed $false -Reason "retry-budget-spent($quotaRetriesUsed/$QuotaRetries)"
      Exit-AgyRun -Code 8 -Message $failureCause.Headline
    }
    $quotaRetriesUsed++
    Write-AgyDiagnostic "quota exhausted; attempting account switch $quotaRetriesUsed of $QuotaRetries"
    if (Invoke-AmOtherAccountSwitch -TrackQuotaAttempts) {
      continue
    }
    Write-AgySwitchEvent -Performed $false -Reason 'no-untried-enabled-account'
    Exit-AgyRun -Code 8 -Message $failureCause.Headline
  }

  $isAuthFailure = ($combinedDiagnostics -match $authPattern) -or
    ($null -ne $failureCause -and $failureCause.Kind -eq 'auth')

  if ($isAuthFailure) {
    if ($authRetriesUsed -lt $AuthRetries) {
      $authRetriesUsed++
      Write-AgyDiagnostic "authentication required; refreshing and retrying ($authRetriesUsed/$AuthRetries)"
      Invoke-AgyRefresh -AttemptIndex $authRetriesUsed
      continue
    }
    if (-not [string]::IsNullOrWhiteSpace($result.Stdout)) { Write-Output $result.Stdout }
    if (-not [string]::IsNullOrWhiteSpace($result.Stderr)) { [Console]::Error.WriteLine($result.Stderr.TrimEnd()) }
    Exit-AgyRun -Code 1 -Message "authentication failed after $attempt attempt(s)"
  }

  if ($null -ne $failureCause -and $failureCause.Kind -eq 'other') {
    Write-AgyDiagnostic "agy reported: $($failureCause.Headline)"
  }

  $isTransientFailure = ($combinedDiagnostics -match $transientPattern) -or [string]::IsNullOrWhiteSpace($result.Stdout)
  if (($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Stdout)) -and
      $isTransientFailure -and $transientRetriesUsed -lt $TransientRetries) {
    $transientRetriesUsed++
    $delaySeconds = [Math]::Min(5 * $transientRetriesUsed, 20)
    Write-AgyDiagnostic "transient failure; retrying in ${delaySeconds}s ($transientRetriesUsed/$TransientRetries)"
    Start-Sleep -Seconds $delaySeconds
    continue
  }

  if ($result.ExitCode -ne 0) {
    if (-not [string]::IsNullOrWhiteSpace($result.Stdout)) { Write-Output $result.Stdout }
    if (-not [string]::IsNullOrWhiteSpace($result.Stderr)) { [Console]::Error.WriteLine($result.Stderr.TrimEnd()) }
    Exit-AgyRun -Code $result.ExitCode -Message "agy.exe failed after $($result.ElapsedSeconds)s with code $($result.ExitCode)"
  }

  if ([string]::IsNullOrWhiteSpace($result.Stdout)) {
    if (-not [string]::IsNullOrWhiteSpace($result.Stderr)) { [Console]::Error.WriteLine($result.Stderr.TrimEnd()) }
    Exit-AgyRun -Code 2 -Message 'agy.exe exited with code 0 but produced no stdout'
  }

  $trimmedOutput = $result.Stdout.Trim()
  if ($trimmedOutput.Length -lt $MinOutputChars) {
    Exit-AgyRun -Code 3 -Message "stdout length $($trimmedOutput.Length) is below MinOutputChars=$MinOutputChars"
  }

  if ($RequireJson) {
    try {
      $null = $trimmedOutput | ConvertFrom-Json -ErrorAction Stop
    } catch {
      Exit-AgyRun -Code 4 -Message "stdout is not valid JSON: $($_.Exception.Message)"
    }
  }

  foreach ($requiredPath in $resolvedRequiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
      Exit-AgyRun -Code 5 -Message "required path was not produced: $requiredPath"
    }
  }

  if ($resolvedOutputFile) {
    try {
      $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
      [System.IO.File]::WriteAllText($resolvedOutputFile, $result.Stdout, $utf8WithoutBom)
    } catch {
      Exit-AgyRun -Code 6 -Message "failed to write output file ${resolvedOutputFile}: $($_.Exception.Message)"
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($result.Stderr)) {
    [Console]::Error.WriteLine($result.Stderr.TrimEnd())
  }
  Write-AgyDiagnostic "completed attempt $attempt in $($result.ElapsedSeconds)s; stdout-chars=$($trimmedOutput.Length)"
  Write-Output $result.Stdout
  exit 0
}
