#!/usr/bin/env bash
# session-start-orient.sh — SessionStart plugin hook that auto-runs
# `where-am-i` for the current project and injects the orientation block
# into the new session's context via additionalContext.
#
# Silent-skip if .claude/state.json doesn't exist (no enforcement —
# uninstrumented projects pay nothing).
#
# Per Claude Code hooks reference: SessionStart fires once per session;
# input JSON includes `cwd`. Output JSON shape for additionalContext:
#   {"hookSpecificOutput": {"hookEventName": "SessionStart",
#                           "additionalContext": "..."}}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

# Observability telemetry (csd-observability-stats): instrument the
# orientation hook so accumulated logs capture the DOMINANT per-session
# context cost — the orientation block itself — which was previously
# uninstrumented (only focus-check / state-track / staleness emitted
# telemetry). Sourced before the early-exit checks so the silent-skip fast
# path is measured too; a no-op unless CLAUDE_HOOK_LOG=1. TELEM_EMIT flips
# to 1 only when the block is actually injected. The trap reads PROJECT_DIR
# at exit time (set below); for the rare pre-resolution exit it falls back
# to the env cwd, matching where telemetry would be written anyway.
# shellcheck disable=SC1091
source "$(dirname "$0")/_telemetry.sh"
telem_start
trap 'telem_end session-start-orient.sh "${TELEM_EMIT:-0}" "${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"' EXIT

if ! command -v jq >/dev/null 2>&1; then
    # Fail-open: missing jq shouldn't bork session start
    exit 0
fi

# Phase P C1 (round-3 reviewer): probe [python3, python, py] via shared
# _python.sh helper. The earlier `command -v python` check accepted the
# Windows Microsoft Store stub (which fails at invocation), silently
# breaking session-start orientation on this machine.
# shellcheck disable=SC1091
source "$(dirname "$0")/_python.sh"
ensure_python || exit 0

HOOK_INPUT="$(cat)"
PROJECT_DIR=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')
[[ -n "$PROJECT_DIR" ]] || PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // .sessionId // ""' 2>/dev/null)

# Periodic cleanup of stale tracker files (>7 days old) from $TMPDIR so they
# don't accumulate forever. Covers focus-check counters + warn markers,
# state-track nudges, state-staleness session markers, hook-log warn
# markers, and (Phase R #7 — round-5 reviewer) state-lock files. The
# state-lock glob was MISSING: Phase Q reverted the unlink-on-release
# (correct, per round-4 C-new-3) and the comment claimed this sweep
# handled the litter — but `.claude-state-lock-*` wasn't in the glob,
# so the claim was false. Now it is. Best-effort; failures are silent.
find "${TMPDIR:-/tmp}" -maxdepth 1 \
    \( -name '.claude-focus-check-*' \
       -o -name '.claude-state-track-*' \
       -o -name '.claude-state-staleness-*' \
       -o -name '.claude-state-lock-*' \
       -o -name '.claude-hook-log-warned-*' \) \
    -mtime +7 -delete 2>/dev/null || true

# Phase O #74: POSIX state-lock now nests its files one level deeper, in a
# per-uid 0700 dir (${TMPDIR}/.claude-state-locks-<uid>/). The maxdepth-1
# sweep above can't reach them; sweep stale lock files inside those dirs
# too (the 0700 dir itself is kept — it's reused, ~0 bytes). The unquoted
# glob degrades to a literal if no such dir exists; the find then errors
# harmlessly into the 2>/dev/null || true. Best-effort, same as above.
find "${TMPDIR:-/tmp}"/.claude-state-locks-* -maxdepth 1 \
    -name '.claude-state-lock-*' -mtime +7 -delete 2>/dev/null || true

# Skip if no state.json — no enforcement on uninstrumented projects
if [[ ! -f "${PROJECT_DIR}/.claude/state.json" ]]; then
    exit 0
fi

# where-am-i lives in the plugin's bin/. Use ${CLAUDE_PLUGIN_ROOT} so this
# resolves correctly when fired as a plugin hook.
WHERE_AM_I="${CLAUDE_PLUGIN_ROOT:-}/bin/where-am-i"
if [[ ! -x "$WHERE_AM_I" ]]; then
    # Fall back to PATH (plugin auto-PATH adds bin/)
    if command -v where-am-i >/dev/null 2>&1; then
        WHERE_AM_I=$(command -v where-am-i)
    else
        # Can't find it — silent skip rather than crash
        exit 0
    fi
fi

ORIENT=$("$PYTHON_BIN" "$WHERE_AM_I" "$PROJECT_DIR" 2>/dev/null)
[[ -n "$ORIENT" ]] || exit 0

# Phase M #64 (audit round-1 reviewer top-3 #3): prompt-injection defense.
# The orient block from where-am-i contains state.json-derived strings
# (objective, current_focus, deliverable titles, blocked-on reasons). A
# poisoned state.json could include </state-tracking-orientation> or
# similar close-tag markup; sanitize by replacing ASCII < > with Unicode
# angle quotes (U+2039 ‹, U+203A ›) so the rendered text reads naturally
# but markup interpretation breaks.
SAFE_ORIENT="${ORIENT//</‹}"; SAFE_ORIENT="${SAFE_ORIENT//>/›}"

# Wrap in a clear marker block for the model
WRAPPED=$(printf '<state-tracking-orientation>\n%s\n</state-tracking-orientation>\n\nThis is the auto-injected orientation block from the state-tracking plugin. Treat it as the source of truth for the project'\''s current objective + version + deliverables. Update via the `update-state` skill or by editing .claude/state.json directly after substantial work.' "$SAFE_ORIENT")

# Observability enrichment: record the injected orientation size (the
# dominant per-session context cost) + session id, so accumulated logs can
# report a real per-session cost distribution and count distinct sessions /
# join to state-history transitions. session id is sanitized to a
# whitelist-safe charset so a malformed id can never corrupt the JSONL.
CTX_BYTES=$(printf '%s' "$WRAPPED" | wc -c 2>/dev/null | tr -d '[:space:]')
case "$CTX_BYTES" in ''|*[!0-9]*) CTX_BYTES=0 ;; esac
SAFE_SID="${SESSION_ID//[^A-Za-z0-9_-]/}"
TELEM_EXTRA=$(printf '"ctx_bytes":%s,"session":"%s"' "$CTX_BYTES" "$SAFE_SID")
TELEM_EMIT=1

jq -n --arg ctx "$WRAPPED" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

exit 0
