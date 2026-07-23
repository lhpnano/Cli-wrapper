<#
.SYNOPSIS
Compatibility entry point for agents that invoke codex-run.

.DESCRIPTION
Keeps the established supervised Codex CLI interface while delegating every
actual Codex invocation to the AI Network Panel's dedicated Agent wrapper.
The wrapper resolves the active network route on every invocation and applies
proxy variables only to the child Codex process. It uses the system-installed
Codex CLI without changing user-level proxy settings.
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

  [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
  [string]$Sandbox = 'read-only',

  [string]$WorkingDirectory = (Get-Location).Path,

  [string[]]$AddDir,

  [string]$ResumeSession,

  [switch]$ResumeLast,

  [switch]$Ephemeral,

  [string]$OutputSchemaFile,

  [ValidateRange(1, 86400)]
  [int]$Timeout = 1800,

  [ValidateRange(0, 3600)]
  [int]$HeartbeatSeconds = 30,

  [ValidateRange(0, 5)]
  [int]$TransientRetries = 1,

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
$label = 'codex-run'

try {
  if ([string]::IsNullOrWhiteSpace($CliPath)) {
    $CliPath = Join-Path $env:LOCALAPPDATA 'AI-Network-Panel\cli-auto\codex.cmd'
  }
  if (-not (Test-Path -LiteralPath $CliPath)) { throw "Agent Codex wrapper does not exist: $CliPath" }
  if ($PSCmdlet.ParameterSetName -eq 'PromptFile') {
    $resolvedPromptFile = Resolve-CliExistingPath -Path $PromptFile -Description 'prompt file'
    $Prompt = Get-Content -LiteralPath $resolvedPromptFile -Raw -Encoding UTF8
  }
  if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'prompt is empty' }
  if ($ResumeLast -and -not [string]::IsNullOrWhiteSpace($ResumeSession)) { throw 'ResumeLast and ResumeSession cannot be used together' }

  # Retry a read-only request once when its response stream dies before output.
  # Writing requests remain single-attempt unless their caller explicitly opts in.
  $effectiveTransientRetries = if ($Sandbox -eq 'read-only' -or $PSBoundParameters.ContainsKey('TransientRetries')) { $TransientRetries } else { 0 }

  $resolvedWorkingDirectory = Resolve-CliExistingPath -Path $WorkingDirectory -Description 'working directory'
  $arguments = @('exec', '--sandbox', $Sandbox, '-C', $resolvedWorkingDirectory, '--skip-git-repo-check', '--color', 'never')
  if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments += @('--model', $Model) }
  foreach ($directory in @($AddDir | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $arguments += @('--add-dir', (Resolve-CliExistingPath -Path $directory -Description 'add-dir'))
  }
  if ($Ephemeral) { $arguments += '--ephemeral' }
  if (-not [string]::IsNullOrWhiteSpace($OutputSchemaFile)) { $arguments += @('--output-schema', (Resolve-CliExistingPath -Path $OutputSchemaFile -Description 'output schema')) }
  if ($ResumeLast -or -not [string]::IsNullOrWhiteSpace($ResumeSession)) {
    $arguments += 'resume'
    if ($ResumeLast) { $arguments += '--last' } else { $arguments += $ResumeSession }
  }
  $arguments += '-'

  $result = Invoke-ReliableCliRun -Label $label -CommandName 'codex' -CliPath $CliPath `
    -Arguments $arguments -Prompt $Prompt -WorkingDirectory $resolvedWorkingDirectory `
    -TimeoutSeconds $Timeout -HeartbeatSeconds $HeartbeatSeconds -TransientRetries $effectiveTransientRetries `
    -MinOutputChars $MinOutputChars -RequireJson ([bool]$RequireJson) -RequirePath $RequirePath `
    -OutputFile $OutputFile -RunRoot $RunRoot -Network Auto
  Complete-CliRun -Label $label -Result $result
} catch {
  $message = Protect-CliDiagnosticText -Text $_.Exception.Message
  Write-CliRunDiagnostic -Label $label -Message $message
  if ($message -match 'not found on PATH|does not exist') { exit 127 }
  exit 64
}
