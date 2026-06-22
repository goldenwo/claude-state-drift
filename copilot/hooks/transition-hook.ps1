# Copilot CLI postToolUse adapter (PowerShell) — detect a git commit whose
# subject suggests a deliverable transition and emit {"additionalContext": "..."}
# pointing at the update-state skill.
#
# Reads the Copilot postToolUse payload from stdin (JSON). Silent otherwise.
#
# Field schema CONFIRMED via the Phase 0 hands-on spike (copilot 1.0.63, Windows,
# 2026-06-22). Copilot's postToolUse payload exposes:
#   .toolName              — interpreter that ran ("powershell" on Windows;
#                            "bash"/"shell" on POSIX). Platform-variant, so we do
#                            NOT guard on it — the command-content gate is the filter.
#   .toolArgs              — a JSON-ENCODED STRING: {"command":"...","description":"..."}
#   .toolResult.resultType — "success" when the underlying tool run succeeded.

$ErrorActionPreference = 'SilentlyContinue'

# Read the payload from stdin robustly across PowerShell invocation modes, since
# a path-valued "powershell" hook field could be launched either way:
#   * `powershell -File script.ps1`    -> stdin is bound to the pipeline ($input)
#   * `powershell -Command "& script"` -> stdin is read via [Console]::In
# Capture the pipeline FIRST (before $input is reassigned), then fall back to the
# console reader, using whichever delivered the payload — correct either way.
$pipelineIn = ''
try { $pipelineIn = @($input) -join "`n" } catch {}
$payloadText = ''
try { $payloadText = [Console]::In.ReadToEnd() } catch {}
if ([string]::IsNullOrWhiteSpace($payloadText)) { $payloadText = $pipelineIn }
if ([string]::IsNullOrWhiteSpace($payloadText)) { exit 0 }

# Cheap substring check before JSON parse
if ($payloadText -notmatch 'git commit') { exit 0 }

# Parse JSON
try {
    $payload = $payloadText | ConvertFrom-Json
} catch { exit 0 }

# .toolArgs is a JSON-ENCODED STRING (Phase 0); parse it, then read .command.
$cmd = ''
if ($payload.toolArgs) {
    $rawArgs = $payload.toolArgs
    if ($rawArgs -is [string]) {
        try { $rawArgs = $rawArgs | ConvertFrom-Json } catch { $rawArgs = $null }
    }
    if ($rawArgs) {
        if ($rawArgs.command)   { $cmd = [string]$rawArgs.command }
        elseif ($rawArgs.input) { $cmd = [string]$rawArgs.input }
    }
}
# Defensive fallback for schema drift (older payloads exposed .toolInput).
if ([string]::IsNullOrEmpty($cmd) -and $payload.toolInput) {
    if ($payload.toolInput.command)   { $cmd = [string]$payload.toolInput.command }
    elseif ($payload.toolInput.input) { $cmd = [string]$payload.toolInput.input }
}
$cmd = $cmd -replace '[\r\n]+', ' '

# Authoritative, platform-independent gate: command must contain 'git commit'.
if ($cmd -notmatch 'git commit') { exit 0 }

# Skip only on an EXPLICIT non-success result (parity with the .sh adapter and
# state-track-commit.sh). Absent/empty resultType -> proceed.
$resultType = ''
if ($payload.toolResult -and $payload.toolResult.resultType) {
    $resultType = [string]$payload.toolResult.resultType
}
if ($resultType -and $resultType -ne 'success') { exit 0 }

# Extract subject from -m argument (best-effort)
$subject = ''
if ($cmd -match '-m\s+[''"]?([^''"]+)[''"]?') {
    $subject = $Matches[1].Trim(" '`"")
}
if ([string]::IsNullOrEmpty($subject)) { $subject = $cmd }

# Sanitize angle brackets (prompt-injection defense)
$safeSubject = $subject -replace '<', '‹' -replace '>', '›'
$safeSubject = $safeSubject -replace '[\r\n]+', ' '

# Transition-keyword regex — .NET-equivalent of the POSIX DEFAULT_PATTERN from
# hooks/state-track-commit.sh. POSIX uses [^[:alnum:]_] and [0-9]+; .NET uses
# [^a-zA-Z0-9_] and \d+ which differ on Unicode input (Unicode letters/digits
# are matched by \d+ but not [0-9]+, and Unicode non-ASCII word chars pass
# [^[:alnum:]_] but not [^a-zA-Z0-9_]). ASCII commit subjects are identical.
$pattern = '(^|[^a-zA-Z0-9_])(ship|shipped|release|released|complete|completed|done|finish|finished|deliver|delivered)([^a-zA-Z0-9_]|$)|(^|[^a-zA-Z0-9_])v\d+\.\d+'

if ($subject -notmatch "(?i)$pattern") { exit 0 }

$nudge = "Commit just landed with subject: $safeSubject`n`nSubject suggests a deliverable transition but .claude/state.json may not reflect it. Consider invoking the ``/update-state`` skill to log this transition before continuing."

@{ additionalContext = $nudge } | ConvertTo-Json -Compress
