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
# Optional enrichment (csd-observability-stats): a hook may set TELEM_EXTRA
# to a pre-formatted JSON fragment of additional key:value pairs (no leading
# comma), e.g.:
#     TELEM_EXTRA='"counter":12,"ctx_bytes":744'
# The fragment is appended into the record verbatim AFTER a charset
# whitelist check (values are internally generated — validated ints, git
# short-SHAs — never user text; the whitelist is defense-in-depth so one
# bad value can't corrupt the JSONL). On any unexpected character the
# fragment is dropped and the base record still writes.
#
# Configuration:
#     CLAUDE_HOOK_LOG=1                — enable (default: disabled, no-op)
#     CLAUDE_HOOK_LOG_MAX_BYTES=N      — size cap (default: 10485760 = 10MB)
#
# Sources _tmpdir.sh, and is the SINGLE owner of that load — every hook that
# sources THIS file (8 of the 16; see _tmpdir.sh's header for the list and for
# what the other 8 must do) gets `harness_tmp` in scope and must not source it
# again (an earlier revision had four hooks doing so redundantly). It has to
# happen HERE at top level rather than lazily inside the size-cap branch that
# needs it: telem_end runs from an EXIT trap, which fires AFTER any cd the
# consuming hook performed, so a source resolved at that point would break for
# any invocation whose $0 is a relative path. Function-only helper — sourcing
# forks nothing, so the hooks' zero-subprocess fast paths are unaffected.
#
# Size cap: when the log file size ≥ MAX_BYTES, the hook refuses further
# writes for this session and emits a one-shot stderr warning (marker
# file pattern, same as focus-check counter-write-failure). Kill switch
# beyond cap is CLAUDE_HOOK_LOG=0.
#
# Portability: uses `date +%s%N` (GNU date / git-bash). On BSD date
# (macOS, FreeBSD) %N is literal — we detect this once and fall back
# to seconds × 1000 (sub-second precision lost but log shape preserved).

# $(dirname …), NOT ${BASH_SOURCE[0]%/*}: the latter strips nothing when the
# path carries no slash, so `cd hooks && source _telemetry.sh` would source
# "_telemetry.sh/_tmpdir.sh", fail, and leave harness_tmp UNDEFINED — after
# which telem_end's warn branch would touch "/.claude-hook-log-warned-$$" at
# the filesystem root. dirname always emits at least ".". The round-1 reviewer
# caught this shape in focus-check.sh; round 2 caught that the fix had
# relocated the fragile idiom here rather than replacing it. T-TD1 locks it.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_tmpdir.sh"

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

# Sanitize a session id for embedding in a TELEM_EXTRA fragment: sets
# SAFE_SID to $1 stripped to [A-Za-z0-9_-] — the subset of telem_end's
# whitelist (see below) that is also safe inside a quoted JSON string value.
# Sets a variable instead of printing so hot-path hooks pay no
# command-substitution fork. SINGLE definition point — this replaced six
# verbatim per-hook copies (2026-07-03); keep in lockstep with the telem_end
# whitelist, and note one drifted copy used to silently drop that hook's
# entire enrichment fragment. The --test block below proves the
# sanitizer-output-survives-the-whitelist contract against the real telem_end.
telem_safe_sid() {
    SAFE_SID="${1//[^A-Za-z0-9_-]/}"
}

# telemetry_capture <hook-name> <payload> <cwd> — opt-in raw-payload capture
# (spec §2.3). Called by each hook AFTER its own INPUT="$(cat)" read — NEVER
# a source-time stdin tee (that would consume stdin and no-op the hook).
# Best-effort: a full disk or unwritable .claude must never affect emission.
telemetry_capture() {
    [ "${CLAUDE_HOOK_CAPTURE:-0}" = "1" ] || return 0
    local hook="$1" payload="$2" cwd="${3:-$PWD}" dir ts
    dir="${cwd}/.claude/.hook-captures"
    [ -d "${cwd}/.claude" ] || return 0
    mkdir -p "$dir" 2>/dev/null || return 0
    # self-ignoring dir (house pattern, cf. focus-check.sh handoff sentinel):
    # CSD consumer repos get mechanical containment, not just a README note.
    printf '*\n' > "$dir/.gitignore" 2>/dev/null || true
    # Unique filename suffix: reuse _telem_now_ms's BSD-safe date probe
    # (review follow-up C5) instead of a bare `date +%s%N 2>/dev/null ||
    # date +%s`. On BSD/macOS date, `%N` is a LITERAL, unexpanded 'N' rather
    # than an error, so that idiom's `||` never fires and two captures from
    # the same hook in the same second silently overwrite each other.
    # _telem_now_ms already solves this correctly via the _TEL_NS_OK probe
    # above; guarded the same way telem_start guards it, so an unexpected
    # failure degrades to an empty (still-valid, just less unique) suffix
    # instead of aborting the capture.
    ts=$(_telem_now_ms 2>/dev/null) || ts=""
    printf '%s' "$payload" > "$dir/${hook}-${ts}.json" 2>/dev/null || true
    return 0
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
            harness_tmp
            warn_marker="${HARNESS_TMP:-${TMPDIR:-/tmp}}/.claude-hook-log-warned-$$"
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

    # Optional TELEM_EXTRA enrichment fragment (see header). Whitelist:
    # letters, digits, underscore, quote, colon, comma, dot, space, hyphen.
    # Must start with a quoted key. Anything else drops the fragment —
    # the base record is never at risk from a malformed enrichment.
    local extra="${TELEM_EXTRA:-}"
    if [ -n "$extra" ]; then
        case "$extra" in
            \"*) case "$extra" in
                     *[!A-Za-z0-9_:,.\"\ -]*) extra="" ;;
                 esac ;;
            *) extra="" ;;
        esac
    fi

    # Append JSONL line. POSIX small-write atomicity for lines under PIPE_BUF
    # (typically 4096) means concurrent appends from parallel hooks don't
    # interleave. Our record is ~100 bytes (~150 with enrichment) — well under.
    if [ -n "$extra" ]; then
        printf '{"hook":"%s","ts":"%s","duration_ms":%d,"fired_emit":%s,%s}\n' \
            "$hook" "$ts" "$duration_ms" "$fired_emit" "$extra" \
            >> "$log_file" 2>/dev/null || true
    else
        printf '{"hook":"%s","ts":"%s","duration_ms":%d,"fired_emit":%s}\n' \
            "$hook" "$ts" "$duration_ms" "$fired_emit" \
            >> "$log_file" 2>/dev/null || true
    fi
}

# Self-test (mirrors hooks/_python.sh): NEVER runs when sourced by a hook —
# only on direct exec with --test. Exit 0 iff all sub-checks pass.
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--test" ]; then
    _tt_pass=0
    _tt_fail=0
    _tt_ok()  { _tt_pass=$((_tt_pass + 1)); echo "  PASS: $1"; }
    _tt_bad() { _tt_fail=$((_tt_fail + 1)); echo "  FAIL: $1"; }

    echo "=== _telemetry.sh self-test ==="

    # T-TD1: this file is the SOLE owner of the _tmpdir.sh load for the whole
    # hook set — every consumer relies on harness_tmp being in scope purely as
    # a side effect of sourcing this one. A broken source here is silent (the
    # rest of the file still works; only telem_end's rare warn branch degrades,
    # writing its marker to the filesystem root), so assert the load actually
    # landed. Round 2 found exactly this failing under a slashless path.
    [ "$(type -t harness_tmp 2>/dev/null)" = "function" ] \
        && _tt_ok "T-TD1 sourcing this helper defines harness_tmp" \
        || _tt_bad "T-TD1 harness_tmp NOT defined — the _tmpdir.sh source failed silently"

    # T1: clean UUID-style sid passes through unchanged
    telem_safe_sid "7200a7e9-6a33-4133-94cf-9d4621482656"
    [ "$SAFE_SID" = "7200a7e9-6a33-4133-94cf-9d4621482656" ] \
        && _tt_ok "T1 clean sid unchanged" || _tt_bad "T1 clean sid unchanged"

    # T2: hostile chars (quotes, commas, colons, spaces, shell metachars,
    # backslash) are stripped — nothing that could escape a JSON string or
    # trip the fragment whitelist survives
    telem_safe_sid 'evil"sid, with:junk $(rm -rf /)\;'
    [ "$SAFE_SID" = "evilsidwithjunkrm-rf" ] \
        && _tt_ok "T2 hostile chars stripped" || _tt_bad "T2 hostile chars stripped (got: $SAFE_SID)"

    # T3: empty input stays empty (callers fall back to \"unknown\")
    telem_safe_sid ""
    [ -z "$SAFE_SID" ] && _tt_ok "T3 empty stays empty" || _tt_bad "T3 empty stays empty"

    # T4: CONTRACT — a fragment built from a sanitized hostile sid survives
    # the REAL telem_end whitelist (record written WITH the session field).
    # This is the lockstep canary: if the telem_end whitelist ever tightens
    # past [A-Za-z0-9_-] without this sanitizer following, T4 goes red.
    _tt_tmp=$(mktemp -d)
    mkdir -p "$_tt_tmp/.claude"
    (
        CLAUDE_HOOK_LOG=1
        telem_safe_sid 'sid"with,bad:chars and spaces'
        telem_start
        TELEM_EXTRA=$(printf '"session":"%s"' "$SAFE_SID")
        TELEM_EMIT=1
        telem_end telemetry-self-test.sh "$TELEM_EMIT" "$_tt_tmp"
    )
    grep -q '"session":"sidwithbadcharsandspaces"' "$_tt_tmp/.claude/.hook-log.jsonl" 2>/dev/null \
        && _tt_ok "T4 sanitized sid survives the real telem_end whitelist" \
        || _tt_bad "T4 sanitized sid survives the real telem_end whitelist"
    rm -rf "$_tt_tmp"

    # T5: capture disabled (default) → no file, no dir
    _tt_tmp=$(mktemp -d); mkdir -p "$_tt_tmp/.claude"
    telemetry_capture test-hook.sh '{"k":"v"}' "$_tt_tmp"
    [ ! -d "$_tt_tmp/.claude/.hook-captures" ] \
        && _tt_ok "T5 capture no-op when unset" || _tt_bad "T5 capture no-op when unset"
    rm -rf "$_tt_tmp"

    # T6: capture enabled → payload file written verbatim + self-ignoring .gitignore
    _tt_tmp=$(mktemp -d); mkdir -p "$_tt_tmp/.claude"
    ( CLAUDE_HOOK_CAPTURE=1 telemetry_capture test-hook.sh '{"k":"v"}' "$_tt_tmp" )
    _tt_cap=$(ls "$_tt_tmp/.claude/.hook-captures/"test-hook.sh-*.json 2>/dev/null | head -1)
    [ -n "$_tt_cap" ] && grep -q '"k":"v"' "$_tt_cap" \
        && grep -qx '\*' "$_tt_tmp/.claude/.hook-captures/.gitignore" 2>/dev/null \
        && _tt_ok "T6 capture writes payload + self-ignoring gitignore" \
        || _tt_bad "T6 capture writes payload + self-ignoring gitignore"
    rm -rf "$_tt_tmp"

    echo "_telemetry.sh self-test: $_tt_pass passed, $_tt_fail failed"
    [ "$_tt_fail" = "0" ] || exit 1
    exit 0
fi
