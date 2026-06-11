#!/usr/bin/env bash
# state-track-commit.sh — PostToolUse hook (v0.3.2-dev). Nudges to update
# .claude/state.json when a git commit lands that didn't include state changes
# AND the subject suggests a deliverable transition.
#
# Fires on every PostToolUse(Bash) tool call but exits cheaply unless the
# command was a successful `git commit`. Repeat-nudge prevention via a
# session-scoped tracker file in $TMPDIR.
#
# Silent-skip on:
#   - jq or git missing
#   - non-Bash tool, non-`git commit` command, failed commit
#   - missing .claude/state.json or .git
#   - state.json already in the commit
#   - subject doesn't match transition pattern
#
# Configuration via environment:
#   STATE_TRACK_DISABLE=1                 — disable entirely
#   STATE_TRACK_PATTERN=<regex>           — override transition-keyword regex
#                                           (default: ship|release|complete|
#                                            done|finish|deliver + v\d+\.\d+)
#
# Per-project config (#29, audit Phase D) via .claude/hooks-config.json:
#   {"state_track_pattern": "<regex>"}    — same override, per-repo (no env).
# Precedence: env STATE_TRACK_PATTERN > hooks-config.json > built-in default.
# A malformed/empty file regex silently falls back to the default.

set +e

# F-prep.3 telemetry — sourced before any early-exit.
# shellcheck disable=SC1091
source "$(dirname "$0")/_telemetry.sh"
telem_start
trap 'telem_end state-track-commit.sh "${TELEM_EMIT:-0}" "${CWD:-$PWD}"' EXIT

[ "${STATE_TRACK_DISABLE:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

# Cheap bash-only short-circuit BEFORE invoking jq — this hook fires on every
# PostToolUse(Bash), most of which aren't git commits. Substring check skips
# jq parsing entirely for unrelated commands.
case "$INPUT" in
    *'"tool_name":"Bash"'*) ;;
    *) exit 0 ;;
esac
case "$INPUT" in
    *"git commit"*) ;;
    *) exit 0 ;;
esac

# Phase F #33: consolidate what was 5 separate jq spawns into ONE jq call.
# Each value is on its own line (newlines in tool_input.command rewritten to
# spaces so the read-N-lines pattern stays correct). Cuts ~30ms off every
# Bash PostToolUse fire that matches the substring filter above.
#
# NOTE: tool_response.exit_code field presence in PostToolUse(Bash) payload is
# not fully documented. We treat a missing field as success (// 0) — if Claude
# Code never emits it for Bash, this hook nudges on every successful-looking
# commit. The subsequent git-log check ensures we only nudge for real commits
# that actually landed (failed commits don't change HEAD).
{
    IFS= read -r TOOL_NAME
    IFS= read -r CMD
    IFS= read -r EXIT_CODE
    IFS= read -r CWD
    IFS= read -r SESSION_ID
} < <(printf '%s' "$INPUT" | jq -r '
    .tool_name // "",
    (.tool_input.command // "" | tostring | gsub("\n"; " ")),
    (.tool_response.exit_code // 0 | tostring),
    .cwd // "",
    .session_id // .sessionId // ""
' 2>/dev/null | tr -d '\r')

[ "$TOOL_NAME" = "Bash" ] || exit 0

case "$CMD" in
    *"git commit"*) ;;
    *) exit 0 ;;
esac

[ "$EXIT_CODE" = "0" ] || exit 0

[ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$(pwd)}"

STATE_FILE="$CWD/.claude/state.json"
[ -f "$STATE_FILE" ] || exit 0
[ -d "$CWD/.git" ] || exit 0

# #78 (R4 N3) untrusted-CWD validation — defense-in-depth, NOT a live
# vuln (Claude Code supplies $CWD; not adversarial under the current
# trust model). If a trusted root IS known ($CLAUDE_PROJECT_DIR set),
# refuse to chdir into a $CWD that escapes it — silent-skip (exit 0)
# rather than enforce inside an untrusted tree. Pure-bash prefix match
# (no realpath spawn — this is on the every-commit hot path). When
# $CLAUDE_PROJECT_DIR is unset (legitimate: harness tests, some launch
# modes) the check is skipped entirely so behavior is UNCHANGED.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    case "${CWD%/}" in
        "${CLAUDE_PROJECT_DIR%/}"|"${CLAUDE_PROJECT_DIR%/}"/*) ;;  # in-root → proceed (normal case)
        *) exit 0 ;;                                              # escapes trusted root → silent-skip
    esac
fi

cd "$CWD" 2>/dev/null || exit 0

LATEST_COMMIT=$(git log -1 --format=%H 2>/dev/null)
[ -z "$LATEST_COMMIT" ] && exit 0

# Phase G #41 (audit N10): HEAD-timestamp freshness guard. PostToolUse
# fires AFTER the Bash command, so we can't snapshot HEAD before. Instead,
# only proceed if the latest commit was actually made within the last
# STATE_TRACK_FRESH_SECS seconds (default 60). This distinguishes
# "fresh commit from THIS bash fire" from "old commit that just happens
# to be HEAD" — e.g., `cat script.sh` where script.sh mentions
# 'git commit', or a failed pre-commit-hook attempt followed by an
# unrelated successful Bash with 'git commit' substring. The previous
# heuristic (trust tool_response.exit_code + check HEAD subject) could
# false-nudge on those.
#
# Defensive: if git or date fail (returncode != 0, empty output), fall
# through to the legacy behavior rather than silent-skip. Better to risk
# an occasional spurious nudge than to suppress a real one.
FRESH_SECS="${STATE_TRACK_FRESH_SECS:-60}"
LATEST_COMMIT_AGE=$(git log -1 --format=%ct 2>/dev/null)
NOW=$(date +%s 2>/dev/null)
if [ -n "$LATEST_COMMIT_AGE" ] && [ -n "$NOW" ]; then
    AGE_SECS=$(( NOW - LATEST_COMMIT_AGE ))
    if [ "$AGE_SECS" -gt "$FRESH_SECS" ] 2>/dev/null; then
        exit 0
    fi
fi

# Repeat-nudge prevention: same session + same commit = don't re-emit
NUDGE_FILE=""
if [ -n "$SESSION_ID" ]; then
    NUDGE_FILE="${TMPDIR:-/tmp}/.claude-state-track-${SESSION_ID}"
    LAST_NUDGED=$(cat "$NUDGE_FILE" 2>/dev/null)
    [ "$LAST_NUDGED" = "$LATEST_COMMIT" ] && exit 0
fi

# Did the commit include .claude/state.json? Use diff-tree (faster than show).
if git diff-tree --no-commit-id --name-only -r "$LATEST_COMMIT" 2>/dev/null | grep -qE '(^|/)\.claude/state\.json$'; then
    [ -n "$NUDGE_FILE" ] && printf '%s\n' "$LATEST_COMMIT" > "$NUDGE_FILE" 2>/dev/null
    exit 0
fi

SUBJECT=$(git log -1 --format=%s "$LATEST_COMMIT" 2>/dev/null)
[ -z "$SUBJECT" ] && exit 0

# Phase M #64: prompt-injection defense — a hostile committer could craft
# a subject containing </close-tag> markup. Sanitize before this string
# flows into the additionalContext block below.
SAFE_SUBJECT="${SUBJECT//</‹}"; SAFE_SUBJECT="${SAFE_SUBJECT//>/›}"

# Phase O #70: newline-prefix injection defense — parity with focus-check /
# where-am-i (ROADMAP #70 scope). git %s is a single line so this is
# normally a no-op; it hardens against any future multi-line subject
# extraction and strips the msys2 CRLF jq/git can leak here (handoff
# learning #5). Single tr flattens any CR/LF run to one space; defanged,
# not deleted.
SAFE_SUBJECT=$(printf '%s' "$SAFE_SUBJECT" | tr -s '\r\n' ' ')

# Conservative transition keywords (avoid 'fix' — too broad). Plus version-tag mentions.
#
# Phase K #57 (audit N11): use POSIX-portable word-boundary alternatives
# instead of GNU `\b`. macOS BSD `grep -E` handles `\b` inconsistently —
# `(^|[^[:alnum:]_])` (start-of-string or non-word char before) and
# `([^[:alnum:]_]|$)` (non-word char or end-of-string after) work on every
# POSIX ERE implementation. T38 ("evangelism4.5" false-positive guard) still
# passes because "v" in "evangelism" is preceded by a word char.
DEFAULT_PATTERN="(^|[^[:alnum:]_])(ship|shipped|release|released|complete|completed|done|finish|finished|deliver|delivered)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])v[0-9]+\.[0-9]+"

# #29 (audit Phase D): resolve the transition-keyword regex with the C1
# (#28) precedence — env STATE_TRACK_PATTERN > .claude/hooks-config.json
# (state_track_pattern) > built-in DEFAULT_PATTERN. The env layer is
# byte-unchanged (set → wins raw, exactly as before #29). The FILE layer
# slots between env and default and reuses bin/read-hooks-config (the #75
# single-fd O_NOFOLLOW reader) gated on a single `[ -f ]` stat — a repo
# with no hooks-config.json (the common case) pays one stat, NO python
# spawn, and falls straight through to the default. _python.sh is sourced
# lazily INSIDE the `[ -f ]` block, mirroring focus-check.sh / the #37
# resolvers, so the no-config path never even pays the interpreter probe.
# We are already past the every-fire short-circuits here (confirmed fresh
# git commit + state.json present), so this resolution runs only for a
# real commit, never on the every-PostToolUse(Bash) hot path.
if [ -n "${STATE_TRACK_PATTERN+x}" ]; then
    # env explicitly set (even to empty) → it wins, raw, byte-unchanged.
    PATTERN="$STATE_TRACK_PATTERN"
else
    PATTERN="$DEFAULT_PATTERN"
    HOOKS_CONFIG="$CWD/.claude/hooks-config.json"
    # Plumbing (stat → _python.sh source → ensure_python → reader spawn →
    # rc/non-empty) is folded into _read_hook_config_str (function-only
    # helper → sourcing never forks; its stat-first guard keeps the no-
    # config path spawn-free). The DOMAIN-SPECIFIC regex-safety block below
    # stays in the caller verbatim — only the read is shared.
    # shellcheck disable=SC1091
    source "$(dirname "$0")/_hooks_config.sh"
    _stp=$(_read_hook_config_str "$HOOKS_CONFIG" state_track_pattern)
    if [ -n "$_stp" ]; then
        # Regex safety: the value is a per-project string that
        # could be a malformed/hostile ERE, or a valid-but-
        # degenerate one (e.g. a lone quantifier "*", which GNU
        # grep accepts with a warning yet matches EVERY subject →
        # a nudge on every commit). grep -E exits 2 on an invalid
        # pattern (0=match, 1=no-match) and would emit a stderr
        # warning. Validate ONCE, stderr silenced, on two counts:
        #   (a) well-formed — rc <= 1 against empty input (>= 2 is
        #       an invalid ERE); AND
        #   (b) selective — does NOT match a known non-transition
        #       sentinel (rejects lone-quantifier match-all values
        #       that pass (a) but would fire on every commit).
        # Either check failing => keep the default. The reader
        # already rejects empty / control-char values. No crash,
        # no noise — the #28/#29 silent-default contract.
        printf '' | grep -qE -- "$_stp" 2>/dev/null
        if [ $? -le 1 ] \
           && ! printf 'zzz_not_a_transition_subject_zzz' \
                | grep -qE -- "$_stp" 2>/dev/null; then
            PATTERN="$_stp"
        fi
    fi
fi

if ! printf '%s' "$SUBJECT" | grep -qiE -- "$PATTERN" 2>/dev/null; then
    [ -n "$NUDGE_FILE" ] && printf '%s\n' "$LATEST_COMMIT" > "$NUDGE_FILE" 2>/dev/null
    exit 0
fi

BLOCK=$(printf '<state-update-nudge>\nCommit %s just landed:\n  %s\n\nSubject suggests a deliverable transition but .claude/state.json was NOT in the commit. Consider invoking the `update-state` skill to reflect this change before continuing. Disable via STATE_TRACK_DISABLE=1; tune the keyword regex via STATE_TRACK_PATTERN or .claude/hooks-config.json state_track_pattern.\n</state-update-nudge>' \
    "${LATEST_COMMIT:0:7}" "$SAFE_SUBJECT")

[ -n "$NUDGE_FILE" ] && printf '%s\n' "$LATEST_COMMIT" > "$NUDGE_FILE" 2>/dev/null

TELEM_EMIT=1   # F-prep.3 telemetry: actual nudge emission
jq -n --arg ctx "$BLOCK" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'

exit 0
