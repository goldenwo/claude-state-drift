#!/usr/bin/env bash
# _telemetry.sh — sourceable helper that appends hook-fire telemetry
# records to <cwd>/.claude/.hook-log.jsonl when CLAUDE_HOOK_LOG=1.
#
# Usage from a hook (after `set +e` and any early disable-checks):
#     source "$(dirname "$0")/_telemetry.sh"
#     telem_start
#     trap 'telem_end <hook-name> "${TELEM_EMIT:-0}" "${CWD:-$PWD}"' EXIT
#     # ... hook body ...
#     # Set TELEM_EMIT=1 just before any real emit (jq -n ... line); leave
#     # at 0 (default) for silent-skip paths.
#
# Record shape (one JSON object per line):
#     {"hook":"focus-check.sh","ts":"2026-05-11T12:34:56Z","duration_ms":12,"fired_emit":1}
#
# Configuration:
#     CLAUDE_HOOK_LOG=1                — enable (default: disabled, no-op)
#     CLAUDE_HOOK_LOG_MAX_BYTES=N      — size cap (default: 10485760 = 10MB)
#
# Size cap: when the log file size ≥ MAX_BYTES, the hook refuses further
# writes for this session and emits a one-shot stderr warning (marker
# file pattern, same as focus-check counter-write-failure). Kill switch
# beyond cap is CLAUDE_HOOK_LOG=0.
#
# Portability: uses `date +%s%N` (GNU date / git-bash). On BSD date
# (macOS, FreeBSD) %N is literal — we detect this once and fall back
# to seconds × 1000 (sub-second precision lost but log shape preserved).

# Detect nanosecond support once per source.
if [ -z "${_TEL_NS_OK:-}" ]; then
    _TEL_PROBE=$(date +%s%N 2>/dev/null)
    case "$_TEL_PROBE" in
        *N|'') _TEL_NS_OK=0 ;;
        *) _TEL_NS_OK=1 ;;
    esac
    export _TEL_NS_OK
fi

_telem_now_ms() {
    if [ "$_TEL_NS_OK" = "1" ]; then
        echo "$(( $(date +%s%N) / 1000000 ))"
    else
        # BSD fallback — millisecond column is always 0; sufficient for log shape
        echo "$(( $(date +%s) * 1000 ))"
    fi
}

telem_start() {
    [ "${CLAUDE_HOOK_LOG:-0}" = "1" ] || return 0
    _TELEM_START_MS=$(_telem_now_ms 2>/dev/null) || _TELEM_START_MS=""
}

telem_end() {
    [ "${CLAUDE_HOOK_LOG:-0}" = "1" ] || return 0
    [ -z "${_TELEM_START_MS:-}" ] && return 0
    local hook="$1" fired_emit="${2:-0}" cwd="${3:-$PWD}"
    local end_ms duration_ms log_file size max_bytes warn_marker ts

    end_ms=$(_telem_now_ms 2>/dev/null) || return 0
    duration_ms=$(( end_ms - _TELEM_START_MS ))
    [ "$duration_ms" -lt 0 ] && duration_ms=0

    log_file="${cwd}/.claude/.hook-log.jsonl"
    [ -d "${cwd}/.claude" ] || return 0

    # Phase Q Sec P1-B (round-4 security review): validate that
    # CLAUDE_HOOK_LOG_MAX_BYTES is a positive integer. Empty / non-numeric
    # / negative values would silently bypass the cap (the `2>/dev/null`
    # below swallowed the non-numeric-comparison error). Fallback to the
    # 10MB default keeps the cap honest.
    max_bytes="${CLAUDE_HOOK_LOG_MAX_BYTES:-10485760}"
    case "$max_bytes" in
        ''|*[!0-9]*) max_bytes=10485760 ;;   # empty or non-digit → default
        0) max_bytes=10485760 ;;              # 0 → default (disabling cap not allowed)
    esac
    if [ -f "$log_file" ]; then
        size=$(wc -c < "$log_file" 2>/dev/null) || size=0
        # Trim whitespace from wc output (varies across platforms)
        size="${size// /}"
        size="${size//$'\t'/}"
        if [ "$size" -ge "$max_bytes" ] 2>/dev/null; then
            warn_marker="${TMPDIR:-/tmp}/.claude-hook-log-warned-$$"
            if [ ! -f "$warn_marker" ]; then
                echo "WARN: ${log_file} (${size} bytes) >= cap ${max_bytes}; refusing telemetry writes this session. Set CLAUDE_HOOK_LOG=0 to disable, or truncate/rotate the file." >&2
                touch "$warn_marker" 2>/dev/null || true
            fi
            return 0
        fi
    fi

    # ISO 8601 UTC second precision is enough; sub-second is in duration_ms.
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts="?"

    # Validate fired_emit is 0 or 1 (sanitize input — hooks always pass literal).
    case "$fired_emit" in
        0|1) ;;
        *) fired_emit=0 ;;
    esac

    # Append JSONL line. POSIX small-write atomicity for lines under PIPE_BUF
    # (typically 4096) means concurrent appends from parallel hooks don't
    # interleave. Our record is ~100 bytes — well under.
    printf '{"hook":"%s","ts":"%s","duration_ms":%d,"fired_emit":%s}\n' \
        "$hook" "$ts" "$duration_ms" "$fired_emit" \
        >> "$log_file" 2>/dev/null || true
}
