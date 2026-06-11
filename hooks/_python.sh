#!/usr/bin/env bash
# _python.sh — sourceable helper that finds a working Python interpreter.
#
# Round-3 reviewer C1 (Phase P): every hook that invokes Python has now
# encountered the Windows Microsoft Store stub problem. `python3` and
# `python` may both exist in PATH but route to a stub that errors on
# invocation. `py` (PEP-397 launcher) is the reliable fallback on Windows.
# Linux CI doesn't have `py` but typically has `python3`.
#
# Probes [python3, python, py] in order. Sanity-checks each by running
# `--version`. First working interpreter wins; sets PYTHON_BIN.
#
# Usage from a hook:
#     source "$(dirname "$0")/_python.sh"
#     ensure_python || exit 0   # silent skip if no working interpreter
#     "$PYTHON_BIN" -c "import json; ..."
#
# Sets:
#   PYTHON_BIN  — path/name of the first working interpreter
# Returns:
#   0 on success (PYTHON_BIN set); 1 if no working interpreter found.

ensure_python() {
    # Phase Q C-new-1 (round-4 reviewer): if PYTHON_BIN is already set
    # (either by a prior ensure_python call OR by an inherited env var),
    # VALIDATE it before trusting. The pre-existing value could be:
    #   - leftover from a sibling project's bash session (stale path)
    #   - hostile (attacker sets PYTHON_BIN=/tmp/poison-binary)
    #   - garbage (operator typo'd export)
    # All three caused state-staleness + snapshot-spec + session-start-orient
    # to silently no-op in round-4's empirical test. Sanity-check via
    # `command -v` AND `--version`; on failure, re-probe from scratch.
    if [ -n "${PYTHON_BIN:-}" ]; then
        if command -v "$PYTHON_BIN" >/dev/null 2>&1 && "$PYTHON_BIN" --version >/dev/null 2>&1; then
            return 0
        fi
        # Pre-existing value is invalid — unset and re-probe
        PYTHON_BIN=""
    fi
    local cand
    for cand in python3 python py; do
        if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then
            PYTHON_BIN="$cand"
            return 0
        fi
    done
    return 1
}

# --- Self-test (#80, R4 N5) -------------------------------------------------
# 10 hooks source this helper; a regression here silently no-ops all of
# them (round-4's empirical finding). `bash hooks/_python.sh --test`
# exercises the tricky validate/re-probe branches. The guard ensures this
# NEVER runs when the file is sourced by a hook — only on direct exec with
# the --test arg. Exit 0 iff all sub-checks pass.
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--test" ]; then
    _pt_pass=0
    _pt_fail=0
    _pt_ok()  { _pt_pass=$((_pt_pass + 1)); echo "  PASS: $1"; }
    _pt_bad() { _pt_fail=$((_pt_fail + 1)); echo "  FAIL: $1"; }

    echo "=== _python.sh self-test ==="

    # P1: clean probe finds a working interpreter and it actually runs.
    if ( unset PYTHON_BIN; ensure_python && [ -n "$PYTHON_BIN" ] \
         && "$PYTHON_BIN" --version >/dev/null 2>&1 ); then
        _pt_ok "P1: clean probe → working PYTHON_BIN"
    else
        _pt_bad "P1: clean probe failed to find a usable interpreter"
    fi

    # P2: empty PATH → no interpreter discoverable → return 1.
    if ( unset PYTHON_BIN; PATH=""; ensure_python ); then
        _pt_bad "P2: empty PATH should yield no interpreter (got success)"
    else
        _pt_ok "P2: empty PATH → ensure_python returns non-zero"
    fi

    # P3: garbage preset PYTHON_BIN (nonexistent path) is NOT trusted —
    # validation fails, re-probe replaces it with a real interpreter.
    if ( PYTHON_BIN="/no/such/python-xyz"; ensure_python \
         && [ "$PYTHON_BIN" != "/no/such/python-xyz" ] \
         && "$PYTHON_BIN" --version >/dev/null 2>&1 ); then
        _pt_ok "P3: garbage PYTHON_BIN re-probed to a real interpreter"
    else
        _pt_bad "P3: garbage PYTHON_BIN not re-probed (round-4 regression)"
    fi

    # P4: preset that EXISTS but isn't python (`false`: --version exits 1)
    # must also be rejected and re-probed, not trusted on existence alone.
    _pt_false="$(command -v false 2>/dev/null || echo /bin/false)"
    if ( PYTHON_BIN="$_pt_false"; ensure_python \
         && [ "$PYTHON_BIN" != "$_pt_false" ] \
         && "$PYTHON_BIN" --version >/dev/null 2>&1 ); then
        _pt_ok "P4: existing-but-not-python preset rejected + re-probed"
    else
        _pt_bad "P4: non-python preset trusted on existence alone"
    fi

    # P5 (POSIX-only): a symlink TO a real interpreter is a valid preset
    # (command -v + --version succeed through the link). Windows git-bash
    # `ln -s` isn't a real symlink (#79) → SKIP there.
    case "$(uname -s 2>/dev/null)" in
      Linux*|Darwin*)
        ( unset PYTHON_BIN; ensure_python ) >/dev/null 2>&1
        _pt_real="$(unset PYTHON_BIN; ensure_python && command -v "$PYTHON_BIN")"
        _pt_link="$(mktemp -u 2>/dev/null)/py-link"
        mkdir -p "$(dirname "$_pt_link")" 2>/dev/null
        if [ -n "$_pt_real" ] && ln -s "$_pt_real" "$_pt_link" 2>/dev/null; then
            if ( PYTHON_BIN="$_pt_link"; ensure_python \
                 && [ "$PYTHON_BIN" = "$_pt_link" ] \
                 && "$PYTHON_BIN" --version >/dev/null 2>&1 ); then
                _pt_ok "P5: symlinked interpreter accepted as valid preset"
            else
                _pt_bad "P5: valid symlinked interpreter wrongly rejected"
            fi
            rm -f "$_pt_link" 2>/dev/null
        else
            _pt_bad "P5: could not set up symlink fixture"
        fi
        ;;
      *) echo "  SKIP: P5 (symlinked interpreter) — POSIX-only" ;;
    esac

    echo "=== _python.sh self-test: $_pt_pass passed, $_pt_fail failed ==="
    [ "$_pt_fail" -eq 0 ]
    exit $?
fi
