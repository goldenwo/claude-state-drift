#!/usr/bin/env bash
# state-staleness.sh — Stop hook (v0.3.2-dev). Two independent session-end
# nudges, emitted as ONE combined additionalContext block:
#
#   1. STALENESS — state.json's last_updated lags HEAD commit time by >N hours
#      AND HEAD is >M commits ahead → nudge to invoke update-state. Both
#      thresholds must hold (avoids noise on routine sessions).
#   2. BLOAT (state-clean auto-nudge) — state.json has >=K archivable `done`
#      deliverables (old, never rendered in orientation = pure disk weight) →
#      nudge to run `state-clean --apply`. Keeps the file lean WITHOUT auto-mutating
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
#   STATE_CLEAN_NUDGE_DISABLE=1    — disable ONLY the bloat half
#   STATE_CLEAN_NUDGE_MIN=K        — archivable-deliverable threshold (default 25)

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

# _telemetry.sh also loads hooks/_tmpdir.sh, so harness_tmp is in scope from
# here on. That matters for WHERE it is loaded: this hook `cd`s into the
# project below, and telem_end runs from an EXIT trap afterwards, so any
# helper source resolved post-cd would break for a relative $0.
ensure_python || exit 0
PYTHON="$PYTHON_BIN"

INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$(pwd)}"

telemetry_capture state-staleness.sh "$INPUT" "$CWD"

STATE_FILE="$CWD/.claude/state.json"
[ -f "$STATE_FILE" ] || exit 0
[ -d "$CWD/.git" ] || exit 0

# Guard-skip breadcrumb (spec §3.2, Task 10 / cff15ee follow-up 2): when the
# #78 out-of-root guard below silent-skips, emit a ONE-TIME-PER-SESSION
# stderr breadcrumb (deduped via a marker file) plus a "guard_skip":1
# telemetry enrichment — the silent-skip is no longer invisible to a human
# debugging the harness, nor to --stats analysis. Self-contained: re-parses
# session_id from $INPUT directly rather than relying on either hook's own
# SESSION_ID variable (state-staleness.sh computes SESSION_ID only AFTER this
# guard runs — see below). Kept BYTE-IDENTICAL between state-staleness.sh and
# state-track-commit.sh (paired copies) — edit one, edit both.
_guard_skip() {  # $1 hook-name (uses $CWD, $CLAUDE_PROJECT_DIR, $INPUT globals)
    local sid; sid=$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // ""' 2>/dev/null)
    sid="${sid//[^A-Za-z0-9_-]/}"
    harness_tmp
    local marker="${HARNESS_TMP:-${TMPDIR:-/tmp}}/.claude-guardskip-$1-${sid:-nosid}"
    if [ ! -f "$marker" ]; then
        echo "[$1] cwd-guard skip: cwd=${CWD} root=${CLAUDE_PROJECT_DIR}" >&2
        touch "$marker" 2>/dev/null
    fi
    TELEM_EXTRA='"guard_skip":1'
    exit 0
}

# #78 (R4 N3) untrusted-CWD validation — defense-in-depth. If a trusted root is
# known ($CLAUDE_PROJECT_DIR set), refuse to chdir into a $CWD that escapes it.
# Separator normalization (\ → /) + case-fold apply ONLY under msys/cygwin
# (Windows payloads carry backslash .cwd vs forward-slash $CLAUDE_PROJECT_DIR;
# the raw compare silent-skipped every real fire — T146d regression-lock; see
# state-track-commit.sh #78 note). On POSIX the compare is RAW (cff15ee
# follow-up 3, spec §3.3): \ is a legal, literal filename byte there, so
# normalizing unconditionally would fold a directory literally named
# `proj\evil` into `proj/evil` and let it slip past the trusted-root prefix
# check below.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    case "$OSTYPE" in
        msys*|cygwin*)
            CWD_CMP="${CWD//\\//}"; ROOT_CMP="${CLAUDE_PROJECT_DIR//\\//}"
            CWD_CMP="${CWD_CMP,,}"; ROOT_CMP="${ROOT_CMP,,}" ;;  # NTFS is case-insensitive (spec §3.1)
        *)  CWD_CMP="$CWD"; ROOT_CMP="$CLAUDE_PROJECT_DIR" ;;  # POSIX: raw, case-sensitive, no separator folding
    esac
    case "${CWD_CMP%/}" in
        "${ROOT_CMP%/}"|"${ROOT_CMP%/}"/*) ;;  # in-root → proceed
        *) _guard_skip "state-staleness.sh" ;;  # escapes trusted root → deduped stderr breadcrumb + guard_skip telemetry
    esac
fi

cd "$CWD" 2>/dev/null || exit 0

# Per-session dedup — shared across BOTH nudges (one emit per session total).
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // ""' 2>/dev/null)
# Resolve the scoped temp dir UNCONDITIONALLY here, not inside the SESSION_ID
# guard below: the parsefail WARN_FILE in _compute_stale also needs
# HARNESS_TMP and is reachable with an empty SESSION_ID, which would
# otherwise leave it writing to "/.claude-state-staleness-parsefail-$$".
harness_tmp

NUDGE_FILE=""
if [ -n "$SESSION_ID" ]; then
    NUDGE_FILE="${HARNESS_TMP:-${TMPDIR:-/tmp}}/.claude-state-staleness-${SESSION_ID}"
    [ -f "$NUDGE_FILE" ] && exit 0
fi

# --- Staleness half (faithful to the original inline logic; returns the block
# on the STALE_BLOCK global, plus STALE_LAG/STALE_COMMITS for telemetry, or
# leaves them empty). `return 0` at every skip point — must NOT exit, or the
# bloat half below would be lost. ---
STALE_BLOCK=""; STALE_LAG=""; STALE_COMMITS=""
_compute_stale() {
    local LAST_UPDATED HEAD_TIME HOURS_THRESHOLD COMMITS_THRESHOLD STATE_LIB WARN_FILE RESULT LAG_HOURS COMMITS_AHEAD IS_STALE
    LAST_UPDATED=$(jq -r '.last_updated // ""' "$STATE_FILE" 2>/dev/null)
    [ -z "$LAST_UPDATED" ] && return 0
    HEAD_TIME=$(git log -1 --format=%aI HEAD 2>/dev/null)
    [ -z "$HEAD_TIME" ] && return 0
    HOURS_THRESHOLD="${STATE_STALENESS_HOURS:-24}"
    COMMITS_THRESHOLD="${STATE_STALENESS_COMMITS:-3}"
    # fleet-steward P2 Task 8 (survey cluster 4): the two-clause predicate
    # itself — lag-hours AND commits-since, plus the Phase P F6
    # unparseable-`--since` guard — now lives in exactly ONE place,
    # bin/_state_lib.evaluate_staleness(). This hook resolves its own
    # thresholds (above, unchanged) and passes EVERYTHING by env var —
    # LU/HT/REPO/HOURS_T/COMMITS_T — never shell/argv interpolation, so a
    # tampered state.json can't become Python injection (T47
    # regression-guards this; the CLI's own --staleness branch never reads
    # argv values either).
    STATE_LIB="$(dirname "$0")/../bin/_state_lib.py"
    RESULT=$(LU="$LAST_UPDATED" HT="$HEAD_TIME" REPO="$CWD" \
             HOURS_T="$HOURS_THRESHOLD" COMMITS_T="$COMMITS_THRESHOLD" \
             "$PYTHON" "$STATE_LIB" --staleness 2>/dev/null)
    LAG_HOURS=$(printf '%s' "$RESULT" | awk '{print $1}')
    COMMITS_AHEAD=$(printf '%s' "$RESULT" | awk '{print $2}')
    IS_STALE=$(printf '%s' "$RESULT" | awk '{print $3}')
    [ -z "$LAG_HOURS" ] && LAG_HOURS="-"
    if [ "$LAG_HOURS" = "-" ]; then
        WARN_FILE="${HARNESS_TMP:-${TMPDIR:-/tmp}}/.claude-state-staleness-parsefail-${SESSION_ID:-$$}"
        if [ ! -f "$WARN_FILE" ]; then
            echo "WARN: state-staleness could not parse last_updated='${LAST_UPDATED}' or HEAD time='${HEAD_TIME}'. Staleness check skipped this session." >&2
            touch "$WARN_FILE" 2>/dev/null
        fi
        return 0
    fi
    [ -z "$COMMITS_AHEAD" ] && COMMITS_AHEAD=0
    [ "$IS_STALE" = "1" ] || return 0
    STALE_BLOCK=$(printf '<state-staleness>\n.claude/state.json is stale:\n  last_updated: %s\n  HEAD commit:  %s (%dh newer than state)\n  Commits since state update: %d\n\nThe state.json does not reflect recent activity. Before declaring the task done, consider invoking the `update-state` skill to catch up. Configurable via STATE_STALENESS_HOURS (default 24) and STATE_STALENESS_COMMITS (default 3); disable via STATE_STALENESS_DISABLE=1.\n</state-staleness>' \
        "$LAST_UPDATED" "$HEAD_TIME" "$LAG_HOURS" "$COMMITS_AHEAD")
    STALE_LAG="$LAG_HOURS"; STALE_COMMITS="$COMMITS_AHEAD"
}
_compute_stale

# --- Bloat half (state-clean auto-nudge): ask state-clean (DRY-RUN) how many `done`
# deliverables are archivable; nudge if it crosses the threshold. The hook NEVER
# archives — it only flags; the human/agent runs `state-clean --apply`. ---
BLOAT_BLOCK=""
if [ "${STATE_CLEAN_NUDGE_DISABLE:-0}" != "1" ]; then
    NUDGE_MIN="${STATE_CLEAN_NUDGE_MIN:-25}"
    STATE_CLEAN="$(dirname "$0")/../bin/state-clean"
    ARCHIVABLE=$("$PYTHON" "$STATE_CLEAN" "$CWD" --json 2>/dev/null | jq -r '.archivable // 0' 2>/dev/null)
    [ -z "$ARCHIVABLE" ] && ARCHIVABLE=0
    if [ "$ARCHIVABLE" -ge "$NUDGE_MIN" ] 2>/dev/null; then
        BLOAT_BLOCK=$(printf '<state-bloat>\n.claude/state.json has %d done deliverable(s) old enough to archive (never shown in orientation -- pure disk weight).\nRun the `/claude-state-drift:clean` command (it dry-runs, confirms, then archives to an append-only .claude/state-archive.jsonl -- lossless; git is the backstop), or `state-clean --apply` directly. Tune via STATE_CLEAN_NUDGE_MIN (default 25); disable via STATE_CLEAN_NUDGE_DISABLE=1.\n</state-bloat>' "$ARCHIVABLE")
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
# (acceptable conflation — bloat nudges are rare and stop once you run state-clean).
telem_safe_sid "$SESSION_ID"
if [ -n "$STALE_BLOCK" ]; then
    TELEM_EXTRA=$(printf '"lag_hours":%s,"commits_ahead":%s,"session":"%s"' "$STALE_LAG" "$STALE_COMMITS" "$SAFE_SID")
else
    TELEM_EXTRA=$(printf '"archivable":%s,"session":"%s"' "${ARCHIVABLE:-0}" "$SAFE_SID")
fi

TELEM_EMIT=1
jq -n --arg ctx "$COMBINED" \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'

exit 0
