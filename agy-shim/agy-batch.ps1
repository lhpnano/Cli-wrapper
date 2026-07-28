<#
.SYNOPSIS
Runs a manifest-driven, resumable Agy batch task.

.DESCRIPTION
Splits low-risk read-only work into independently verifiable JSON batches.
Each item must have a unique id. A failed batch is retried once, then bisected.
Repeated failures stop with exit code 20 so Codex can take over.

.PARAMETER Manifest
Path to a UTF-8 JSON manifest.

.PARAMETER ValidateOnly
Validates and normalizes the manifest without creating a run directory or
calling Agy.

.NOTES
Exit codes: 0 complete or manifest valid; 10 invalid worker product;
20 Codex takeover required; 64 invalid manifest; 65 unsafe manifest.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$Manifest,

  [switch]$ValidateOnly,

  [string]$WorkerPath
)

$ErrorActionPreference = 'Stop'
$agyRun = if ([string]::IsNullOrWhiteSpace($WorkerPath)) {
  Join-Path $PSScriptRoot 'agy-run.ps1'
} else {
  [System.IO.Path]::GetFullPath($WorkerPath)
}
$workerHost = Join-Path $PSScriptRoot 'agy-worker-host.ps1'
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)

function Write-BatchDiagnostic {
  param([string]$Message)
  [Console]::Error.WriteLine("[agy-batch] $Message")
}

function Stop-Batch {
  param(
    [int]$Code,
    [string]$Message
  )
  if ($Message) { Write-BatchDiagnostic $Message }
  exit $Code
}

function Get-ConfigValue {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default
  )
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  $property.Value
}

function Get-FullPath {
  param(
    [string]$Path,
    [string]$BasePath
  )
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Test-PathInside {
  param(
    [string]$Child,
    [string]$Parent
  )
  $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
  $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd('\')
  if ($childFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  $childFull.StartsWith($parentFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value,
    [int]$Depth = 30
  )
  $json = ConvertTo-Json -InputObject $Value -Depth $Depth
  [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8WithoutBom)
}

function New-BatchObject {
  param(
    [string]$Id,
    [string[]]$ItemIds,
    [int]$Depth,
    [int]$Attempt = 0
  )
  [pscustomobject]@{
    batch_id = $Id
    item_ids = @($ItemIds)
    depth = $Depth
    attempt = $Attempt
  }
}

function Invoke-WorkerProcess {
  param(
    [string]$ArgumentLine,
    [string]$StdoutPath,
    [string]$StderrPath,
    [string]$BatchId
  )
  $powershellExe = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
  } else {
    Join-Path $PSHOME 'powershell.exe'
  }
  $processInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processInfo.FileName = $powershellExe
  $processInfo.Arguments = $ArgumentLine
  $processInfo.UseShellExecute = $false
  $processInfo.CreateNoWindow = $true
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $processInfo
  $stdoutTask = $null
  $stderrTask = $null
  try {
    if (-not $process.Start()) { throw 'failed to start worker process' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextHeartbeat = $heartbeatSeconds
    $outerHardTimeout = $timeoutSeconds + 60
    $forcedTimeout = $false
    while (-not $process.WaitForExit(1000)) {
      $elapsedSeconds = [int][Math]::Floor($stopwatch.Elapsed.TotalSeconds)
      if ($elapsedSeconds -ge $outerHardTimeout) {
        Write-BatchDiagnostic "$BatchId worker exceeded outer hard timeout ${outerHardTimeout}s; stopping PID $($process.Id)"
        try { $process.Kill() } catch {}
        try { $process.WaitForExit(5000) | Out-Null } catch {}
        $forcedTimeout = $true
        break
      }
      if ($heartbeatSeconds -gt 0 -and $elapsedSeconds -ge $nextHeartbeat) {
        Write-BatchDiagnostic "$BatchId running, elapsed ${elapsedSeconds}s, worker PID $($process.Id)"
        $nextHeartbeat += $heartbeatSeconds
      }
    }
    $process.WaitForExit()
    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
    [System.IO.File]::WriteAllText($StdoutPath, [string]$stdoutTask.Result, $utf8WithoutBom)
    [System.IO.File]::WriteAllText($StderrPath, [string]$stderrTask.Result, $utf8WithoutBom)
    $workerProcessExitCode = if ($forcedTimeout) { 124 } else { [int]$process.ExitCode }
    Write-BatchDiagnostic "$BatchId worker process exited with code $workerProcessExitCode"
    return $workerProcessExitCode
  } catch {
    [System.IO.File]::WriteAllText($StderrPath, "[agy-batch] worker host error: $($_.Exception.Message)", $utf8WithoutBom)
    Write-BatchDiagnostic "$BatchId worker host error: $($_.Exception.Message)"
    return 1
  } finally {
    if ($null -ne $stopwatch) { $stopwatch.Stop() }
    $process.Dispose()
  }
}

function Split-BatchObject {
  param([object]$Batch)
  $ids = @($Batch.item_ids)
  $middle = [int][Math]::Ceiling($ids.Count / 2.0)
  $left = @($ids[0..($middle - 1)])
  $right = @($ids[$middle..($ids.Count - 1)])
  @(
    (New-BatchObject -Id "$($Batch.batch_id)a" -ItemIds $left -Depth ($Batch.depth + 1)),
    (New-BatchObject -Id "$($Batch.batch_id)b" -ItemIds $right -Depth ($Batch.depth + 1))
  )
}

function Build-WorkerPrompt {
  param(
    [string]$Instruction,
    [object[]]$BatchItems
  )
  $inputJson = ConvertTo-Json -InputObject @($BatchItems) -Depth 30 -Compress
  @"
You are a deterministic batch worker controlled by Codex.

TASK
$Instruction

OUTPUT CONTRACT
- Process every input item exactly once.
- Return exactly one JSON array and no Markdown or commentary.
- Return exactly $($BatchItems.Count) output objects.
- Every output object must contain the original "id" unchanged.
- Do not invent, remove, merge, or duplicate ids.
- Do not modify files, execute commands, publish, send messages, or change external systems.
- If an item cannot be processed, return its id with an "error" field instead of omitting it.

INPUT_JSON
$inputJson
"@
}

function Test-WorkerOutput {
  param(
    [string]$Path,
    [string[]]$ExpectedIds
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{ Valid = $false; Reason = 'worker output file is missing'; Items = @() }
  }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    $outputItems = @($parsed)
  } catch {
    return [pscustomobject]@{ Valid = $false; Reason = "invalid JSON: $($_.Exception.Message)"; Items = @() }
  }
  if ($outputItems.Count -ne $ExpectedIds.Count) {
    return [pscustomobject]@{ Valid = $false; Reason = "count mismatch: expected $($ExpectedIds.Count), got $($outputItems.Count)"; Items = @() }
  }
  $seen = @{}
  foreach ($item in $outputItems) {
    $idProperty = $item.PSObject.Properties['id']
    if ($null -eq $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
      return [pscustomobject]@{ Valid = $false; Reason = 'an output item has no id'; Items = @() }
    }
    $id = [string]$idProperty.Value
    if ($seen.ContainsKey($id)) {
      return [pscustomobject]@{ Valid = $false; Reason = "duplicate output id: $id"; Items = @() }
    }
    $seen[$id] = $true
  }
  foreach ($expectedId in $ExpectedIds) {
    if (-not $seen.ContainsKey([string]$expectedId)) {
      return [pscustomobject]@{ Valid = $false; Reason = "missing output id: $expectedId"; Items = @() }
    }
  }
  [pscustomobject]@{ Valid = $true; Reason = ''; Items = @($outputItems) }
}

if (-not (Test-Path -LiteralPath $agyRun -PathType Leaf)) {
  Stop-Batch -Code 127 -Message "agy-run worker not found: $agyRun"
}
if (-not (Test-Path -LiteralPath $workerHost -PathType Leaf)) {
  Stop-Batch -Code 127 -Message "worker host not found: $workerHost"
}
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
  Stop-Batch -Code 64 -Message "manifest does not exist: $Manifest"
}

$manifestPath = (Resolve-Path -LiteralPath $Manifest).Path
$manifestDirectory = Split-Path -Parent $manifestPath
try {
  $config = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
} catch {
  Stop-Batch -Code 64 -Message "manifest is not valid JSON: $($_.Exception.Message)"
}

$version = [int](Get-ConfigValue -Object $config -Name 'version' -Default 1)
if ($version -ne 1) { Stop-Batch -Code 64 -Message "unsupported manifest version: $version" }

$taskId = [string](Get-ConfigValue -Object $config -Name 'task_id' -Default '')
if ($taskId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
  Stop-Batch -Code 64 -Message 'task_id must be 1-80 safe ASCII characters'
}

$instruction = [string](Get-ConfigValue -Object $config -Name 'instruction' -Default '')
if ([string]::IsNullOrWhiteSpace($instruction)) { Stop-Batch -Code 64 -Message 'instruction is required' }
if ($instruction.Length -gt 12000) { Stop-Batch -Code 64 -Message 'instruction exceeds 12000 characters' }

$itemsValue = Get-ConfigValue -Object $config -Name 'items' -Default $null
if ($null -eq $itemsValue) { Stop-Batch -Code 64 -Message 'items array is required' }
$items = @($itemsValue)
if ($items.Count -eq 0) { Stop-Batch -Code 64 -Message 'items array is empty' }

$itemMap = @{}
$orderedIds = New-Object System.Collections.ArrayList
foreach ($item in $items) {
  $idProperty = $item.PSObject.Properties['id']
  if ($null -eq $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
    Stop-Batch -Code 64 -Message 'every input item must have a non-empty id'
  }
  $id = [string]$idProperty.Value
  if ($itemMap.ContainsKey($id)) { Stop-Batch -Code 64 -Message "duplicate input id: $id" }
  $itemMap[$id] = $item
  [void]$orderedIds.Add($id)
}

$itemType = ([string](Get-ConfigValue -Object $config -Name 'item_type' -Default 'record')).ToLowerInvariant()
$complexity = ([string](Get-ConfigValue -Object $config -Name 'complexity' -Default 'routine')).ToLowerInvariant()
if ($complexity -notin @('routine', 'high')) {
  Stop-Batch -Code 64 -Message 'complexity must be routine or high'
}
$routineBatchDefaults = @{ file = 5; page = 8; record = 30 }
$highBatchDefaults = @{ file = 3; page = 5; record = 20 }
$batchDefaults = if ($complexity -eq 'high') { $highBatchDefaults } else { $routineBatchDefaults }
$batchMaximums = @{ file = 8; page = 10; record = 50 }
if (-not $batchDefaults.ContainsKey($itemType)) {
  Stop-Batch -Code 64 -Message 'item_type must be file, page, or record'
}
$batchSize = [int](Get-ConfigValue -Object $config -Name 'batch_size' -Default $batchDefaults[$itemType])
if ($batchSize -lt 1 -or $batchSize -gt $batchMaximums[$itemType]) {
  Stop-Batch -Code 64 -Message "batch_size for $itemType must be between 1 and $($batchMaximums[$itemType])"
}

$configuredModel = [string](Get-ConfigValue -Object $config -Name 'model' -Default '')
if ([string]::IsNullOrWhiteSpace($configuredModel)) {
  $model = if ($complexity -eq 'high') { 'Gemini 3.1 Pro (High)' } else { 'Gemini 3.6 Flash (High)' }
  $modelSelection = 'auto'
} else {
  $model = $configuredModel
  $modelSelection = 'explicit'
}
$defaultTimeoutSeconds = if ($complexity -eq 'high') { 300 } else { 180 }
$timeoutSeconds = [int](Get-ConfigValue -Object $config -Name 'timeout_seconds' -Default $defaultTimeoutSeconds)
$heartbeatSeconds = [int](Get-ConfigValue -Object $config -Name 'heartbeat_seconds' -Default 30)
$maxSplitDepth = [int](Get-ConfigValue -Object $config -Name 'max_split_depth' -Default 3)
$maxConsecutiveFailures = [int](Get-ConfigValue -Object $config -Name 'max_consecutive_failures' -Default 4)
$quotaRetries = [int](Get-ConfigValue -Object $config -Name 'quota_retries' -Default 1)
# Long runs span hours and routinely outlive one account's quota, so hopping is on by
# default here. A manifest can still set it to false when the work must stay billed to
# whichever account is active.
$allowAccountSwitch = [bool](Get-ConfigValue -Object $config -Name 'allow_account_switch' -Default $true)
if ($timeoutSeconds -lt 10 -or $timeoutSeconds -gt 3600) { Stop-Batch -Code 64 -Message 'timeout_seconds must be between 10 and 3600' }
if ($heartbeatSeconds -lt 0 -or $heartbeatSeconds -gt 300) { Stop-Batch -Code 64 -Message 'heartbeat_seconds must be between 0 and 300' }
if ($maxSplitDepth -lt 0 -or $maxSplitDepth -gt 8) { Stop-Batch -Code 64 -Message 'max_split_depth must be between 0 and 8' }
if ($maxConsecutiveFailures -lt 2 -or $maxConsecutiveFailures -gt 20) { Stop-Batch -Code 64 -Message 'max_consecutive_failures must be between 2 and 20' }
if ($quotaRetries -lt 0 -or $quotaRetries -gt 5) { Stop-Batch -Code 64 -Message 'quota_retries must be between 0 and 5' }

$readOnly = [bool](Get-ConfigValue -Object $config -Name 'read_only' -Default $true)
$skipPermissions = [bool](Get-ConfigValue -Object $config -Name 'skip_permissions' -Default $false)
if (-not $readOnly) {
  Stop-Batch -Code 65 -Message 'automatic batch mode only supports read_only=true; let Codex supervise write tasks directly'
}
if ($skipPermissions) {
  Stop-Batch -Code 65 -Message 'automatic batch mode forbids skip_permissions'
}

$workspaceRootValue = [string](Get-ConfigValue -Object $config -Name 'workspace_root' -Default $manifestDirectory)
$workspaceRoot = Get-FullPath -Path $workspaceRootValue -BasePath $manifestDirectory
if (-not (Test-Path -LiteralPath $workspaceRoot -PathType Container)) {
  Stop-Batch -Code 64 -Message "workspace_root does not exist: $workspaceRoot"
}

$outputDirValue = [string](Get-ConfigValue -Object $config -Name 'output_dir' -Default (Join-Path '.agy-runs' $taskId))
$outputDir = Get-FullPath -Path $outputDirValue -BasePath $workspaceRoot
if (-not (Test-PathInside -Child $outputDir -Parent $workspaceRoot)) {
  Stop-Batch -Code 65 -Message 'output_dir must be inside workspace_root'
}
$finalOutputValue = [string](Get-ConfigValue -Object $config -Name 'final_output' -Default 'final.json')
$finalOutput = Get-FullPath -Path $finalOutputValue -BasePath $outputDir
if (-not (Test-PathInside -Child $finalOutput -Parent $outputDir)) {
  Stop-Batch -Code 65 -Message 'final_output must be inside output_dir'
}

$addDirsValue = Get-ConfigValue -Object $config -Name 'add_dirs' -Default @($workspaceRoot)
$addDirs = @()
foreach ($directoryValue in @($addDirsValue)) {
  $directory = Get-FullPath -Path ([string]$directoryValue) -BasePath $workspaceRoot
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    Stop-Batch -Code 64 -Message "add_dirs entry does not exist: $directory"
  }
  $addDirs += $directory
}

$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$summary = [ordered]@{
  valid = $true
  task_id = $taskId
  item_type = $itemType
  item_count = $items.Count
  batch_size = $batchSize
  estimated_batches = [int][Math]::Ceiling($items.Count / [double]$batchSize)
  complexity = $complexity
  model = $model
  model_selection = $modelSelection
  quota_retries = $quotaRetries
  allow_account_switch = $allowAccountSwitch
  read_only = $readOnly
  workspace_root = $workspaceRoot
  output_dir = $outputDir
  final_output = $finalOutput
}
if ($ValidateOnly) {
  ConvertTo-Json -InputObject $summary -Depth 5
  exit 0
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$batchesDir = Join-Path $outputDir 'batches'
New-Item -ItemType Directory -Path $batchesDir -Force | Out-Null
$statePath = Join-Path $outputDir 'run_state.json'
$snapshotPath = Join-Path $outputDir 'manifest.snapshot.json'

$pending = New-Object System.Collections.ArrayList
$completed = New-Object System.Collections.ArrayList
$failed = New-Object System.Collections.ArrayList
$accountSwitchEvents = New-Object System.Collections.ArrayList
$consecutiveFailures = 0
$batchSequence = 0
$activeBatch = $null

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  $previousState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$previousState.manifest_hash -ne $manifestHash) {
    Stop-Batch -Code 64 -Message 'manifest changed after the run started; use a new task_id or output_dir'
  }
  if ([string]$previousState.stage -eq 'complete' -and (Test-Path -LiteralPath $finalOutput -PathType Leaf)) {
    ConvertTo-Json -InputObject ([ordered]@{ status = 'complete'; resumed = $true; final_output = $finalOutput })
    exit 0
  }
  if ([string]$previousState.stage -eq 'needs_codex') {
    ConvertTo-Json -InputObject ([ordered]@{ status = 'needs_codex'; run_state = $statePath; failed_items = (Join-Path $outputDir 'failed_items.json') })
    exit 20
  }
  foreach ($entry in @($previousState.pending_batches)) { [void]$pending.Add($entry) }
  foreach ($entry in @($previousState.completed_batches)) { [void]$completed.Add($entry) }
  foreach ($entry in @($previousState.failed_batches)) { [void]$failed.Add($entry) }
  if ($null -ne $previousState.active_batch) { [void]$pending.Insert(0, $previousState.active_batch) }
  $consecutiveFailures = [int]$previousState.consecutive_failures
  $batchSequence = [int]$previousState.batch_sequence
  Write-BatchDiagnostic "resuming task $taskId with $($pending.Count) pending batch(es)"
} else {
  Write-JsonFile -Path $snapshotPath -Value $config
  for ($offset = 0; $offset -lt $orderedIds.Count; $offset += $batchSize) {
    $take = [Math]::Min($batchSize, $orderedIds.Count - $offset)
    $ids = @($orderedIds.GetRange($offset, $take))
    $batchSequence++
    [void]$pending.Add((New-BatchObject -Id ('b{0:d4}' -f $batchSequence) -ItemIds $ids -Depth 0))
  }
}

# agy-run.ps1 emits one "account-switch: ..." line per decision on stderr. Reading them
# back is how the batch learns whether a hop happened without any extra IPC.
function Read-AccountSwitchEvents {
  param([string]$StderrPath)
  if (-not (Test-Path -LiteralPath $StderrPath -PathType Leaf)) { return @() }
  try {
    return @(Get-Content -LiteralPath $StderrPath -Encoding UTF8 -ErrorAction Stop |
      Where-Object { $_ -match 'account-switch:' } |
      ForEach-Object { ($_ -replace '^\[agy-run\]\s*', '').Trim() })
  } catch { return @() }
}

function Save-RunState {
  param(
    [string]$Stage,
    [string]$NextAction,
    [int]$InfrastructureExitCode = 0
  )
  $completedArtifacts = @($completed | ForEach-Object { $_.output_file })
  $failureMessages = @($failed | ForEach-Object { "$($_.batch_id) attempt $($_.attempt): $($_.reason)" })
  $activeOperations = @()
  if ($null -ne $activeBatch) { $activeOperations = @("processing $($activeBatch.batch_id)") }
  if ((Test-Path -LiteralPath $finalOutput -PathType Leaf) -and -not ($completedArtifacts -contains $finalOutput)) {
    $completedArtifacts += $finalOutput
  }
  $state = [ordered]@{
    objective = "Run Agy batch task $taskId"
    stage = $Stage
    completed_artifacts = $completedArtifacts
    active_operations = @($activeOperations)
    pending_tasks = @($pending | ForEach-Object { $_.batch_id })
    failures = $failureMessages
    next_action = $NextAction
    updated_at = (Get-Date -Format o)
    manifest_path = $manifestPath
    manifest_hash = $manifestHash
    output_dir = $outputDir
    final_output = $finalOutput
    complexity = $complexity
    model = $model
    model_selection = $modelSelection
    quota_retries = $quotaRetries
    allow_account_switch = $allowAccountSwitch
    account_switches = @($accountSwitchEvents)
    account_switch_count = @($accountSwitchEvents | Where-Object { $_.event -match 'performed=true' }).Count
    infrastructure_exit_code = $InfrastructureExitCode
    item_count = $items.Count
    batch_size = $batchSize
    pending_batches = @($pending)
    active_batch = $activeBatch
    completed_batches = @($completed)
    failed_batches = @($failed)
    consecutive_failures = $consecutiveFailures
    batch_sequence = $batchSequence
  }
  $temporaryState = "$statePath.tmp"
  Write-JsonFile -Path $temporaryState -Value $state
  Move-Item -LiteralPath $temporaryState -Destination $statePath -Force
}

Save-RunState -Stage 'running' -NextAction 'process next pending batch'

while ($pending.Count -gt 0) {
  $activeBatch = $pending[0]
  $pending.RemoveAt(0)
  Save-RunState -Stage 'running' -NextAction "complete $($activeBatch.batch_id)"

  $batchItems = @($activeBatch.item_ids | ForEach-Object { $itemMap[[string]$_] })
  $workerPrompt = Build-WorkerPrompt -Instruction $instruction -BatchItems $batchItems

  if ($workerPrompt.Length -gt 23000) {
    if ($activeBatch.item_ids.Count -gt 1 -and $activeBatch.depth -lt $maxSplitDepth) {
      $split = Split-BatchObject -Batch $activeBatch
      [void]$pending.Insert(0, $split[1])
      [void]$pending.Insert(0, $split[0])
      Write-BatchDiagnostic "$($activeBatch.batch_id) prompt is too large; split before execution"
      $activeBatch = $null
      Save-RunState -Stage 'running' -NextAction 'process smaller prompt batch'
      continue
    }
    $failedItemsPath = Join-Path $outputDir 'failed_items.json'
    Write-JsonFile -Path $failedItemsPath -Value @($batchItems)
    $activeBatch = $null
    Save-RunState -Stage 'needs_codex' -NextAction 'Codex must process an item that exceeds the prompt limit'
    Stop-Batch -Code 20 -Message 'an individual batch exceeds the safe prompt limit; Codex takeover required'
  }

  $safeBatchId = $activeBatch.batch_id -replace '[^A-Za-z0-9._-]', '_'
  $attemptNumber = [int]$activeBatch.attempt + 1
  $prefix = Join-Path $batchesDir ("{0}.attempt{1}" -f $safeBatchId, $attemptNumber)
  $promptPath = "$prefix.prompt.txt"
  $inputPath = "$prefix.input.json"
  $outputPath = "$prefix.output.json"
  $consolePath = "$prefix.stdout.txt"
  $errorPath = "$prefix.stderr.txt"
  $workerConfigPath = "$prefix.worker.json"
  [System.IO.File]::WriteAllText($promptPath, $workerPrompt, $utf8WithoutBom)
  Write-JsonFile -Path $inputPath -Value @($batchItems)
  Remove-Item -LiteralPath $outputPath,$consolePath,$errorPath -Force -ErrorAction SilentlyContinue

  Write-BatchDiagnostic "starting $($activeBatch.batch_id), items=$($activeBatch.item_ids.Count), attempt=$attemptNumber"
  Write-JsonFile -Path $workerConfigPath -Value ([ordered]@{
    worker_path = $agyRun
    prompt_file = $promptPath
    model = $model
    timeout_seconds = $timeoutSeconds
    heartbeat_seconds = $heartbeatSeconds
    output_file = $outputPath
    add_dirs = @($addDirs)
    require_json = $true
    sandbox = $true
    quota_retries = $quotaRetries
    allow_account_switch = $allowAccountSwitch
  })
  $workerArgumentLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Config "{1}"' -f $workerHost, $workerConfigPath
  $workerExitCode = Invoke-WorkerProcess -ArgumentLine $workerArgumentLine `
    -StdoutPath $consolePath -StderrPath $errorPath -BatchId $activeBatch.batch_id

  # The worker owns the account decision; the batch only records what it did. These lines
  # are pre-masked by agy-run.ps1 and carry no credential material.
  foreach ($switchLine in (Read-AccountSwitchEvents -StderrPath $errorPath)) {
    [void]$accountSwitchEvents.Add([pscustomobject]@{
      batch_id = $activeBatch.batch_id
      attempt = $attemptNumber
      event = $switchLine
      observed_at = (Get-Date -Format o)
    })
    Write-BatchDiagnostic "$($activeBatch.batch_id) $switchLine"
  }

  $validation = if ($workerExitCode -eq 0) {
    Test-WorkerOutput -Path $outputPath -ExpectedIds @($activeBatch.item_ids)
  } else {
    [pscustomobject]@{ Valid = $false; Reason = "agy-run exit code $workerExitCode"; Items = @() }
  }

  if ($validation.Valid) {
    [void]$completed.Add([pscustomobject]@{
      batch_id = $activeBatch.batch_id
      item_ids = @($activeBatch.item_ids)
      output_file = $outputPath
      completed_at = (Get-Date -Format o)
    })
    $consecutiveFailures = 0
    Write-BatchDiagnostic "completed $($activeBatch.batch_id); $($pending.Count) batch(es) remain"
    $activeBatch = $null
    Save-RunState -Stage 'running' -NextAction 'process next pending batch'
    continue
  }

  $consecutiveFailures++
  [void]$failed.Add([pscustomobject]@{
    batch_id = $activeBatch.batch_id
    attempt = $attemptNumber
    item_ids = @($activeBatch.item_ids)
    exit_code = $workerExitCode
    reason = $validation.Reason
    stderr_file = $errorPath
    failed_at = (Get-Date -Format o)
  })
  Write-BatchDiagnostic "$($activeBatch.batch_id) failed: $($validation.Reason)"

  if ($workerExitCode -in @(7, 8, 9)) {
    $failedItemsPath = Join-Path $outputDir 'failed_items.json'
    Write-JsonFile -Path $failedItemsPath -Value @($batchItems)
    $infrastructureExitCode = $workerExitCode
    $activeBatch = $null
    Save-RunState -Stage 'needs_codex' -InfrastructureExitCode $infrastructureExitCode `
      -NextAction "Codex must resolve infrastructure exit code $infrastructureExitCode before resuming"
    Stop-Batch -Code 20 `
      -Message "worker infrastructure failure $infrastructureExitCode; retrying or bisecting items cannot fix it"
  }

  if ($consecutiveFailures -ge $maxConsecutiveFailures) {
    $failedItemsPath = Join-Path $outputDir 'failed_items.json'
    Write-JsonFile -Path $failedItemsPath -Value @($batchItems)
    $activeBatch = $null
    Save-RunState -Stage 'needs_codex' -NextAction 'Codex must inspect failure logs and process remaining items'
    Stop-Batch -Code 20 -Message "$consecutiveFailures consecutive failures; Codex takeover required"
  }

  if ([int]$activeBatch.attempt -lt 1) {
    $activeBatch.attempt = 1
    [void]$pending.Insert(0, $activeBatch)
    Write-BatchDiagnostic "retrying $($activeBatch.batch_id) once without changing the batch"
    $activeBatch = $null
    Save-RunState -Stage 'running' -NextAction 'retry failed batch once'
    continue
  }

  if ($activeBatch.item_ids.Count -gt 1 -and $activeBatch.depth -lt $maxSplitDepth) {
    $split = Split-BatchObject -Batch $activeBatch
    [void]$pending.Insert(0, $split[1])
    [void]$pending.Insert(0, $split[0])
    Write-BatchDiagnostic "bisected $($activeBatch.batch_id) into $($split[0].batch_id) and $($split[1].batch_id)"
    $activeBatch = $null
    Save-RunState -Stage 'running' -NextAction 'process bisected batches'
    continue
  }

  $failedItemsPath = Join-Path $outputDir 'failed_items.json'
  Write-JsonFile -Path $failedItemsPath -Value @($batchItems)
  $activeBatch = $null
  Save-RunState -Stage 'needs_codex' -NextAction 'Codex must process the irreducible failed batch'
  Stop-Batch -Code 20 -Message 'failed batch cannot be split further; Codex takeover required'
}

$resultMap = @{}
foreach ($completedBatch in $completed) {
  $batchResult = Get-Content -LiteralPath $completedBatch.output_file -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($resultItem in @($batchResult)) {
    $resultMap[[string]$resultItem.id] = $resultItem
  }
}

$orderedResults = New-Object System.Collections.ArrayList
foreach ($id in $orderedIds) {
  if (-not $resultMap.ContainsKey([string]$id)) {
    Save-RunState -Stage 'needs_codex' -NextAction "Codex must recover missing result id $id"
    Stop-Batch -Code 20 -Message "final merge is missing id: $id"
  }
  [void]$orderedResults.Add($resultMap[[string]$id])
}
Write-JsonFile -Path $finalOutput -Value @($orderedResults)
$activeBatch = $null
Save-RunState -Stage 'complete' -NextAction 'none'
ConvertTo-Json -InputObject ([ordered]@{
  status = 'complete'
  task_id = $taskId
  item_count = $items.Count
  completed_batches = $completed.Count
  complexity = $complexity
  model = $model
  model_selection = $modelSelection
  quota_retries = $quotaRetries
  allow_account_switch = $allowAccountSwitch
  account_switch_count = @($accountSwitchEvents | Where-Object { $_.event -match 'performed=true' }).Count
  final_output = $finalOutput
  run_state = $statePath
})
exit 0
