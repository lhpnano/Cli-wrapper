Set-StrictMode -Version 2.0

$script:CliRunUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:CliTransientPattern = 'network|connection|connection reset|connection refused|EOF|timed? out|timeout|temporarily unavailable|overloaded|rate limit|HTTP\s+(408|409|425|429|500|502|503|504)'

function Write-CliRunDiagnostic {
  param(
    [string]$Label,
    [string]$Message
  )
  [Console]::Error.WriteLine("[$Label] $Message")
}

function Protect-CliDiagnosticText {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $protected = $Text -replace '(?i)Bearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [REDACTED]'
  $protected = $protected -replace '(?i)\b(sk|key|token)-[A-Za-z0-9_-]{8,}\b', '$1-[REDACTED]'
  $protected
}

function ConvertTo-CliArgumentString {
  param([string[]]$Arguments)
  ($Arguments | ForEach-Object {
    $argument = [string]$_
    if ($argument -eq '') {
      '""'
    } elseif ($argument -notmatch '[\s"]') {
      $argument
    } else {
      $quoted = '"'
      $slashes = 0
      foreach ($character in $argument.ToCharArray()) {
        if ($character -eq '\') {
          $slashes++
        } elseif ($character -eq '"') {
          $quoted += ('\' * (($slashes * 2) + 1)) + '"'
          $slashes = 0
        } else {
          if ($slashes -gt 0) {
            $quoted += ('\' * $slashes)
            $slashes = 0
          }
          $quoted += $character
        }
      }
      if ($slashes -gt 0) { $quoted += ('\' * ($slashes * 2)) }
      $quoted += '"'
      $quoted
    }
  }) -join ' '
}

function Resolve-CliExistingPath {
  param(
    [string]$Path,
    [string]$Description
  )
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Description path is empty"
  }
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Description does not exist: $Path"
  }
  (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-CliOutputPath {
  param([string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $parent = Split-Path -Parent $fullPath
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $fullPath
}

function Write-CliJsonFile {
  param(
    [string]$Path,
    [object]$Value
  )
  $json = ConvertTo-Json -InputObject $Value -Depth 20
  $temporaryPath = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
  [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $script:CliRunUtf8)
  Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function New-CliRunDirectory {
  param(
    [string]$Label,
    [string]$RunRoot
  )
  $resolvedRoot = if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    Join-Path $env:LOCALAPPDATA 'ai-cli-runs'
  } else {
    [System.IO.Path]::GetFullPath($RunRoot)
  }
  $labelRoot = Join-Path $resolvedRoot $Label
  New-Item -ItemType Directory -Path $labelRoot -Force | Out-Null
  $directoryName = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
  $runDirectory = Join-Path $labelRoot $directoryName
  New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
  $runDirectory
}

function Resolve-CliCommandSpec {
  param(
    [string]$CommandName,
    [string]$CliPath
  )
  $resolvedPath = $null
  if (-not [string]::IsNullOrWhiteSpace($CliPath)) {
    $resolvedPath = Resolve-CliExistingPath -Path $CliPath -Description 'CLI path'
  } else {
    $command = Get-Command "$CommandName.cmd" -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command "$CommandName.ps1" -ErrorAction SilentlyContinue }
    if ($null -eq $command) { $command = Get-Command $CommandName -ErrorAction SilentlyContinue }
    if ($null -eq $command) { throw "$CommandName executable was not found on PATH" }
    $resolvedPath = $command.Source
  }

  $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
  if ($extension -eq '.ps1') {
    return [pscustomobject]@{
      FilePath = (Join-Path $PSHOME 'powershell.exe')
      PrefixArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolvedPath)
      ResolvedCliPath = $resolvedPath
    }
  }
  if ($extension -eq '.cmd' -or $extension -eq '.bat') {
    return [pscustomobject]@{
      FilePath = $env:ComSpec
      PrefixArguments = @('/d', '/c', 'call', $resolvedPath)
      ResolvedCliPath = $resolvedPath
    }
  }
  [pscustomobject]@{
    FilePath = $resolvedPath
    PrefixArguments = @()
    ResolvedCliPath = $resolvedPath
  }
}

function Stop-CliProcessTree {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Label
  )
  if ($null -eq $Process) { return }
  try {
    if ($Process.HasExited) { return }
  } catch { return }

  try {
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $killInfo = New-Object System.Diagnostics.ProcessStartInfo
    $killInfo.FileName = $taskkill
    $killInfo.Arguments = "/PID $($Process.Id) /T /F"
    $killInfo.UseShellExecute = $false
    $killInfo.CreateNoWindow = $true
    $killInfo.RedirectStandardOutput = $true
    $killInfo.RedirectStandardError = $true
    $killer = [System.Diagnostics.Process]::Start($killInfo)
    $killer.WaitForExit(10000) | Out-Null
    $killer.Dispose()
  } catch {
    Write-CliRunDiagnostic -Label $Label -Message "process-tree stop failed; falling back to parent kill: $($_.Exception.Message)"
    try { $Process.Kill() } catch {}
  }
}

function Invoke-CliProcess {
  param(
    [string]$Label,
    [object]$CommandSpec,
    [string[]]$Arguments,
    [string]$StdinText,
    [string]$WorkingDirectory,
    [int]$TimeoutSeconds,
    [int]$HeartbeatSeconds,
    [string]$AttemptDirectory,
    [int]$Attempt
  )

  $process = $null
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $timedOut = $false
  $processStatePath = Join-Path $AttemptDirectory 'process-state.json'
  $stdoutPath = Join-Path $AttemptDirectory 'stdout.txt'
  $stderrPath = Join-Path $AttemptDirectory 'stderr.txt'

  try {
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $CommandSpec.FilePath
    $processInfo.Arguments = ConvertTo-CliArgumentString -Arguments (@($CommandSpec.PrefixArguments) + @($Arguments))
    $processInfo.WorkingDirectory = $WorkingDirectory
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $previousInputEncoding = [Console]::InputEncoding
    try {
      [Console]::InputEncoding = $script:CliRunUtf8
      if (-not $process.Start()) { throw 'failed to start CLI process' }
      $stdinWriter = $process.StandardInput
    } finally {
      [Console]::InputEncoding = $previousInputEncoding
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $StdinText) { $stdinWriter.Write($StdinText) }
    $stdinWriter.Flush()
    $stdinWriter.Close()

    $startedAt = (Get-Date).ToString('o')
    Write-CliJsonFile -Path $processStatePath -Value ([ordered]@{
      status = 'running'
      pid = $process.Id
      attempt = $Attempt
      stdin_chars = if ($null -eq $StdinText) { 0 } else { $StdinText.Length }
      started_at = $startedAt
      last_heartbeat_at = $startedAt
      timeout_seconds = $TimeoutSeconds
    })

    $nextHeartbeat = $HeartbeatSeconds
    while (-not $process.WaitForExit(1000)) {
      $elapsedSeconds = [int][Math]::Floor($stopwatch.Elapsed.TotalSeconds)
      if ($TimeoutSeconds -gt 0 -and $elapsedSeconds -ge $TimeoutSeconds) {
        $timedOut = $true
        Write-CliRunDiagnostic -Label $Label -Message "hard timeout after ${TimeoutSeconds}s; stopping process tree PID $($process.Id)"
        Stop-CliProcessTree -Process $process -Label $Label
        try { $process.WaitForExit(10000) | Out-Null } catch {}
        break
      }
      if ($HeartbeatSeconds -gt 0 -and $elapsedSeconds -ge $nextHeartbeat) {
        $heartbeatAt = (Get-Date).ToString('o')
        Write-CliRunDiagnostic -Label $Label -Message "running attempt $Attempt, elapsed ${elapsedSeconds}s, PID $($process.Id)"
        Write-CliJsonFile -Path $processStatePath -Value ([ordered]@{
          status = 'running'
          pid = $process.Id
          attempt = $Attempt
          started_at = $startedAt
          last_heartbeat_at = $heartbeatAt
          elapsed_seconds = $elapsedSeconds
          timeout_seconds = $TimeoutSeconds
        })
        $nextHeartbeat += $HeartbeatSeconds
      }
    }

    if (-not $timedOut) { $process.WaitForExit() }
    try { [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 10000) | Out-Null } catch {}
    $stdout = if ($stdoutTask.IsCompleted) { [string]$stdoutTask.Result } else { '' }
    $stderr = if ($stderrTask.IsCompleted) { [string]$stderrTask.Result } else { 'output capture did not complete' }
    $stderr = Protect-CliDiagnosticText -Text $stderr
    $exitCode = if ($timedOut) { 124 } else { [int]$process.ExitCode }
    $stopwatch.Stop()

    [System.IO.File]::WriteAllText($stdoutPath, $stdout, $script:CliRunUtf8)
    [System.IO.File]::WriteAllText($stderrPath, $stderr, $script:CliRunUtf8)
    Write-CliJsonFile -Path $processStatePath -Value ([ordered]@{
      status = if ($timedOut) { 'timed_out' } elseif ($exitCode -eq 0) { 'completed' } else { 'failed' }
      pid = $process.Id
      attempt = $Attempt
      started_at = $startedAt
      finished_at = (Get-Date).ToString('o')
      elapsed_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
      exit_code = $exitCode
      timed_out = $timedOut
      stdin_chars = if ($null -eq $StdinText) { 0 } else { $StdinText.Length }
      stdout_chars = $stdout.Length
      stderr_chars = $stderr.Length
    })

    [pscustomobject]@{
      Stdout = $stdout
      Stderr = $stderr
      ExitCode = $exitCode
      TimedOut = $timedOut
      ElapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
      Pid = $process.Id
      AttemptDirectory = $AttemptDirectory
    }
  } catch {
    $stopwatch.Stop()
    $message = Protect-CliDiagnosticText -Text $_.Exception.Message
    [System.IO.File]::WriteAllText($stderrPath, $message, $script:CliRunUtf8)
    Write-CliJsonFile -Path $processStatePath -Value ([ordered]@{
      status = 'failed'
      attempt = $Attempt
      finished_at = (Get-Date).ToString('o')
      elapsed_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
      exit_code = 1
      error = $message
    })
    [pscustomobject]@{
      Stdout = ''
      Stderr = $message
      ExitCode = 1
      TimedOut = $false
      ElapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
      Pid = if ($process) { $process.Id } else { $null }
      AttemptDirectory = $AttemptDirectory
    }
  } finally {
    if ($process) { $process.Dispose() }
  }
}

# Network routing, mirroring agy-run.ps1. Codex reaches its provider over a long-lived
# streaming connection: short requests survive an unproxied path while the stream gets
# cut mid-flight, which surfaces as "stream disconnected before completion" rather than
# anything that looks like a network error. Neither CLI carries proxy settings of its
# own, so the wrapper supplies them -- on this process only, never in HKCU.
function Test-CliProxyListening {
  param([string]$Url)
  try {
    $uri = [System.Uri]::new($Url)
    $client = New-Object System.Net.Sockets.TcpClient
    $listening = $client.ConnectAsync($uri.Host, $uri.Port).Wait(500)
    $client.Close()
    return $listening
  } catch { return $false }
}

# The VPN service runs whether or not the tunnel is up, so the process list proves
# nothing. An adapter that is Up AND owns a default route does.
function Set-CliNetworkRoute {
  param(
    [string]$Network = 'Auto',
    [string]$V2rayEndpoint = 'http://127.0.0.1:10808'
  )
  $resolver = Join-Path $PSScriptRoot 'cli-network-sync.ps1'
  if (-not (Test-Path -LiteralPath $resolver -PathType Leaf)) {
    return [pscustomobject]@{ Mode = $Network; Ok = $false; Reason = "network resolver missing: $resolver" }
  }
  try {
    $resolved = @(& $resolver -Network $Network -V2rayEndpoint $V2rayEndpoint 2>$null)
    $route = if ($resolved.Count -gt 0) { ([string]$resolved[-1]).Trim() } else { '' }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($route)) {
      return [pscustomobject]@{ Mode = $Network; Ok = $false; Reason = 'network resolver returned no usable route' }
    }
    if ($route -like 'ERROR:*') {
      return [pscustomobject]@{ Mode = $Network; Ok = $false; Reason = $route.Substring(6) }
    }
    $mode = if ($route -eq 'DIRECT') {
      if ($Network -eq 'Auto') {
        $surfRoute = @(& $resolver -Network Surfshark -V2rayEndpoint $V2rayEndpoint 2>$null)
        if ($surfRoute.Count -gt 0 -and ([string]$surfRoute[-1]).Trim() -eq 'DIRECT') { 'Surfshark' } else { 'Direct' }
      } else { $Network }
    } else { 'V2rayN' }
    if ($route -eq 'DIRECT') {
      $env:HTTP_PROXY = $null
      $env:HTTPS_PROXY = $null
      $env:ALL_PROXY = $null
    } else {
      $env:HTTP_PROXY = $route
      $env:HTTPS_PROXY = $route
      $env:ALL_PROXY = $null
    }
  } catch {
    return [pscustomobject]@{ Mode = $Network; Ok = $false; Reason = "network resolver failed: $($_.Exception.Message)" }
  }
  if ([string]::IsNullOrWhiteSpace($env:NO_PROXY)) { $env:NO_PROXY = '127.0.0.1,localhost' }
  return [pscustomobject]@{ Mode = $mode; Ok = $true; Reason = '' }
}

function Invoke-ReliableCliRun {
  param(
    [string]$Label,
    [string]$CommandName,
    [string]$CliPath,
    [string[]]$Arguments,
    [string]$Prompt,
    [string]$WorkingDirectory,
    [int]$TimeoutSeconds,
    [int]$HeartbeatSeconds,
    [int]$TransientRetries,
    [int]$MinOutputChars,
    [bool]$RequireJson,
    [string[]]$RequirePath,
    [string]$OutputFile,
    [string]$RunRoot,
    [string]$Network = 'Auto',
    [string]$V2rayEndpoint = 'http://127.0.0.1:10808'
  )

  $route = Set-CliNetworkRoute -Network $Network -V2rayEndpoint $V2rayEndpoint
  if (-not $route.Ok) {
    Write-CliRunDiagnostic -Label $Label -Message $route.Reason
    exit 9
  }
  Write-CliRunDiagnostic -Label $Label -Message "network: $($route.Mode)"

  $resolvedWorkingDirectory = Resolve-CliExistingPath -Path $WorkingDirectory -Description 'working directory'
  $commandSpec = Resolve-CliCommandSpec -CommandName $CommandName -CliPath $CliPath
  $runDirectory = New-CliRunDirectory -Label $Label -RunRoot $RunRoot
  $runStatePath = Join-Path $runDirectory 'run-state.json'
  $resolvedRequiredPaths = @($RequirePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [System.IO.Path]::GetFullPath($_) })
  $resolvedOutputFile = if ([string]::IsNullOrWhiteSpace($OutputFile)) { $null } else { Resolve-CliOutputPath -Path $OutputFile }
  $startedAt = (Get-Date).ToString('o')

  $state = [ordered]@{
    tool = $Label
    status = 'starting'
    started_at = $startedAt
    updated_at = $startedAt
    working_directory = $resolvedWorkingDirectory
    resolved_cli_path = $commandSpec.ResolvedCliPath
    network_mode = $route.Mode
    timeout_seconds = $TimeoutSeconds
    prompt_chars = if ($null -eq $Prompt) { 0 } else { $Prompt.Length }
    heartbeat_seconds = $HeartbeatSeconds
    transient_retries = $TransientRetries
    active_operation = $null
    attempts = @()
  }
  Write-CliJsonFile -Path $runStatePath -Value $state
  Write-CliRunDiagnostic -Label $Label -Message "run directory: $runDirectory"

  $finalResult = $null
  for ($attempt = 1; $attempt -le ($TransientRetries + 1); $attempt++) {
    $attemptDirectory = Join-Path $runDirectory ('attempt-{0:d3}' -f $attempt)
    New-Item -ItemType Directory -Path $attemptDirectory -Force | Out-Null
    $state.status = 'running'
    $state.updated_at = (Get-Date).ToString('o')
    $state.active_operation = [ordered]@{ attempt = $attempt; status = 'running'; attempt_directory = $attemptDirectory }
    Write-CliJsonFile -Path $runStatePath -Value $state
    Write-CliRunDiagnostic -Label $Label -Message "starting attempt $attempt; hard-timeout=${TimeoutSeconds}s"

    $result = Invoke-CliProcess -Label $Label -CommandSpec $commandSpec -Arguments $Arguments `
      -StdinText $Prompt -WorkingDirectory $resolvedWorkingDirectory -TimeoutSeconds $TimeoutSeconds `
      -HeartbeatSeconds $HeartbeatSeconds -AttemptDirectory $attemptDirectory -Attempt $attempt

    $state.attempts += @([ordered]@{
      attempt = $attempt
      exit_code = $result.ExitCode
      timed_out = $result.TimedOut
      elapsed_seconds = $result.ElapsedSeconds
      stdout_chars = $result.Stdout.Length
      stderr_chars = $result.Stderr.Length
      attempt_directory = $attemptDirectory
    })
    $combinedDiagnostics = "$($result.Stdout)`n$($result.Stderr)"
    $failed = $result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Stdout)
    $transient = $result.TimedOut -or [string]::IsNullOrWhiteSpace($result.Stdout) -or $combinedDiagnostics -match $script:CliTransientPattern
    if ($failed -and $transient -and $attempt -le $TransientRetries) {
      $delaySeconds = [Math]::Min(5 * $attempt, 20)
      $state.status = 'retry_wait'
      $state.updated_at = (Get-Date).ToString('o')
      $state.active_operation = [ordered]@{ attempt = $attempt; status = 'retry_wait'; delay_seconds = $delaySeconds }
      Write-CliJsonFile -Path $runStatePath -Value $state
      Write-CliRunDiagnostic -Label $Label -Message "transient failure; retrying in ${delaySeconds}s ($attempt/$TransientRetries)"
      Start-Sleep -Seconds $delaySeconds
      continue
    }
    $finalResult = $result
    break
  }

  if ($null -eq $finalResult) { throw 'CLI run ended without a final result' }
  $failureCode = 0
  $failureMessage = ''
  if ($finalResult.ExitCode -ne 0) {
    $failureCode = $finalResult.ExitCode
    $failureMessage = "$CommandName failed with code $($finalResult.ExitCode)"
  } elseif ([string]::IsNullOrWhiteSpace($finalResult.Stdout)) {
    $failureCode = 2
    $failureMessage = "$CommandName exited with code 0 but produced no stdout"
  } else {
    $trimmedOutput = $finalResult.Stdout.Trim()
    if ($trimmedOutput.Length -lt $MinOutputChars) {
      $failureCode = 3
      $failureMessage = "stdout length $($trimmedOutput.Length) is below MinOutputChars=$MinOutputChars"
    } elseif ($RequireJson) {
      try { $null = $trimmedOutput | ConvertFrom-Json -ErrorAction Stop }
      catch {
        $failureCode = 4
        $failureMessage = "stdout is not valid JSON: $($_.Exception.Message)"
      }
    }
  }

  if ($failureCode -eq 0) {
    foreach ($requiredPath in $resolvedRequiredPaths) {
      if (-not (Test-Path -LiteralPath $requiredPath)) {
        $failureCode = 5
        $failureMessage = "required path was not produced: $requiredPath"
        break
      }
    }
  }

  if ($failureCode -eq 0 -and $resolvedOutputFile) {
    try { [System.IO.File]::WriteAllText($resolvedOutputFile, $finalResult.Stdout, $script:CliRunUtf8) }
    catch {
      $failureCode = 6
      $failureMessage = "failed to write output file ${resolvedOutputFile}: $($_.Exception.Message)"
    }
  }

  [System.IO.File]::WriteAllText((Join-Path $runDirectory 'stdout.txt'), $finalResult.Stdout, $script:CliRunUtf8)
  [System.IO.File]::WriteAllText((Join-Path $runDirectory 'stderr.txt'), $finalResult.Stderr, $script:CliRunUtf8)
  $state.status = if ($failureCode -eq 0) { 'completed' } elseif ($failureCode -eq 124) { 'timed_out' } else { 'failed' }
  $state.updated_at = (Get-Date).ToString('o')
  $state.finished_at = $state.updated_at
  $state.active_operation = $null
  $state.exit_code = $failureCode
  $state.failure = if ($failureMessage) { $failureMessage } else { $null }
  $state.output_file = $resolvedOutputFile
  Write-CliJsonFile -Path $runStatePath -Value $state

  [pscustomobject]@{
    Stdout = $finalResult.Stdout
    Stderr = $finalResult.Stderr
    ExitCode = $failureCode
    FailureMessage = $failureMessage
    ElapsedSeconds = $finalResult.ElapsedSeconds
    RunDirectory = $runDirectory
    OutputFile = $resolvedOutputFile
  }
}

function Complete-CliRun {
  param(
    [string]$Label,
    [object]$Result
  )
  if (-not [string]::IsNullOrWhiteSpace($Result.Stderr)) {
    [Console]::Error.WriteLine($Result.Stderr.TrimEnd())
  }
  if ($Result.ExitCode -ne 0) {
    if (-not [string]::IsNullOrWhiteSpace($Result.Stdout)) { Write-Output $Result.Stdout }
    Write-CliRunDiagnostic -Label $Label -Message "$($Result.FailureMessage); run directory: $($Result.RunDirectory)"
    exit $Result.ExitCode
  }
  Write-CliRunDiagnostic -Label $Label -Message "completed in $($Result.ElapsedSeconds)s; run directory: $($Result.RunDirectory)"
  Write-Output $Result.Stdout
  exit 0
}
