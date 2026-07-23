<#
.SYNOPSIS
Runs Claude CLI reliably without changing CC Switch provider configuration.

.DESCRIPTION
Passes the prompt through stdin, applies a hard timeout and heartbeat, keeps
per-run state under %LOCALAPPDATA%\ai-cli-runs\claude-run, preserves the real
exit code, and validates stdout or required products. Model, base URL, and auth
values are inherited from Claude CLI and CC Switch unless explicitly overridden
by supported non-provider parameters.

.NOTES
Wrapper exit codes: 2 empty stdout; 3 output too short; 4 invalid JSON;
5 required path missing; 6 output write failed; 64 invalid input;
124 hard timeout; 127 Claude CLI missing. Other codes come from Claude CLI.
#>
[CmdletBinding(DefaultParameterSetName = 'Prompt')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Prompt', Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$Prompt,

  [Parameter(Mandatory = $true, ParameterSetName = 'PromptFile')]
  [ValidateNotNullOrEmpty()]
  [string]$PromptFile,

  [string]$Model,

  [ValidateSet('plan', 'dontAsk', 'manual', 'acceptEdits', 'auto')]
  [string]$PermissionMode = 'plan',

  [ValidateSet('text', 'json', 'stream-json')]
  [string]$OutputFormat = 'text',

  [string]$WorkingDirectory = (Get-Location).Path,

  [string[]]$AddDir,

  [string]$ResumeSession,

  [switch]$Continue,

  [switch]$ForkSession,

  [string]$SessionId,

  [switch]$NoSessionPersistence,

  [switch]$DisableTools,

  [switch]$SafeMode,

  [ValidateRange(0, 10000)]
  [int]$MaxTurns = 0,

  [ValidateRange(0, 1000000)]
  [double]$MaxBudgetUsd = 0,

  [ValidateSet('', 'low', 'medium', 'high', 'xhigh', 'max')]
  [string]$Effort = '',

  [string]$FallbackModel,

  [string]$JsonSchemaFile,

  [ValidateRange(1, 86400)]
  [int]$Timeout = 1800,

  [ValidateRange(0, 3600)]
  [int]$HeartbeatSeconds = 30,

  [ValidateRange(0, 5)]
  [int]$TransientRetries = 0,

  [ValidateRange(1, 2147483647)]
  [int]$MinOutputChars = 1,

  [switch]$RequireJson,

  [string[]]$RequirePath,

  [string]$OutputFile,

  [string]$RunRoot,

  [string]$CliPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cli-run-core.ps1')
$label = 'claude-run'

try {
  if ($PSCmdlet.ParameterSetName -eq 'PromptFile') {
    $resolvedPromptFile = Resolve-CliExistingPath -Path $PromptFile -Description 'prompt file'
    $Prompt = Get-Content -LiteralPath $resolvedPromptFile -Raw -Encoding UTF8
  }
  if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'prompt is empty' }
  if ($Continue -and -not [string]::IsNullOrWhiteSpace($ResumeSession)) {
    throw 'Continue and ResumeSession cannot be used together'
  }
  if ($ForkSession -and -not ($Continue -or -not [string]::IsNullOrWhiteSpace($ResumeSession))) {
    throw 'ForkSession requires Continue or ResumeSession'
  }
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $null = [Guid]::Parse($SessionId)
    if ($Continue -or -not [string]::IsNullOrWhiteSpace($ResumeSession)) {
      throw 'SessionId cannot be combined with Continue or ResumeSession'
    }
  }

  $resolvedWorkingDirectory = Resolve-CliExistingPath -Path $WorkingDirectory -Description 'working directory'
  $arguments = @('-p', '--output-format', $OutputFormat, '--permission-mode', $PermissionMode)
  if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments += @('--model', $Model) }
  if ($Continue) { $arguments += '--continue' }
  if (-not [string]::IsNullOrWhiteSpace($ResumeSession)) { $arguments += @('--resume', $ResumeSession) }
  if ($ForkSession) { $arguments += '--fork-session' }
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $arguments += @('--session-id', $SessionId) }
  if ($NoSessionPersistence) { $arguments += '--no-session-persistence' }
  if ($DisableTools) { $arguments += @('--tools', '') }
  if ($SafeMode) { $arguments += '--safe-mode' }
  if ($MaxTurns -gt 0) { $arguments += @('--max-turns', [string]$MaxTurns) }
  if ($MaxBudgetUsd -gt 0) {
    $arguments += @('--max-budget-usd', $MaxBudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture))
  }
  if (-not [string]::IsNullOrWhiteSpace($Effort)) { $arguments += @('--effort', $Effort) }
  if (-not [string]::IsNullOrWhiteSpace($FallbackModel)) { $arguments += @('--fallback-model', $FallbackModel) }

  $schemaRequiresJson = $false
  if (-not [string]::IsNullOrWhiteSpace($JsonSchemaFile)) {
    $resolvedSchema = Resolve-CliExistingPath -Path $JsonSchemaFile -Description 'JSON schema'
    $schemaObject = Get-Content -LiteralPath $resolvedSchema -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $schemaDeclaration = $schemaObject.PSObject.Properties['$schema']
    if ($null -ne $schemaDeclaration -and [string]$schemaDeclaration.Value -match 'json-schema\.org/draft/2020-12/schema') {
      $schemaObject.PSObject.Properties.Remove('$schema')
      Write-CliRunDiagnostic -Label $label -Message 'removed Draft 2020-12 $schema declaration for Claude CLI compatibility'
    }
    $compactSchema = ConvertTo-Json -InputObject $schemaObject -Depth 30 -Compress
    $arguments += @('--json-schema', $compactSchema)
    $schemaRequiresJson = $OutputFormat -eq 'text'
  }
  $resolvedAddDirs = @($AddDir | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($resolvedAddDirs.Count -gt 0) {
    $arguments += '--add-dir'
    foreach ($directory in $resolvedAddDirs) {
      $arguments += Resolve-CliExistingPath -Path $directory -Description 'add-dir'
    }
  }

  $validateJson = [bool]$RequireJson -or $OutputFormat -eq 'json' -or $schemaRequiresJson
  $result = Invoke-ReliableCliRun -Label $label -CommandName 'claude' -CliPath $CliPath `
    -Arguments $arguments -Prompt $Prompt -WorkingDirectory $resolvedWorkingDirectory `
    -TimeoutSeconds $Timeout -HeartbeatSeconds $HeartbeatSeconds -TransientRetries $TransientRetries `
    -MinOutputChars $MinOutputChars -RequireJson $validateJson -RequirePath $RequirePath `
    -OutputFile $OutputFile -RunRoot $RunRoot
  Complete-CliRun -Label $label -Result $result
} catch {
  $message = Protect-CliDiagnosticText -Text $_.Exception.Message
  Write-CliRunDiagnostic -Label $label -Message $message
  if ($message -match 'not found on PATH|CLI path does not exist') { exit 127 }
  exit 64
}
