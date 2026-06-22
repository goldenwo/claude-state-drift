# Copilot CLI sessionStart adapter (PowerShell) — emit the WHERE YOU ARE
# orientation block as additionalContext so the model sees project state
# at session start.
#
# Reuses where-am-i (format-agnostic); only adds Copilot's output JSON
# wrapper: {"additionalContext": "<block>"}
#
# Silent (exit 0, no output) when no .claude/state.json is present.
#
# Environment:
#   WHEREAMI_STUB      — test seam: inject orientation text without real bin on PATH.
#   CLAUDE_PROJECT_DIR — passed through to where-am-i for project root resolution.

$ErrorActionPreference = 'SilentlyContinue'  # cross-platform analog of the .sh's `set -euo pipefail` (both silence non-fatal errors and exit cleanly)

# Resolve this script's own directory so we can locate where-am-i at its
# installed sibling path without relying on any env var being set.
# Copilot calls hooks by absolute path, so $PSScriptRoot is always absolute.
$ScriptDir = $PSScriptRoot
$SiblingWhereAmI = Join-Path $ScriptDir 'bin\where-am-i'

# where-am-i is a PYTHON script, so it must be run with a Python interpreter
# (NOT bash). Resolve one the way the toolkit's _python.sh does: probe
# py / python3 / python and sanity-check --version, so a Microsoft Store stub
# (which fails --version, exit 49) is skipped in favor of the real `py` launcher.
$pyBin = $null
foreach ($cand in @('py','python3','python')) {
    $c = Get-Command $cand -ErrorAction SilentlyContinue
    if ($null -ne $c) {
        try { & $c.Source --version *> $null } catch { continue }
        if ($LASTEXITCODE -eq 0) { $pyBin = $c.Source; break }
    }
}

# WHEREAMI_STUB lets tests inject output without the real bin on PATH (highest priority).
# When unset (production): self-locate where-am-i at $ScriptDir\bin\where-am-i — the
# installer places bin\ as a direct child of the same directory the adapters live in
# (i.e. $COPILOT_HOME\state-drift\{orient-hook.ps1,bin\where-am-i}). Pass the current
# directory (the project Copilot opened) so where-am-i reads its .claude/state.json.
# Fall back to bare 'where-am-i' on PATH for manually configured installs.
if ($null -ne $env:WHEREAMI_STUB) {
    $block = $env:WHEREAMI_STUB
} else {
    $wai = if (Test-Path $SiblingWhereAmI) { $SiblingWhereAmI } else { (Get-Command where-am-i -ErrorAction SilentlyContinue).Source }
    if ($wai -and $pyBin) {
        $block = (& $pyBin $wai (Get-Location).Path 2>$null) -join "`n"
    } else {
        $block = ''
    }
}

# No state.json (or where-am-i returned nothing) → stay silent (no injection).
if ([string]::IsNullOrEmpty($block)) { exit 0 }

# Wrap in Copilot's additionalContext JSON envelope.
# ConvertTo-Json handles all escaping (newlines, quotes, backslashes).
@{ additionalContext = $block } | ConvertTo-Json -Compress
