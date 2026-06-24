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

# Resolve this script's own directory for the legacy sibling-bin fallback below.
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
# When unset (production): resolve where-am-i. In the marketplace-plugin layout the
# adapters live at $env:CLAUDE_PLUGIN_ROOT\copilot\hooks\ while bin\ sits at the plugin
# ROOT, so a sibling self-locate ($ScriptDir\bin) does NOT resolve — prefer the
# plugin-root env var (Copilot/Codex/Claude all export CLAUDE_PLUGIN_ROOT = the install
# dir). Fall back to the sibling layout (legacy direct-copy installs), then bare
# 'where-am-i' on PATH. Pass the current dir (the project) so where-am-i reads state.json.
if ($null -ne $env:WHEREAMI_STUB) {
    $block = $env:WHEREAMI_STUB
} else {
    $PluginRootWhereAmI = if ($env:CLAUDE_PLUGIN_ROOT) { Join-Path $env:CLAUDE_PLUGIN_ROOT 'bin\where-am-i' } else { $null }
    $wai = if ($PluginRootWhereAmI -and (Test-Path $PluginRootWhereAmI)) {
        $PluginRootWhereAmI
    } elseif (Test-Path $SiblingWhereAmI) {
        $SiblingWhereAmI
    } else {
        (Get-Command where-am-i -ErrorAction SilentlyContinue).Source
    }
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
