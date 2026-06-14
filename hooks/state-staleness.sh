#!/usr/bin/env bash
# state-staleness.sh — Stop hook (v0.3.2-dev). Two independent session-end
# nudges, emitted as ONE combined additionalContext block:
#
#   1. STALENESS — state.json's last_updated lags HEAD commit time by >N hours
#      AND HEAD is >M commits ahead → nudge to invoke update-state. Both
#      thresholds must hold (avoids noise on routine sessions).
#   2. BLOAT (state-archive auto-nudge) — state.json has >=K archivable `done`
#      deliverables (old, never rendered in orientation = pure disk weight) →
#      nudge to run `state-archive --apply`. Keeps the file lean WITHOUT auto-mutating
#      it (the plugin is "nudge, never auto-write"): the hook only flags; the
#      human/agent runs the archive.
#
# Per-session deduplication: at most one emit per session across many Stop events.
#
# Silent-skip on: jq/git/python missing, no .claude/state.json, no .git,
# malformed timestamps, already nudged this session.
#
# Configuration via environment:
#   STATE_STALENESS_DISABLE=1   — master kill: disable the ENTIRE hook
#   STATE_STALENESS_HOURS=N     — staleness lag threshold in hours (default 24)
#   STATE_STALENESS_COMMITS=N   — staleness commits-since threshold (default 3)
#   STATE_ARCHIVE_NUDGE_DISABLE=1    — disable ONLY the bloat half
#   STATE_ARCHIVE_NUDGE_MIN=K        — archivable-deliverable threshold (default 25)

set +e

# F-prep.3 telemetry — sourced before any early-exit.
# shellcheck disable=SC1091
source "$(dirname "$0")/_telemetry.sh"
telem_start
trap 'telem_end state-staleness.sh "${TELEM_EMIT:-0}" "${CWD:-$PWD}"' EXIT

# Master kill — preserves the historical "disable this hook" behavior.
[ "${STATE_STALENESS_DISABLE:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Phase P C1 (round-3 reviewer): probe [python3, python, py] via shared
# _python.sh helper (py = the Windows fallback when python3/python are Store stubs).
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

# #78 (R4 N3) untrusted-CWD validation — defense-in-depth. If a trusted root is
# known ($CLAUDE_PROJECT_DIR set), refuse to chdir into a $CWD that escapes it.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    case "${CWD%/}" in
        "${CLAUDE_PROJECT_DIR%/}"|"${CLAUDE_PROJECT_DIR%/}"/*) ;;  # in-root → proceed
        *) exit 0 ;;                                              # escapes trusted root → silent-skip
    esac
fi

cd "$CWD" 2>/dev/null || exit 0

# Per-session dedup — shared across BOTH nudges (one emit per session total).
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // ""' 2>/dev/null)
NUDGE_FILE=""
if [ -n "$SESSION_ID" ]; then
    NUDGE_FILE="${TMPDIR:-/tmp}/.claude-state-staleness-${SESSION_ID}"
    [ -f "$NUDGE_FILE" ] && exit 0
fi

# --- Staleness half (faithful to the original inline logic; returns the block
# on the STALE_BLOCK global, plus STALE_LAG/STALE_COMMITS for telemetry, or
# leaves them empty). `return 0` at every skip point — must NOT exit, or the
# bloat half below would be lost. ---
STALE_BLOCK=""; STALE_LAG=""; STALE_COMMITS=""
_compute_stale() {
    local LAST_UPDATED HEAD_TIME HOURS_THRESHOLD COMMITS_THRESHOLD LAG_HOURS COMMITS_AHEAD STATE_LIB WARN_FILE
    LAST_UPDATED=$(jq -r '.last_updated // ""' "$STATE_FILE" 2>/dev/null)
    [ -z "$LAST_UPDATED" ] && return 0
    HEAD_TIME=$(git log -1 --format=%aI HEAD 2>/dev/null)
    [ -z "$HEAD_TIME" ] && return 0
    HOURS_THRESHOLD="${STATE_STALENESS_HOURS:-24}"
    COMMITS_THRESHOLD="${STATE_STALENESS_COMMITS:-3}"
    # Hours between state.last_updated and HEAD. Timestamps pass via env vars
    # (LU + HT) — never shell interpolation — so a tampered state.json can't
    # become Python injection (T47 regression-guards this).
    STATE_LIB="$(dirname "$0")/../bin/_state_lib.py"
    LAG_HOURS=$(LU="$LAST_UPDATED" HT="$HEAD_TIME" "$PYTHON" "$STATE_LIB" --lag-hours 2>/dev/null)
    [ -z "$LAG_HOURS" ] && LAG_HOURS="-"
    if [ "$LAG_HOURS" = "-" ]; then
        WARN_FILE="${TMPDIR:-/tmp}/.claude-state-staleness-parsefail-${SESSION_ID:-$$}"
        if [ ! -f "$WARN_FILE" ]; then
            echo "WARN: state-staleness could not parse last_updated='${LAST_UPDATED}' or HEAD time='${HEAD_TIME}'. Staleness check skipped this session." >&2
            touch "$WARN_FILE" 2>/dev/null
        fi
        return 0
    fi
    # Only pass --since when LAG_HOURS>0 (parse succeeded), else git log --since
    # with an unparseable value returns ALL commits → false-trip (Phase P F6).
    if [ "$LAG_HOURS" -gt 0 ] 2>/dev/null; then
        COMMITS_AHEAD=$(git log --since="$LAST_UPDATED" --oneline 2>/dev/null | wc -l | tr -d ' ')
    else
        COMMITS_AHEAD=0
    fi
    [ -z "$COMMITS_AHEAD" ] && COMMITS_AHEAD=0
    [ "$LAG_HOURS" -lt "$HOURS_THRESHOLD" ] || [ "$COMMITS_AHEAD" -lt "$COMMITS_THRESHOLD" ] && return 0
    STALE_BLOCK=$(printf '<state-staleness>\n.claude/state.json is stale:\n  last_updated: %s\n  HEAD commit:  %s (%dh newer than state)\n  Commits since state update: %d\n\nThe state.json does not reflect recent activity. Before declaring the task done, consider invoking the `update-state` skill to catch up. Configurable via STATE_STALENESS_HOURS (default 24) and STATE_STALENESS_COMMITS (default 3); disable via STATE_STALENESS_DISABLE=1.\n</state-staleness>' \
        "$LAST_UPDATED" "$HEAD_TIME" "$LAG_HOURS" "$COMMITS_AHEAD")
    STALE_LAG="$LAG_HOURS"; STALE_COMMITS="$COMMITS_AHEAD"
}
_compute_stale

# --- Bloat half (state-archive auto-nudge): ask state-archive (DRY-RUN) how many `done`
# deliverables are archivable; nudge if it crosses the threshold. The hook NEVER
# archives — it only flags; the human/agent runs `state-archive --apply`. ---
BLOAT_BLOCK=""
if [ "${STATE_ARCHIVE_NUDGE_DISABLE:-0}" != "1" ]; then
    NUDGE_MIN="${STATE_ARCHIVE_NUDGE_MIN:-25}"
    STATE_ARCHIVE="$(dirname "$0")/../bin/state-archive"
    ARCHIVABLE=$("$PYTHON" "$STATE_ARCHIVE" "$CWD" --json 2>/dev/null | jq -r '.archivable // 0' 2>/dev/null)
    [ -z "$ARCHIVABLE" ] && ARCHIVABLE=0
    if [ "$ARCHIVABLE" -ge "$NUDGE_MIN" ] 2>/dev/null; then
        BLOAT_BLOCK=$(printf '<state-bloat>\n.claude/state.json has %d done deliverable(s) old enough to archive (never shown in orientation -- pure disk weight).\nRun the `/claude-state-drift:archive` command (it dry-runs, confirms, then archives to an append-only .claude/state-archive.jsonl -- lossless; git is the backstop), or `state-archive --apply` directly. Tune via STATE_ARCHIVE_NUDGE_MIN (default 25); disable via STATE_ARCHIVE_NUDGE_DISABLE=1.\n</state-bloat>' "$ARCHIVABLE")
    fi
fi

# --- Combine + emit (one additionalContext). ---
COMBINED="$STALE_BLOCK"
if [ -n "$BLOAT_BLOCK" ]; then
    COMBINED="${COMBINED:+$COMBINED$'\n\n'}$BLOAT_BLOCK"
fi
[ -z "$COMBINED" ] && exit 0

[ -n "$NUDGE_FILE" ] && touch "$NUDGE_FILE" 2>/dev/null

# Observability enrichment. When staleness fired, record the goal-aligned
# lag_hours/commits_ahead (a --stats view surfaces "your state was N hours / M
# commits behind your work"). A bloat-only emit records the archivable count
# instead; it still counts as a state-staleness.sh fire in --stats activity
# (acceptable conflation — bloat nudges are rare and stop once you run state-archive).
SAFE_SID="${SESSION_ID//[^A-Za-z0-9_-]/}"
if [ -n "$STALE_BLOCK" ]; then
    TELEM_EXTRA=$(printf '"lag_hours":%s,"commits_ahead":%s,"session":"%s"' "$STALE_LAG" "$STALE_COMMITS" "$SAFE_SID")
else
    TELEM_EXTRA=$(printf '"archivable":%s,"session":"%s"' "${ARCHIVABLE:-0}" "$SAFE_SID")
fi

TELEM_EMIT=1
jq -n --arg ctx "$COMBINED" \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'

exit 0
