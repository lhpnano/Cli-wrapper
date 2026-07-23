param(
  [Parameter(Mandatory = $true)]
  [string]$Config
)

$ErrorActionPreference = 'Stop'
try {
  $configPath = (Resolve-Path -LiteralPath $Config).Path
  $settings = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $workerPath = (Resolve-Path -LiteralPath ([string]$settings.worker_path)).Path
  $arguments = @{
    PromptFile = [string]$settings.prompt_file
    Model = [string]$settings.model
    Timeout = [int]$settings.timeout_seconds
    HeartbeatSeconds = [int]$settings.heartbeat_seconds
    OutputFile = [string]$settings.output_file
    AddDir = @($settings.add_dirs | ForEach-Object { [string]$_ })
    QuotaRetries = [int]$settings.quota_retries
  }
  if ([bool]$settings.require_json) { $arguments.RequireJson = $true }
  if ([bool]$settings.sandbox) { $arguments.Sandbox = $true }
  # Only forwarded when the manifest opted in, so a manifest with
  # allow_account_switch:false can never produce an account hop.
  if ([bool]$settings.allow_account_switch) { $arguments.AllowAccountSwitch = $true }
  & $workerPath @arguments
  exit $LASTEXITCODE
} catch {
  [Console]::Error.WriteLine("[agy-worker-host] $($_.Exception.Message)")
  exit 1
}
