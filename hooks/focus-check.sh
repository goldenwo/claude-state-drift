#!/usr/bin/env bash
# focus-check.sh — UserPromptSubmit hook (v0.3.2-dev) that periodically
# re-injects the project's objective + current_focus from .claude/state.json
# into the session context, mitigating mid-session drift.
#
# Fires on every UserPromptSubmit, but only EMITS the focus-check block every
# Nth prompt (default 6). Counter is session-scoped, stored in $TMPDIR keyed
# by session_id so each fresh session starts at 0.
#
# Silent-skip on:
#   - jq missing
#   - state.json missing (uninstrumented projects pay nothing)
#   - state.json malformed
#   - session_id unavailable from hook input
#
# Configuration via environment:
#   FOCUS_CHECK_EVERY=N    — re-anchor cadence (default 6, min 1)
#   FOCUS_CHECK_DISABLE=1  — disable entirely
#
# This is the spec-review-loop's Reflexion-style re-anchor pattern, scoped
# to general work instead of review rounds. UserPromptSubmit is the right
# hook shape (recurring, deterministic, naturally lower-cadence than
# PostToolUse) — see docs/ROADMAP.md change log 2026-05-10.

set +e

# F-prep.3 telemetry — sourced before any early-exit so silent-skip paths
# also get logged (lets us measure the fast-path cost on uninstrumented projects).
# shellcheck disable=SC1091
source "$(dirname "$0")/_telemetry.sh"
telem_start
trap 'telem_end focus-check.sh "${TELEM_EMIT:-0}" "${CWD:-$PWD}"' EXIT

DEFAULT_EVERY=6

# #28 (audit F6): per-project `.claude/hooks-config.json` overrides these
# knobs. Precedence is env override > file > built-in default. Capture
# whether the env var was EXPLICITLY set (via ${VAR+x}, true even for an
# empty value) BEFORE defaulting, so the file layer (applied later, once
# CWD is known + only if the config file exists) can tell "env did not
# set this" from "env set it to something". This keeps existing env-var
# behavior byte-for-byte unchanged: when the env var is set, the file is
# never consulted for that knob.
EVERY_ENV_SET="${FOCUS_CHECK_EVERY+x}"
DISABLE_ENV_SET="${FOCUS_CHECK_DISABLE+x}"

EVERY="${FOCUS_CHECK_EVERY:-$DEFAULT_EVERY}"
case "${EVERY}" in
    ''|*[!0-9]*|0) EVERY=$DEFAULT_EVERY ;;
esac

# Env-set disable still short-circuits here exactly as before (#28 must
# not change the env path): when FOCUS_CHECK_DISABLE is set in the env
# and =1, exit immediately — no CWD resolution, no file read, identical
# to pre-#28. The FILE disable is consulted later (CWD-dependent), only
# when the env var did NOT set it.
if [ -n "$DISABLE_ENV_SET" ]; then
    [ "${FOCUS_CHECK_DISABLE:-0}" = "1" ] && exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# F-prep N4 fix (#32): check state.json existence BEFORE any jq spawn.
# UserPromptSubmit fires on every prompt; uninstrumented projects must
# pay zero subprocess cost. When CLAUDE_PROJECT_DIR is set (every real
# Claude Code session), this resolves the cwd without parsing stdin.
# Falls through to the legacy slow path when env-cwd is missing (harness
# tests) so existing test fixtures still work unchanged.
EARLY_CWD="${CLAUDE_PROJECT_DIR:-}"
INPUT=""

if [ -n "$EARLY_CWD" ]; then
    # Fast path: env-cwd known. Existence check requires zero jq spawns.
    # Assign CWD before any exit so the trap's telem_end uses the right
    # directory (if telemetry is enabled and CLAUDE_PROJECT_DIR has a
    # .claude/ dir, the early-exit fire still gets logged to that project).
    CWD="$EARLY_CWD"
    if [ ! -f "${CWD}/.claude/state.json" ]; then
        exit 0   # uninstrumented project — zero-cost exit (no jq spawn)
    fi
    STATE_FILE="${CWD}/.claude/state.json"
else
    # Slow path: no env-cwd. Read stdin and parse cwd via jq. This is the
    # historical behavior used by bin/focus-check-test fixtures.
    INPUT="$(cat 2>/dev/null)"
    [ -z "${INPUT}" ] && exit 0
    CWD=$(printf '%s' "${INPUT}" | jq -r '.cwd // ""' 2>/dev/null)
    [ -z "${CWD}" ] && CWD="$(pwd)"
    STATE_FILE="${CWD}/.claude/state.json"
    [ -f "${STATE_FILE}" ] || exit 0
fi

# #28 file-layer (audit F6) — apply per-project .claude/hooks-config.json
# overrides for any knob the env var did NOT set. Placement: AFTER the
# state.json existence gate (uninstrumented repos already exited above,
# paying zero cost) and gated on a single `[ -f ]` stat for the config
# file. The overwhelmingly common case is "state.json exists, no
# hooks-config.json" → one cheap stat, NO python/jq spawn, then fall
# through unchanged. Only a repo that actually ships the override file
# pays the reader subprocess. Precedence: env (already resolved above) >
# file (here) > built-in default (already in EVERY). Malformed / absent /
# bad-type → reader exits non-zero → we keep the current value silently
# (no crash, no stderr — the strongest #28 acceptance criterion).
HOOKS_CONFIG="${CWD}/.claude/hooks-config.json"
if [ -f "$HOOKS_CONFIG" ]; then
    # Shared config-read helper (function-only → sourcing never forks).
    # Sourced lazily HERE, inside the `[ -f ]` guard, so the no-config hot
    # path pays only the single stat above and never even sources this
    # helper. _hooks_config.sh lazily sources _python.sh itself (its
    # stat-first plumbing preserves the no-spawn-on-no-config invariant).
    # shellcheck disable=SC1091
    source "$(dirname "$0")/_hooks_config.sh"
    # focus_check_every (int): only when env did NOT set it. The helper
    # folds the stat → python-source → reader → ''|*[!0-9]*|0 guard and
    # echoes a validated int ≥ 1 (rc 0) or nothing (rc != 0 → keep default).
    if [ -z "$EVERY_ENV_SET" ]; then
        _hc_every=$(_read_hook_config_int "$HOOKS_CONFIG" focus_check_every) && EVERY="$_hc_every"
    fi
    # focus_check_disable (bool→"1"/"0"): only when env did NOT set it. The
    # str helper returns the raw "1"/"0"; the domain compare stays here.
    if [ -z "$DISABLE_ENV_SET" ]; then
        _hc_disable=$(_read_hook_config_str "$HOOKS_CONFIG" focus_check_disable)
        [ "$_hc_disable" = "1" ] && exit 0   # file disables focus-check for this project
    fi
fi

# Both paths converge here: state.json exists; need stdin for session_id.
[ -z "${INPUT}" ] && INPUT="$(cat 2>/dev/null)"
[ -z "${INPUT}" ] && exit 0

SESSION_ID=$(printf '%s' "${INPUT}" | jq -r '.session_id // .sessionId // ""' 2>/dev/null)
[ -z "${SESSION_ID}" ] && exit 0

TMP="${TMPDIR:-/tmp}"
COUNTER_FILE="${TMP}/.claude-focus-check-${SESSION_ID}"

COUNTER=0
if [ -f "${COUNTER_FILE}" ]; then
    COUNTER=$(cat "${COUNTER_FILE}" 2>/dev/null)
    case "${COUNTER}" in
        ''|*[!0-9]*) COUNTER=0 ;;
    esac
fi

COUNTER=$((COUNTER + 1))

# Phase K #58 (audit N13): atomic counter write via temp+rename. Reduces the
# window for a partial-write race if the hook is interrupted (signal, killed
# by parent timeout) mid-write. mv is atomic on the same filesystem.
#
# Note re: PID tag — execution plan suggested appending $$ to the counter key
# for parallel-session-with-same-session-id isolation, but every hook fire is
# a NEW bash subshell with a new $$. PID tag would break counter continuity
# (counter never accumulates → focus-check never emits). Stuck with session_id
# only; trusting Claude Code's UUID session_ids are unique across parallel
# sessions. If that assumption breaks upstream, revisit with $PPID-based tag.
TMP_COUNTER="${COUNTER_FILE}.tmp.$$"
if ! { printf '%d\n' "${COUNTER}" > "${TMP_COUNTER}" 2>/dev/null && mv "${TMP_COUNTER}" "${COUNTER_FILE}" 2>/dev/null; }; then
    # Counter write failed (TMPDIR read-only, disk full, etc). Without
    # persistence the counter resets to 1 each fire — focus-check would
    # never emit. Surface to stderr so the operator sees something is wrong.
    # One-shot per session via a marker file (best-effort; if marker also
    # can't be written, the warning may repeat — that's correct signal).
    rm -f "${TMP_COUNTER}" 2>/dev/null
    WARN_MARKER="${TMP}/.claude-focus-check-warned-${SESSION_ID}"
    if [ ! -f "$WARN_MARKER" ]; then
        TMP_INFO=$(ls -ld "$TMP" 2>&1 | head -1)
        echo "WARN: focus-check.sh cannot persist counter to ${COUNTER_FILE} — focus-check will not fire correctly. TMPDIR=${TMP}; perms: ${TMP_INFO}" >&2
        touch "$WARN_MARKER" 2>/dev/null
    fi
fi

if [ $((COUNTER % EVERY)) -ne 0 ]; then
    exit 0
fi

OBJECTIVE=$(jq -r '.objective // ""' "${STATE_FILE}" 2>/dev/null)
# Phase O #66 (baseline F15): truncate to 300 *codepoints* + ellipsis
# INSIDE the jq read. Bash `${FOCUS:0:300}` is byte-indexed under a byte
# locale (LC_ALL=C) and splits a multibyte char mid-sequence → the
# downstream `jq -n --arg` then either errors (no block emitted) or
# launders the broken bytes into valid-but-wrong mojibake. jq `length`
# and `[a:b]` are Unicode-codepoint-based and locale-independent, so this
# is correct on every platform with zero extra processes (reuses this jq
# spawn). `tostring` keeps a non-string current_focus from erroring.
FOCUS=$(jq -r '(.current_focus // "" | tostring | if length > 300 then .[0:300] + "…" else . end)' "${STATE_FILE}" 2>/dev/null)
VERSION=$(jq -r '.version // "?"' "${STATE_FILE}" 2>/dev/null)

[ -z "${OBJECTIVE}" ] && [ -z "${FOCUS}" ] && exit 0

# FOCUS is already truncated+ellipsized codepoint-safe (above, #66).
FOCUS_SHORT="${FOCUS}"

# Phase M #64 (audit round-1 reviewer top-3 #3): defense against prompt-
# injection via state.json content. A malicious or accidental focus/
# objective could carry close-tag markup like </user-prompt-submit-hook>
# or </focus-check> that, when echoed into Claude's context, might be
# interpreted as a frame boundary. Replace ASCII < > with visually-
# similar Unicode angle quotes (U+2039 ‹, U+203A ›) so the rendered text
# reads naturally but the markup interpretation breaks. Cheap; preserves
# JSON-encoding done by jq below as a second defensive layer.
SAFE_OBJECTIVE="${OBJECTIVE//</‹}"; SAFE_OBJECTIVE="${SAFE_OBJECTIVE//>/›}"
SAFE_FOCUS="${FOCUS_SHORT//</‹}"; SAFE_FOCUS="${SAFE_FOCUS//>/›}"

# Phase O #70 (round-3 reviewer F3): newline-prefix injection defense.
# Phase M #64 neutralized <>-markup, but a poisoned objective/current_focus
# can still carry a `\n\nSYSTEM: ignore previous` block whose blank-line
# separator reads as a fresh instruction section. These are single-line
# metadata fields — newlines in them carry no legitimate meaning — so
# flatten any CR/LF run to one space (tr maps \r and \n to space, -s
# squeezes the run). This also strips the msys2 CRLF that jq -r leaks on
# git-bash (handoff learning #5). Defanged, not deleted, consistent with
# the <> treatment above. Single tr keeps the emit path cheap (perf gate).
SAFE_OBJECTIVE=$(printf '%s' "$SAFE_OBJECTIVE" | tr -s '\r\n' ' ')
SAFE_FOCUS=$(printf '%s' "$SAFE_FOCUS" | tr -s '\r\n' ' ')

BLOCK=$(printf '<focus-check>\nObjective: %s\nCurrent focus: %s\nProject version: %s\nYou are %d turns into this session. Verify your next action serves the focus before proceeding. If it does not, reconsider scope or invoke the re-anchor skill (or /re-anchor).\n</focus-check>' \
    "${SAFE_OBJECTIVE}" "${SAFE_FOCUS}" "${VERSION}" "${COUNTER}")

TELEM_EMIT=1   # F-prep.3 telemetry: distinguish actual-emit from silent-skip paths
jq -n --arg ctx "${BLOCK}" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'

exit 0
