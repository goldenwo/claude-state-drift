#!/usr/bin/env bash
# state-staleness.sh — Stop hook (v0.3.2-dev). Compares state.json's
# last_updated against HEAD commit time. If state is stale by >N hours AND
# HEAD is >M commits ahead of state.last_updated, emit a one-time per-session
# nudge to invoke update-state.
#
# Two thresholds must BOTH hold to fire — avoids noise on routine sessions
# without substantive commits. Per-session deduplication means only one
# nudge per session even across many Stop events.
#
# Silent-skip on:
#   - jq, git, or python missing
#   - no .claude/state.json
#   - no .git
#   - malformed timestamps
#   - already nudged this session
#
# Configuration via environment:
#   STATE_STALENESS_DISABLE=1            — disable entirely
#   STATE_STALENESS_HOURS=N              — lag threshold in hours (default 24)
#   STATE_STALENESS_COMMITS=N            — commits-since threshold (default 3)

set +e

# F-prep.3 telemetry — sourced before any early-exit.
# shellcheck disable=SC1091
source "$(dirname "$0")/_telemetry.sh"
telem_start
trap 'telem_end state-staleness.sh "${TELEM_EMIT:-0}" "${CWD:-$PWD}"' EXIT

[ "${STATE_STALENESS_DISABLE:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Phase P C1 (round-3 reviewer): probe [python3, python, py] via shared
# _python.sh helper. Previous two-candidate loop missed `py` (PEP-397
# launcher), the reliable Windows fallback when python3/python are
# Microsoft Store stubs.
# shellcheck disable=SC1091
source "$(dirname "$0")/_python.sh"
ensure_python || exit 0
PYTHON="$PYTHON_BIN"

INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$(pwd)}"

STATE_FILE="$CWD/.claude/state.json"
[ -f "$STATE_FILE" ] || exit 0
[ -d "$CWD/.git" ] || exit 0

# #78 (R4 N3) untrusted-CWD validation — defense-in-depth, NOT a live
# vuln (Claude Code supplies $CWD; not adversarial under the current
# trust model). If a trusted root IS known ($CLAUDE_PROJECT_DIR set),
# refuse to chdir into a $CWD that escapes it — silent-skip (exit 0)
# rather than enforce inside an untrusted tree. Pure-bash prefix match
# (no realpath spawn — this is on the Stop hot path). When
# $CLAUDE_PROJECT_DIR is unset (legitimate: harness tests, some launch
# modes) the check is skipped entirely so behavior is UNCHANGED.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    case "${CWD%/}" in
        "${CLAUDE_PROJECT_DIR%/}"|"${CLAUDE_PROJECT_DIR%/}"/*) ;;  # in-root → proceed (normal case)
        *) exit 0 ;;                                              # escapes trusted root → silent-skip
    esac
fi

cd "$CWD" 2>/dev/null || exit 0

# Per-session dedup
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // ""' 2>/dev/null)
NUDGE_FILE=""
if [ -n "$SESSION_ID" ]; then
    NUDGE_FILE="${TMPDIR:-/tmp}/.claude-state-staleness-${SESSION_ID}"
    [ -f "$NUDGE_FILE" ] && exit 0
fi

LAST_UPDATED=$(jq -r '.last_updated // ""' "$STATE_FILE" 2>/dev/null)
[ -z "$LAST_UPDATED" ] && exit 0

HEAD_TIME=$(git log -1 --format=%aI HEAD 2>/dev/null)
[ -z "$HEAD_TIME" ] && exit 0

HOURS_THRESHOLD="${STATE_STALENESS_HOURS:-24}"
COMMITS_THRESHOLD="${STATE_STALENESS_COMMITS:-3}"

# Hours between state.last_updated and HEAD commit time. Integer; 0 if state
# is newer than HEAD (or parse error).
#
# Delegates to bin/_state_lib.py via its --lag-hours CLI mode (Phase F #34).
# Timestamps pass through env vars (LU + HT) — never shell interpolation —
# so a tampered state.json can't become Python code injection. The library
# script is fully hard-coded; T47 regression-tests this property.
STATE_LIB="$(dirname "$0")/../bin/_state_lib.py"
LAG_HOURS=$(LU="$LAST_UPDATED" HT="$HEAD_TIME" "$PYTHON" "$STATE_LIB" --lag-hours 2>/dev/null)
[ -z "$LAG_HOURS" ] && LAG_HOURS="-"

# Phase Q F-new-5 (round-4 reviewer): "-" sentinel means parse failed.
# Distinct from LAG_HOURS=0 (which is "state newer than HEAD" — valid).
# Parse failures used to be silent; surface a one-time stderr warning so
# operators see when state.json's last_updated stops being parseable.
if [ "$LAG_HOURS" = "-" ]; then
    WARN_FILE="${TMPDIR:-/tmp}/.claude-state-staleness-parsefail-${SESSION_ID:-$$}"
    if [ ! -f "$WARN_FILE" ]; then
        echo "WARN: state-staleness could not parse last_updated='${LAST_UPDATED}' or HEAD time='${HEAD_TIME}'. Staleness check skipped this session." >&2
        touch "$WARN_FILE" 2>/dev/null
    fi
    exit 0
fi

# Commits landed since last_updated. git log accepts ISO 8601 in --since.
#
# Phase P F6 (round-3 reviewer): if $LAST_UPDATED is unparseable, `git log
# --since="$LAST_UPDATED"` falls back to "no time filter" → returns ALL
# commits → COMMITS_AHEAD reflects the entire repo history → false-trips
# the threshold. Guard: only pass --since if our LAG_HOURS computation
# above succeeded with a positive value (which means parse_iso ran cleanly
# on the same value). LAG_HOURS=0 covers both "newer than HEAD" and "parse
# failed" cases — in both, skip the --since path and count 0 commits.
if [ "$LAG_HOURS" -gt 0 ] 2>/dev/null; then
    COMMITS_AHEAD=$(git log --since="$LAST_UPDATED" --oneline 2>/dev/null | wc -l | tr -d ' ')
else
    COMMITS_AHEAD=0
fi
[ -z "$COMMITS_AHEAD" ] && COMMITS_AHEAD=0

# Both conditions must hold
if [ "$LAG_HOURS" -lt "$HOURS_THRESHOLD" ] || [ "$COMMITS_AHEAD" -lt "$COMMITS_THRESHOLD" ]; then
    exit 0
fi

BLOCK=$(printf '<state-staleness>\n.claude/state.json is stale:\n  last_updated: %s\n  HEAD commit:  %s (%dh newer than state)\n  Commits since state update: %d\n\nThe state.json does not reflect recent activity. Before declaring the task done, consider invoking the `update-state` skill to catch up. Configurable via STATE_STALENESS_HOURS (default 24) and STATE_STALENESS_COMMITS (default 3); disable via STATE_STALENESS_DISABLE=1.\n</state-staleness>' \
    "$LAST_UPDATED" "$HEAD_TIME" "$LAG_HOURS" "$COMMITS_AHEAD")

[ -n "$NUDGE_FILE" ] && touch "$NUDGE_FILE" 2>/dev/null

TELEM_EMIT=1   # F-prep.3 telemetry: actual staleness nudge emission
jq -n --arg ctx "$BLOCK" \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'

exit 0
