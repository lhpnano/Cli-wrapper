$ErrorActionPreference = "Stop"
$ClaudeArgs = $args
try {
  $statusRaw = & claude auth status 2>$null
  $status = $statusRaw | ConvertFrom-Json
} catch {
  $status = $null
}

if (-not $status -or -not $status.loggedIn) {
  [Console]::Error.WriteLine("Claude Code is installed but not logged in.")
  [Console]::Error.WriteLine("Use the shared Claude account with:")
  [Console]::Error.WriteLine("  claude auth login --claudeai")
  [Console]::Error.WriteLine("Then verify with:")
  [Console]::Error.WriteLine("  claude auth status")
  exit 2
}

& claude @ClaudeArgs
exit $LASTEXITCODE
