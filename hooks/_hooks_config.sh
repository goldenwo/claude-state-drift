#!/usr/bin/env bash
# _hooks_config.sh — sourceable helper that reads ONE typed knob from the
# `hooks-config.json` layers (ROADMAP #28's unified override file):
# project `.claude/hooks-config.json` first, then the user-level
# ${CLAUDE_CONFIG_DIR:-~/.claude}/hooks-config.json (2026-08-17), folding
# the four-hook config-read idiom into two functions.
#
# DRY mini-wave (v0.3.4-dev): the idiom
#     [ -f .claude/hooks-config.json ]  →  lazy source _python.sh  →
#     ensure_python  →  "$PYTHON_BIN" bin/read-hooks-config CFG KEY  →  rc-check
# had crossed into a 4th hook (focus-check.sh, state-track-commit.sh,
# lint-after-write.sh, stop-runs-tests.sh). It lives here once.
#
# Top level is FUNCTION DEFINITIONS ONLY (plus the guarded --test block),
# so `source`-ing this file never forks a subprocess — it stays cheap on
# the UserPromptSubmit / PostToolUse(Bash) hot paths. The load-bearing
# perf invariant is the stat-first guard below: a caller with NEITHER a
# project nor a user-level hooks-config.json pays exactly two `[ -f ]`
# stats — no _python.sh source, no interpreter probe, no reader spawn.
#
# Usage from a hook:
#     source "$(dirname "$0")/_hooks_config.sh"
#     # int knob (folds the ''|*[!0-9]*|0 guard; echoes a validated int ≥ 1):
#     if v=$(_read_hook_config_int "$cfg" lint_timeout_seconds); then t="$v"; fi
#     # string knob (echoes the non-empty raw value; caller post-processes):
#     if s=$(_read_hook_config_str "$cfg" state_track_pattern); then …; fi
#
# Path resolution GOTCHA: inside a *sourced* file `$0` is the CALLER, not
# this helper. _python.sh and ../bin/read-hooks-config are resolved relative
# to ${BASH_SOURCE[0]} (this file), absolutized ONCE at source time into
# $_HC_DIR (see below) so the functions work from any caller dir and from a
# caller function context (lint/stop call them inside resolve_*_timeout). A
# caller `cd` before the call (e.g. state-track-commit.sh cds at L110, well
# before it sources+calls us at L204-205) is harmless: $_HC_DIR is absolute.
# Covered by --test P3.
#
# Returns (both functions):
#   0  printed the validated value for KEY on stdout (use it)
#   non-zero  no usable value — absent file / no python / reader failure /
#             empty / (int only) non-int or < 1 — NOTHING printed; the
#             caller keeps its built-in default. Mirrors read-hooks-config's
#             silent-default contract: no crash, no stderr on the hot path.

# Resolve THIS helper's own directory ONCE, at source time, fork-free.
# Path GOTCHA: in a sourced file `$0` is the CALLER, so siblings must be
# found relative to ${BASH_SOURCE[0]} (this file). We absolutize it HERE, at
# source time, so a *relative* ${BASH_SOURCE[0]} can never be re-resolved
# against the wrong cwd if a caller `cd`s before invoking us. A relative
# BASH_SOURCE arises ONLY from a direct `bash _hooks_config.sh --test` (the
# self-test) run from the repo: there $PWD at source time is the dir the
# relative path is anchored to, so pinning it now (the `*/*` / bare-name
# branches) is correct before any later cwd change. A real hook fire sources
# us via `$(dirname "$0")/_hooks_config.sh` with an absolute $0, so
# BASH_SOURCE[0] is already absolute, the `/*` branch fires, and $PWD is
# never consulted — a caller `cd` (e.g. state-track-commit.sh at L110, before
# it sources+calls us at L204-205) is therefore irrelevant to $_HC_DIR. Both
# branches are pure parameter expansion — NO subshell, so a plain `source`
# of this file still never forks (the hot-path invariant).
case "${BASH_SOURCE[0]}" in
    /*) _HC_DIR="${BASH_SOURCE[0]%/*}" ;;          # already absolute
    */*) _HC_DIR="${PWD}/${BASH_SOURCE[0]%/*}" ;;   # relative with a dir part
    *)  _HC_DIR="${PWD}" ;;                         # bare filename (cwd)
esac

# Single-file read: stat-first → lazy python → reader. Echoes the raw
# reader value and returns its rc; prints nothing / non-zero on
# absent-file / no-python / reader-failure.
_hc_read_file() {
    local cfg="$1" key="$2"
    # 1. Stat first — the load-bearing perf invariant. A no-config caller
    #    pays only this stat (no _python.sh source, no python spawn).
    [ -f "$cfg" ] || return 1
    # 2. Lazy-source _python.sh, but only if the caller hasn't already
    #    (lint/stop source it at file top for the lint/test exec). $_HC_DIR
    #    was resolved absolute at source time (above), so it survives any
    #    caller `cd` (state-track-commit.sh).
    if ! command -v ensure_python >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        source "$_HC_DIR/_python.sh"
    fi
    # 3. Need a working interpreter; absent one → caller default.
    ensure_python || return 1
    # 4. Single-key read via the #75 O_NOFOLLOW reader. rc 0 → $v is the
    #    reader-validated value for the key.
    local v
    v=$("$PYTHON_BIN" "$_HC_DIR/../bin/read-hooks-config" "$cfg" "$key" 2>/dev/null) || return 1
    printf '%s\n' "$v"
}

# Shared plumbing with the two-layer resolution (2026-08-17): per KEY, the
# project file the caller passed is tried first; when it yields no usable
# value (absent file, absent key, wrong type, malformed JSON, no python),
# the USER-LEVEL file ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks-config.json
# is tried — plugin-owned machine-wide defaults without hand-editing
# ~/.claude/settings.json env blocks. Precedence per knob is therefore
# env (in the callers) > project file > user file > built-in default.
# Perf invariant, restated for two layers: a caller whose project has
# NEITHER file pays exactly two [ -f ] stats — no _python.sh source, no
# interpreter probe, no reader spawn. The user path is resolved from the
# environment at call time (pure parameter expansion, fork-free), which is
# also what lets test suites isolate it via CLAUDE_CONFIG_DIR.
# The two public functions add type-specific validation on top.
_hc_read_raw() {
    local cfg="$1" key="$2" v ucfg
    if v=$(_hc_read_file "$cfg" "$key"); then
        printf '%s\n' "$v"
        return 0
    fi
    ucfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks-config.json"
    # Same path both layers (a project rooted at $HOME hands us the user
    # file as its "project" file) → nothing new to read.
    [ "$ucfg" = "$cfg" ] && return 1
    v=$(_hc_read_file "$ucfg" "$key") || return 1
    printf '%s\n' "$v"
}

# _read_hook_config_int CFG KEY → on success echoes a validated integer ≥ 1
# and returns 0; on absent-file / no-python / reader-failure / empty /
# non-int / 0 returns non-zero and echoes nothing. Folds in the
# ''|*[!0-9]*|0 numeric guard the int callers (lint, stop, focus-check
# focus_check_every) each duplicated as defense-in-depth atop the reader's
# own validation.
_read_hook_config_int() {
    local v
    v=$(_hc_read_raw "$1" "$2") || return 1
    case "$v" in
        ''|*[!0-9]*|0) return 1 ;;   # empty / non-int / zero → caller default
        *) printf '%s\n' "$v" ;;
    esac
}

# _read_hook_config_str CFG KEY → on success echoes the non-empty raw value
# and returns 0; else returns non-zero (echoes nothing). The reader already
# rejects empty / control-char strings, but we re-check non-empty here so a
# caller can rely on a non-empty stdout. Any DOMAIN post-processing stays in
# the caller: state-track's regex-safety block on state_track_pattern, or
# focus-check's `[ "$x" = "1" ]` on focus_check_disable.
_read_hook_config_str() {
    local v
    v=$(_hc_read_raw "$1" "$2") || return 1
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

# --- Self-test (DRY mini-wave) ----------------------------------------------
# Mirrors _python.sh's --test guard: runs ONLY on direct exec with --test,
# never when sourced by a hook. The primary behavioral coverage lives in the
# existing suites (lint/stop --test T20-T23, focus-check-test §7/§14); this
# pins the helper's own contract, esp. the BASH_SOURCE path-resolution
# invariant (P3) — the one gotcha that would silently break lint/stop, which
# call these functions from inside a resolver FUNCTION. Exit 0 iff all pass.
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--test" ]; then
    _hct_pass=0
    _hct_fail=0
    _hct_ok()  { _hct_pass=$((_hct_pass + 1)); echo "  PASS: $1"; }
    _hct_bad() { _hct_fail=$((_hct_fail + 1)); echo "  FAIL: $1"; }

    echo "=== _hooks_config.sh self-test ==="

    _hct_tmp="$(mktemp -d)"
    trap 'rm -rf "$_hct_tmp"' EXIT
    _hct_cfg="$_hct_tmp/hooks-config.json"
    # Two-layer isolation (user-level fallback, 2026-08-17): point the
    # user-layer resolution at a dir inside the fixture tree so a REAL
    # ~/.claude/hooks-config.json on the dev machine can never leak into
    # P1-P6 (which assume no user layer) and P7+ can plant one
    # deterministically. _hc_read_raw resolves the path from the
    # environment at call time, so a plain assignment suffices.
    CLAUDE_CONFIG_DIR="$_hct_tmp/user-claude"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    _hct_ucfg="$CLAUDE_CONFIG_DIR/hooks-config.json"

    # P1: NEITHER layer present → both functions return non-zero, print
    # nothing, and (the perf invariant) do NOT source _python.sh: the
    # no-config caller pays only the two [ -f ] stats. Run in a subshell
    # with PYTHON_BIN/ensure_python unset so we can assert no python probe.
    if ( unset PYTHON_BIN
         out=$(_read_hook_config_int "$_hct_cfg" lint_timeout_seconds)
         rc=$?
         [ $rc -ne 0 ] && [ -z "$out" ] \
           && ! command -v ensure_python >/dev/null 2>&1 ); then
        _hct_ok "P1: absent config → non-zero, empty, no _python.sh source"
    else
        _hct_bad "P1: absent config leaked a value or sourced python"
    fi

    # P2: valid int knob → echoed verbatim, rc 0.
    printf '%s' '{"lint_timeout_seconds":42}' > "$_hct_cfg"
    if out=$(_read_hook_config_int "$_hct_cfg" lint_timeout_seconds) \
       && [ "$out" = "42" ]; then
        _hct_ok "P2: valid int knob echoed (42)"
    else
        _hct_bad "P2: valid int knob not echoed (got '${out:-}')"
    fi

    # P3: BASH_SOURCE path resolution works from a CALLER FUNCTION whose
    # $0/cwd differ from this helper's dir — the spec's headline gotcha.
    # lint/stop hit this (resolve_*_timeout calls us). A wrapper fn + a cd
    # into an unrelated dir proves we don't resolve relative to $0/PWD.
    _hct_caller() { _read_hook_config_int "$1" lint_timeout_seconds; }
    if out=$( cd "$_hct_tmp" && _hct_caller "$_hct_cfg" ) \
       && [ "$out" = "42" ]; then
        _hct_ok "P3: resolves via BASH_SOURCE from a caller fn + foreign cwd"
    else
        _hct_bad "P3: BASH_SOURCE resolution broke from caller fn (got '${out:-}')"
    fi

    # P4: int guard rejects a zero / non-int (reader pre-validates, but the
    # folded guard is defense-in-depth — assert it bites on a raw 0 value).
    printf '%s' '{"lint_timeout_seconds":0}' > "$_hct_cfg"
    if out=$(_read_hook_config_int "$_hct_cfg" lint_timeout_seconds); then
        _hct_bad "P4: int knob value 0 wrongly accepted (got '$out')"
    else
        _hct_ok "P4: int knob value 0 rejected → caller default"
    fi

    # P5: string knob → non-empty raw value echoed verbatim, rc 0.
    printf '%s' '{"state_track_pattern":"epic|launch"}' > "$_hct_cfg"
    if out=$(_read_hook_config_str "$_hct_cfg" state_track_pattern) \
       && [ "$out" = "epic|launch" ]; then
        _hct_ok "P5: string knob echoed verbatim (epic|launch)"
    else
        _hct_bad "P5: string knob not echoed verbatim (got '${out:-}')"
    fi

    # P6: absent KEY in a present file → non-zero, empty (caller default).
    printf '%s' '{"lint_timeout_seconds":42}' > "$_hct_cfg"
    if out=$(_read_hook_config_str "$_hct_cfg" state_track_pattern); then
        _hct_bad "P6: absent key wrongly returned a value (got '$out')"
    else
        _hct_ok "P6: absent key → non-zero, caller default"
    fi

    # ─── User-level fallback layer (2026-08-17) ─────────────────────────────
    # Per-key precedence: project .claude/hooks-config.json > user-level
    # ${CLAUDE_CONFIG_DIR:-~/.claude}/hooks-config.json > caller default.
    # (Env vars sit above both, but that layer lives in the CALLERS.)

    # P7: no project file → a key resolves from the USER-LEVEL file.
    rm -f "$_hct_cfg"
    printf '%s' '{"lint_timeout_seconds":31}' > "$_hct_ucfg"
    if out=$(_read_hook_config_int "$_hct_cfg" lint_timeout_seconds) \
       && [ "$out" = "31" ]; then
        _hct_ok "P7: user-level file supplies the knob (31)"
    else
        _hct_bad "P7: user-level fallback missing (got '${out:-}')"
    fi

    # P8: both layers define the key → PROJECT wins.
    printf '%s' '{"lint_timeout_seconds":42}' > "$_hct_cfg"
    if out=$(_read_hook_config_int "$_hct_cfg" lint_timeout_seconds) \
       && [ "$out" = "42" ]; then
        _hct_ok "P8: project value shadows user value (42 over 31)"
    else
        _hct_bad "P8: project did not shadow user (got '${out:-}')"
    fi

    # P9: per-KEY merge, not per-file shadowing — a project file that
    # exists but LACKS the key still falls through to the user layer for
    # that key, while the keys it does define stay project-sourced.
    printf '%s' '{"focus_check_every":2}' > "$_hct_cfg"
    if out=$(_read_hook_config_int "$_hct_cfg" lint_timeout_seconds) \
       && [ "$out" = "31" ]; then
        _hct_ok "P9: key absent from project file falls to user layer (31)"
    else
        _hct_bad "P9: per-key merge broken (got '${out:-}')"
    fi
    if out=$(_read_hook_config_int "$_hct_cfg" focus_check_every) \
       && [ "$out" = "2" ]; then
        _hct_ok "P9b: key present in project file stays project-sourced (2)"
    else
        _hct_bad "P9b: project-present key misresolved (got '${out:-}')"
    fi

    # P10: a project `false` SHADOWS a user `true` for a bool knob (the
    # re-enable-locally case): rc 0 with "0", never the user's "1". A
    # wrong user-wins or first-truthy merge would flip this.
    printf '%s' '{"focus_check_disable":false}' > "$_hct_cfg"
    printf '%s' '{"focus_check_disable":true}' > "$_hct_ucfg"
    if out=$(_read_hook_config_str "$_hct_cfg" focus_check_disable) \
       && [ "$out" = "0" ]; then
        _hct_ok "P10: project false shadows user true (\"0\")"
    else
        _hct_bad "P10: bool shadowing broken (got '${out:-}')"
    fi

    # P11: the handoff-nudge knobs are in the reader schema with the right
    # types (int/int/bool), resolvable from the user layer — the knob
    # family this fallback exists for (plugin-owned config instead of env
    # in ~/.claude/settings.json).
    rm -f "$_hct_cfg"
    printf '%s' '{"handoff_nudge_tokens":150000,"handoff_nudge_pct":80,"handoff_nudge_disable":true}' > "$_hct_ucfg"
    if out=$(_read_hook_config_int "$_hct_cfg" handoff_nudge_tokens) \
       && [ "$out" = "150000" ]; then
        _hct_ok "P11: handoff_nudge_tokens int knob (150000)"
    else
        _hct_bad "P11: handoff_nudge_tokens not readable (got '${out:-}')"
    fi
    if out=$(_read_hook_config_int "$_hct_cfg" handoff_nudge_pct) \
       && [ "$out" = "80" ]; then
        _hct_ok "P11b: handoff_nudge_pct int knob (80)"
    else
        _hct_bad "P11b: handoff_nudge_pct not readable (got '${out:-}')"
    fi
    if out=$(_read_hook_config_str "$_hct_cfg" handoff_nudge_disable) \
       && [ "$out" = "1" ]; then
        _hct_ok "P11c: handoff_nudge_disable bool knob (\"1\")"
    else
        _hct_bad "P11c: handoff_nudge_disable not readable (got '${out:-}')"
    fi

    echo "=== _hooks_config.sh self-test: $_hct_pass passed, $_hct_fail failed ==="
    [ "$_hct_fail" -eq 0 ]
    exit $?
fi
