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
#   FOCUS_CHECK_EVERY=N            — re-anchor cadence (default 6, min 1)
#   FOCUS_CHECK_DISABLE=1          — disable entirely (also disables the
#                                    handoff-pressure nudge, which lives in
#                                    this hook and exits with it)
#   STATE_HANDOFF_NUDGE_DISABLE=1  — disable only the handoff-pressure nudge
#   STATE_HANDOFF_NUDGE_PCT=N      — nudge threshold, exact-% path (default 75)
#   STATE_HANDOFF_NUDGE_TOKENS=N   — nudge threshold, token-estimate fallback
#                                    (default 150000)
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

telemetry_capture focus-check.sh "$INPUT" "$CWD"

# Single jq spawn pulls both session_id and transcript_path (the latter
# needed only by the handoff-pressure nudge's token-estimate fallback
# below) — avoids a second subprocess in the common no-pressure hot path.
_SID_TP=$(printf '%s' "${INPUT}" | jq -r '((.session_id // .sessionId // "") | tostring) + "\t" + ((.transcript_path // "") | tostring)' 2>/dev/null)
SESSION_ID="${_SID_TP%%$'\t'*}"
NUDGE_TRANSCRIPT_PATH="${_SID_TP#*$'\t'}"
[ -z "${SESSION_ID}" ] && exit 0

# ---- handoff-pressure nudge (CSD v0.4.0) — fires at most once per session,
# BEFORE the periodic re-anchor gate below (same-prompt exclusivity: only
# one CSD injection per prompt — if the nudge fires it exits before the
# counter-mod gate can also emit <focus-check>). Reads the exact context %
# from claude-ctx's session-status file when present; falls back to a
# transcript-byte/4 token estimate (never renders a fabricated %). Sentinel
# path uses a sanitized session id (never the raw value) so a hostile
# session_id can't path-traverse the sentinel filename.
if [ "${STATE_HANDOFF_NUDGE_DISABLE:-0}" != "1" ]; then
    NUDGE_SAFE_SID="${SESSION_ID//[^A-Za-z0-9_-]/}"
    if [ -n "$NUDGE_SAFE_SID" ]; then
        NUDGE_SENT_DIR="${CWD}/.claude/.handoff-nudge"
        NUDGE_SENT="${NUDGE_SENT_DIR}/${NUDGE_SAFE_SID}"
        if [ ! -f "$NUDGE_SENT" ]; then
            NUDGE_MSG=""
            # SAFE_SID (not the raw session_id) in the path: a hostile id
            # can't traverse to an attacker-chosen *.json; legit ids are
            # UUID-shaped so sanitize is the identity for them.
            NUDGE_SS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-status/${NUDGE_SAFE_SID}.json"
            if [ -f "$NUDGE_SS_FILE" ]; then
                NUDGE_USED_PCT=$(jq -r '.used_pct // empty' "$NUDGE_SS_FILE" 2>/dev/null)
                # numeric guard (house idiom, cf. NUDGE_TBYTES below): the value
                # feeds an awk compare and the rendered message — non-numeric
                # content (incl. a used_pct crafted as awk program text) is
                # dropped, never interpolated.
                case "$NUDGE_USED_PCT" in ''|.|*[!0-9.]*|*.*.*) NUDGE_USED_PCT="" ;; esac
                if [ -n "$NUDGE_USED_PCT" ]; then
                    NUDGE_PCT_THRESH="${STATE_HANDOFF_NUDGE_PCT:-75}"
                    case "$NUDGE_PCT_THRESH" in ''|.|*[!0-9.]*|*.*.*) NUDGE_PCT_THRESH=75 ;; esac
                    if awk -v p="$NUDGE_USED_PCT" -v t="$NUDGE_PCT_THRESH" 'BEGIN{exit !(p+0 >= t+0)}' 2>/dev/null; then
                        NUDGE_MSG="context ~${NUDGE_USED_PCT%.*}%: consider /claude-state-drift:handoff before it gets tight"
                    fi
                fi
            elif [ -n "$NUDGE_TRANSCRIPT_PATH" ] && [ -f "$NUDGE_TRANSCRIPT_PATH" ]; then
                NUDGE_TBYTES=$(wc -c < "$NUDGE_TRANSCRIPT_PATH" 2>/dev/null | tr -d '[:space:]')
                case "$NUDGE_TBYTES" in ''|*[!0-9]*) NUDGE_TBYTES=0 ;; esac
                NUDGE_TOK=$(( NUDGE_TBYTES / 4 ))
                NUDGE_TOK_THRESH="${STATE_HANDOFF_NUDGE_TOKENS:-150000}"
                if [ "$NUDGE_TOK" -ge "$NUDGE_TOK_THRESH" ]; then
                    NUDGE_MSG="context estimate ~$(( NUDGE_TOK / 1000 ))k tokens: consider /claude-state-drift:handoff before it gets tight"
                fi
            fi
            if [ -n "$NUDGE_MSG" ]; then
                mkdir -p "$NUDGE_SENT_DIR" 2>/dev/null
                # self-ignoring dir: consumer repos (where no committed
                # .claude/.gitignore covers this) never see it in git status.
                # Rewritten every fire so its mtime stays ahead of the prune.
                printf '*\n' > "$NUDGE_SENT_DIR/.gitignore" 2>/dev/null
                : > "$NUDGE_SENT" 2>/dev/null
                # opportunistic 48h prune of stale sentinels (best-effort, never fatal)
                find "$NUDGE_SENT_DIR" -type f -mmin +2880 -delete 2>/dev/null
                TELEM_EXTRA=$(printf '"nudge":1,"session":"%s"' "$NUDGE_SAFE_SID")
                TELEM_EMIT=1
                jq -n --arg ctx "$NUDGE_MSG" \
                    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
                exit 0
            fi
        fi
    fi
fi

# Scoped temp dir. These per-session counters used to land in the SHARED
# system temp root, which is what made session-start-orient.sh's stale-tracker
# sweep O(everything any program on the box ever left there). harness_tmp
# comes from hooks/_tmpdir.sh, which _telemetry.sh (sourced at line 36, before
# every early exit) loads for its own warn-marker path — so there is no second
# source here. An earlier revision added one and the round-1 reviewer caught it
# as dead work whose ${BASH_SOURCE[0]%/*} form also printed
# "focus-check.sh/_tmpdir.sh: Not a directory" on every fire whenever argv0
# carried no slash. Cost, measured rather than asserted: sourcing forks
# nothing, but harness_tmp is NOT free on POSIX — its mode check spends one
# stat fork per call (~1.1ms measured on ubuntu:24.04, vs ~8us for the
# builtin-only tests) and two on macOS, where the GNU probe must fail first.
# Zero forks on Windows, which returns before the stat. Negligible against
# this hook's 600ms budget, but it is real: do not add more work here on the
# assumption that this path is fork-free.
harness_tmp
# Guarded, not decorative: harness_tmp only exists for the 8 hooks that source
# _telemetry.sh, and a bare "$HARNESS_TMP" in a hook that ever stops doing so
# would put this counter at the filesystem root. See _tmpdir.sh's header; T-S12
# pins the form across all of hooks/.
TMP="${HARNESS_TMP:-${TMPDIR:-/tmp}}"
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
        echo "WARN: focus-check.sh cannot persist counter to ${COUNTER_FILE} — focus-check will not fire correctly. dir=${TMP} (TMPDIR=${TMPDIR:-/tmp}); perms: ${TMP_INFO}" >&2
        touch "$WARN_MARKER" 2>/dev/null
    fi
fi

if [ $((COUNTER % EVERY)) -ne 0 ]; then
    exit 0
fi

# SINGLE-PASS state.json read. This was three separate `jq` spawns over the
# same file; measured on Windows at ~109ms each, they were the dominant term
# in this hook's p95adj (775ms against a 600ms budget — perf-bench [OVER]).
# Process COUNT, not parse size, is what costs: one spawn now emits all three
# values, newline-separated.
#
# Phase O #66 (baseline F15): truncate to 300 *codepoints* + ellipsis INSIDE
# the jq read. Bash `${FOCUS:0:300}` is byte-indexed under a byte locale
# (LC_ALL=C) and splits a multibyte char mid-sequence → the downstream
# `jq -n --arg` then either errors (no block emitted) or launders the broken
# bytes into valid-but-wrong mojibake. jq `length` and `[a:b]` are
# Unicode-codepoint-based and locale-independent, so this is correct on every
# platform. `tostring` keeps a non-string current_focus from erroring.
#
# Phase O #70's CR/LF flattening also moves in here, replacing two downstream
# `tr` spawns. It MUST happen inside jq now: the three values are split back
# apart line-by-line, so an embedded newline would desynchronise the split.
# `gsub("[\r\n]+"; " ")` is the same translate-and-squeeze as `tr -s '\r\n' ' '`.
_FC_RAW=$(jq -r '
    def flat: tostring | gsub("[\r\n]+"; " ");
    (.objective // "" | flat),
    (.current_focus // "" | tostring
        | if length > 300 then .[0:300] + "…" else . end
        | flat),
    (.version // "?" | flat)
' "${STATE_FILE}" 2>/dev/null)
OBJECTIVE=${_FC_RAW%%$'\n'*}
_FC_REST=${_FC_RAW#*$'\n'}
FOCUS=${_FC_REST%%$'\n'*}
VERSION=${_FC_REST#*$'\n'}
# jq -r leaks msys2 CRLF line endings on git-bash (handoff learning #5). The
# old `tr -s '\r\n' ' '` swallowed those terminators as a side effect; the
# line-split above does not, so strip the trailing CR explicitly.
OBJECTIVE=${OBJECTIVE%$'\r'}
FOCUS=${FOCUS%$'\r'}
VERSION=${VERSION%$'\r'}

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
# metadata fields — newlines in them carry no legitimate meaning — so any
# CR/LF run is flattened to one space. That now happens inside the single
# jq read above (see there), which removes the two `tr` spawns this step
# used to cost. Defanged, not deleted, consistent with the <> treatment.

BLOCK=$(printf '<focus-check>\nObjective: %s\nCurrent focus: %s\nProject version: %s\nYou are %d turns into this session. Verify your next action serves the focus before proceeding. If it does not, reconsider scope or invoke the re-anchor skill (or /re-anchor).\n</focus-check>' \
    "${SAFE_OBJECTIVE}" "${SAFE_FOCUS}" "${VERSION}" "${COUNTER}")

# Observability enrichment (csd-observability-stats): record WHEN the
# intervention fired (turn counter) and HOW BIG the injected block is
# (bytes), so accumulated telemetry can answer "when does drift prevention
# happen?" and "what does it cost per session?" without transcript mining.
# Emit-path only (every Nth prompt) — the silent-skip hot path never pays
# the extra wc spawn. COUNTER is already validated numeric above.
CTX_BYTES=$(printf '%s' "${BLOCK}" | wc -c 2>/dev/null | tr -d '[:space:]')
case "${CTX_BYTES}" in ''|*[!0-9]*) CTX_BYTES=0 ;; esac
# session id (sanitized to whitelist-safe charset) lets offline analysis
# count distinct sessions and join focus-check activity to the same
# session's state-history transitions.
telem_safe_sid "$SESSION_ID"
TELEM_EXTRA=$(printf '"counter":%d,"ctx_bytes":%s,"session":"%s"' "${COUNTER}" "${CTX_BYTES}" "${SAFE_SID}")

TELEM_EMIT=1   # F-prep.3 telemetry: distinguish actual-emit from silent-skip paths
jq -n --arg ctx "${BLOCK}" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'

exit 0
