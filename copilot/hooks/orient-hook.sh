#!/usr/bin/env bash
# Copilot CLI sessionStart adapter — emit the WHERE YOU ARE orientation block
# as additionalContext so the model sees project state at session start.
#
# Reuses bin/where-am-i (format-agnostic); only adds Copilot's output JSON
# wrapper: {"additionalContext": "<block>"}
#
# Silent (exit 0, no output) when no .claude/state.json is present — Copilot
# simply receives no additionalContext and the session starts normally.
#
# Environment:
#   WHEREAMI_STUB      — test seam: inject orientation text without real bin on PATH.
#   CLAUDE_PROJECT_DIR — passed through to where-am-i for project root resolution.
set -euo pipefail

# Resolve this script's own directory for the legacy sibling-bin fallback below.
# Copilot calls hooks by absolute path, so ${BASH_SOURCE[0]} is always absolute.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# where-am-i is a PYTHON script, so run it with a Python interpreter rather than
# relying on its shebang (which fails where python3 is a Microsoft Store stub).
# Probe python3/python/py and sanity-check --version (parity with _python.sh),
# so a non-working stub is skipped.
_pybin=""
for _cand in python3 python py; do
    if command -v "$_cand" >/dev/null 2>&1 && "$_cand" --version >/dev/null 2>&1; then
        _pybin="$_cand"; break
    fi
done

# WHEREAMI_STUB lets tests inject output without the real bin on PATH (highest priority).
# When unset (production): resolve where-am-i. In the marketplace-plugin layout the
# adapters live at $CLAUDE_PLUGIN_ROOT/copilot/hooks/ while bin/ sits at the plugin
# ROOT, so a sibling self-locate ($DIR/bin) does NOT resolve — prefer the plugin-root
# env var (Copilot/Codex/Claude all export CLAUDE_PLUGIN_ROOT = the install dir). Fall
# back to the sibling layout (legacy direct-copy installs), then bare 'where-am-i' on
# PATH. Pass $PWD (the project Copilot opened) so where-am-i reads its .claude/state.json.
if [ "${WHEREAMI_STUB+x}" ]; then
    block="$WHEREAMI_STUB"
else
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/bin/where-am-i" ]; then
        _wai="$CLAUDE_PLUGIN_ROOT/bin/where-am-i"
    elif [ -f "$DIR/bin/where-am-i" ]; then
        _wai="$DIR/bin/where-am-i"
    else
        _wai="$(command -v where-am-i 2>/dev/null || true)"
    fi
    if [ -n "$_wai" ] && [ -n "$_pybin" ]; then
        block="$("$_pybin" "$_wai" "$PWD" 2>/dev/null || true)"
    elif [ -n "$_wai" ]; then
        block="$("$_wai" 2>/dev/null || true)"   # last resort: rely on shebang
    else
        block=""
    fi
fi

# No state.json (or where-am-i returned nothing) → stay silent (no injection).
[ -n "$block" ] || exit 0

# Wrap in Copilot's additionalContext JSON envelope.
# jq -Rs . encodes the entire block as a JSON string (handles newlines,
# backslashes, quotes, and all other special characters safely).
printf '{"additionalContext": %s}\n' "$(printf '%s' "$block" | jq -Rs .)"
