# Reliable Codex and Claude CLI wrappers

`codex-run` and `claude-run` add process supervision and output validation to
the installed CLIs. They do not read, copy, or set provider credentials.

## Provider ownership

- Codex++ remains the only owner of Codex provider, base URL, API key, and
  default model settings.
- CC Switch remains the only owner of Claude base URL, auth token, and default
  model settings.
- The wrappers only pass `--model` when `-Model` is explicitly supplied.
- Every invocation starts a fresh child process, so provider changes apply to
  the next invocation. They do not alter an already-running child process.

## Defaults

- Hard timeout: 1800 seconds.
- Heartbeat: 30 seconds, written to stderr.
- Transient retries: disabled because a task may have side effects.
- Codex sandbox: `read-only`.
- Claude permission mode: `plan`.
- Prompts are sent through stdin and are not persisted by the wrapper.
- Run state and redacted diagnostics are written below
  `%LOCALAPPDATA%\ai-cli-runs\codex-run` or
  `%LOCALAPPDATA%\ai-cli-runs\claude-run`.

## Examples

```powershell
codex-run -Prompt 'Return exactly PONG.' -Timeout 120
claude-run -Prompt 'Return exactly PONG.' -Timeout 120

codex-run -PromptFile .\task.md -Sandbox workspace-write `
  -RequirePath .\result.md -OutputFile .\final-message.txt

claude-run -PromptFile .\task.md -PermissionMode acceptEdits `
  -MaxTurns 20 -RequirePath .\result.md -OutputFile .\final-message.txt

codex-run -PromptFile .\continue.md -ResumeSession <session-id>
claude-run -PromptFile .\continue.md -ResumeSession <session-id> -ForkSession
```

For deterministic JSON output:

```powershell
codex-run -PromptFile .\task.md -OutputSchemaFile .\schema.json `
  -RequireJson -OutputFile .\result.json

claude-run -PromptFile .\task.md -JsonSchemaFile .\schema.json `
  -RequireJson -OutputFile .\result.json
```

Claude Code 2.1.215 may reject a schema that declares the Draft 2020-12 URI.
`claude-run` removes that optional declaration before passing the schema to
Claude. Field constraints remain in the schema, and the wrapper still validates
that stdout is JSON.

Retries must be explicitly enabled and are limited to transient failures:

```powershell
codex-run -PromptFile .\read-only-task.md -TransientRetries 1
claude-run -PromptFile .\read-only-task.md -TransientRetries 1
```

Do not enable retries for a task that publishes, sends messages, modifies an
external system, or cannot safely run more than once.

## Run artifacts

Each run directory contains:

- `run-state.json`: overall status, attempts, active operation, exit code.
- `attempt-NNN/process-state.json`: PID, heartbeat, timeout and attempt status.
- `attempt-NNN/stdout.txt` and `stderr.txt`: attempt output.
- `stdout.txt` and `stderr.txt`: final attempt output.

The prompt is intentionally excluded. Supply `-OutputFile` when the final
answer itself must be placed at a stable path.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Successful CLI call and product validation |
| 2 | CLI returned exit code 0 with empty stdout |
| 3 | Output shorter than `MinOutputChars` |
| 4 | Invalid JSON when JSON is required |
| 5 | A required path was not produced |
| 6 | Final output file could not be written |
| 64 | Invalid wrapper input |
| 124 | Wrapper hard timeout |
| 127 | CLI executable not found |

Other nonzero values are preserved from the underlying CLI.

## agy network routing

`agy-run.ps1` and the `agy*` shims set proxy variables on the `agy.exe` child process
only. Nothing is written to `HKCU\Environment`, so Claude, Codex, and the desktop
clients are never affected and no restart is needed after switching networks.

| Mode | Behaviour |
|---|---|
| `Auto` (default) | Surfshark if a VPN adapter owns a default route, else V2rayN if the proxy port is listening, else Direct |
| `V2rayN` | `HTTP_PROXY`/`HTTPS_PROXY` set to the endpoint; exits 9 if nothing is listening |
| `Surfshark` | Proxy variables cleared, routing left to the tunnel; exits 9 if no VPN adapter owns a default route |
| `Direct` | Proxy variables cleared, no tunnel expected |

Surfshark is detected by adapter and default route, never by process list: the
Surfshark service runs whether or not the tunnel is up. Surfshark wins ties in
`Auto` because network-layer routing also covers traffic that ignores proxy
variables.

```powershell
agy-run -Prompt 'Return exactly PONG.' -Timeout 90                  # Auto
agy-run -Prompt 'Return exactly PONG.' -Network V2rayN
agy-run -Prompt '...' -Network Surfshark -AllowAccountSwitch
```

Interactive shims: `agy` (Auto), `agy-v2ray`, `agy-surfshark`, `agy-direct`.

Each calls `agy-mode.ps1`, which only *prints* the resolved path (a proxy URL,
`DIRECT`, or `ERROR:<msg>`), then hands `%*` straight to `agy.exe`. Do not route
agy's own flags through `powershell -File`: it mangles `--long-flags`, agy falls back

to interactive mode, and the call hangs forever.

### Token freshness

Before dispatch the wrapper reads the `gemini:antigravity` credential's LastWritten
metadata. If it is older than `3599 - Timeout - 300` seconds it asks Antigravity
Manager to re-issue by switching to the *currently active* account, then verifies
LastWritten actually advanced. A cross-process mutex keeps a batch fan-out from
stampeding AM.

Account hopping depends on why the run failed:

- **Quota exhausted**: switches to another enabled account and retries automatically
  (`-QuotaRetries`, default 1). Manifest workers receive `quota_retries` (default 1).
  Every account is attempted at most once per worker, preventing account ping-pong.
- **Auth failure**: re-mints the *active* account's token. Falling back to the other
  account is opt-in via `-AllowAccountSwitch`, since auth is normally fixed in place
  and hopping changes which account the work bills to.

### agy exit codes

| Code | Meaning |
|---:|---|
| 7 | Rejected by region. Change the proxy exit's **provider**, not just its country |
| 8 | Quota exhausted, and the automatic switch to the other account did not help |
| 9 | No usable network path: requested mode unavailable, or transport failed |

agy collapses every backend failure into `Error: Agent execution terminated due to
error.` on stderr, so the wrapper always passes `--log-file` and classifies from the
log in this order: transport, region, auth, quota. Diagnose any agy failure from that
log; the stderr line carries no information.
