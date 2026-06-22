#!/usr/bin/env bash
# Copilot CLI postToolUse adapter — detect a git commit whose subject suggests
# a deliverable transition and emit {"additionalContext": "..."} pointing at
# the update-state skill.
#
# Reads the Copilot postToolUse payload from stdin (JSON). Emits additionalContext
# when the payload describes a git commit tool call whose subject matches the
# transition-keyword regex. Silent (exit 0, no output) otherwise.
#
# Transition-keyword regex: DRY copy of the documented DEFAULT_PATTERN from
# hooks/state-track-commit.sh. If that hook's default changes, update here too.
# (Full DRY via sourcing is not practical cross-repo; the regex is the stable
# public contract documented in SCHEMA.md / the plugin README.)
#
# Field schema CONFIRMED via the Phase 0 hands-on spike (copilot 1.0.63, Windows,
# 2026-06-22). The Copilot postToolUse payload exposes:
#   .toolName              — interpreter that ran ("powershell" on Windows;
#                            "bash"/"shell" on POSIX). Platform-variant, so we do
#                            NOT guard on it — the command-content gate below is
#                            the authoritative, platform-independent filter.
#   .toolArgs              — a JSON-ENCODED STRING, e.g.
#                            {"command":"git commit -m \"...\"","description":"..."}
#   .toolResult.resultType — "success" when the underlying tool run succeeded.
#
# Environment:
#   (none needed — all config comes from stdin)
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

# Cheap substring short-circuit before jq parse — most postToolUse calls are
# not git commits. Skip jq entirely unless both substrings are present.
case "$INPUT" in
    *"git commit"*) ;;
    *) exit 0 ;;
esac

# Extract the command and the tool result in one jq pass. .toolArgs is a JSON-
# ENCODED STRING (Phase 0), so parse it before reading .command. We are off the
# hot path here (only reached when the raw payload already contains "git commit"),
# so favor clarity over shaving jq spawns.
{
    IFS= read -r RESULT_TYPE
    IFS= read -r CMD
} < <(printf '%s' "$INPUT" | jq -r '
    (.toolResult.resultType // ""),
    ((.toolArgs // "" | (if type == "string" then (fromjson? // {}) else . end) | (.command // .input // "")) | tostring | gsub("\n"; " "))
' 2>/dev/null | tr -d '\r')

# Defensive fallback for schema drift across Copilot versions/platforms
# (older payloads exposed the command under .toolInput).
if [ -z "$CMD" ]; then
    CMD="$(printf '%s' "$INPUT" | jq -r '(.toolInput.command // .toolInput.input // "") | tostring | gsub("\n"; " ")' 2>/dev/null | tr -d '\r')"
fi

# Authoritative, platform-independent gate: the command must contain 'git commit'.
# Non-shell tools (file reads, web fetches) carry no .command, so CMD stays empty
# and we exit silently — no tool-name match needed.
case "$CMD" in
    *"git commit"*) ;;
    *) exit 0 ;;
esac

# Skip only on an EXPLICIT non-success result. Absent/empty resultType -> proceed
# (don't suppress a real transition; parity with state-track-commit.sh's
# "treat a missing exit_code as success" stance).
if [ -n "$RESULT_TYPE" ] && [ "$RESULT_TYPE" != "success" ]; then
    exit 0
fi

# Extract the commit subject from the -m argument (best-effort heuristic).
# Handles: git commit -m "subject here" or git commit -m 'subject here'
# For commits without -m (using $EDITOR), we fall back to the full command string.
SUBJECT="$(printf '%s' "$CMD" | grep -oE '\-m[[:space:]]+["'"'"']?[^"'"'"']+["'"'"']?' | sed "s/^-m[[:space:]]*[\"']*//" | sed "s/[\"']*\$//" | head -1)"
[ -n "$SUBJECT" ] || SUBJECT="$CMD"

# Prompt-injection defense: sanitize angle brackets before flowing into JSON context.
SAFE_SUBJECT="${SUBJECT//</‹}"; SAFE_SUBJECT="${SAFE_SUBJECT//>/›}"
# Flatten CR/LF to space (parity with state-track-commit.sh Phase O #70).
SAFE_SUBJECT="$(printf '%s' "$SAFE_SUBJECT" | tr -s '\r\n' ' ')"

# Conservative transition-keyword regex — DRY copy from hooks/state-track-commit.sh
# DEFAULT_PATTERN (Phase K #57, POSIX-portable word-boundary alternatives):
#   (^|non-word)(keyword)(non-word|$)   plus   version-tag (^|non-word)vN.N
# Avoiding 'fix' (too broad). Extends with common past tenses.
TRANSITION_PATTERN="(^|[^[:alnum:]_])(ship|shipped|release|released|complete|completed|done|finish|finished|deliver|delivered)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])v[0-9]+\.[0-9]+"

if ! printf '%s' "$SUBJECT" | grep -qiE -- "$TRANSITION_PATTERN" 2>/dev/null; then
    exit 0
fi

# Emit the nudge as Copilot additionalContext.
NUDGE="Commit just landed with subject: $SAFE_SUBJECT

Subject suggests a deliverable transition but .claude/state.json may not reflect it. Consider invoking the \`/update-state\` skill to log this transition before continuing."

jq -n --arg ctx "$NUDGE" '{"additionalContext": $ctx}'

exit 0
