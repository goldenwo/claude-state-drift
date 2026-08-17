#!/usr/bin/env bash
# _tmpdir.sh — sourceable helper resolving the toolkit's OWN scoped temp
# directory, so per-session marker/counter litter never lands in the shared
# system temp root.
#
# Why: session-start-orient.sh used to sweep stale trackers with a
# `find "$TMPDIR" -maxdepth 1 ...` over the SHARED temp root. That scan is
# O(everything any program on the box ever put in /tmp) — measured at 4.196s
# on a dev machine whose /tmp held 88,527 entries (only 3,471 of them ours),
# blowing the hook's 2000ms perf budget by ~2.4x for work that deleted zero
# files. Confining our litter to a directory we own makes the sweep O(our
# own churn) instead. focus-check.sh already scopes its handoff-nudge
# sentinels this way (a project-local .claude/.handoff-nudge dir); this
# helper generalizes that to the temp-dir litter the other hooks produce.
#
# Layout mirrors bin/state-lock's existing split:
#   POSIX:   ${TMPDIR:-/tmp}/.claude-harness-<uid>   (mode 0700)
#   Windows: ${TMPDIR:-/tmp}/.claude-harness         (no uid — %TEMP% is
#            already per-user under the profile, same reasoning as
#            state-lock's lock_path_for win32 branch)
#
# Usage from a hook — do NOT source this directly. hooks/_telemetry.sh is the
# single owner of that load, so harness_tmp is in scope wherever telemetry is.
# That is 8 of the 16 hooks (the four helpers in this directory —
# _hooks_config.sh, _python.sh, _telemetry.sh and this file — are not hooks):
# decision-prompt-telemetry, focus-check, overnight-queue-guard,
# session-start-orient, session-start-yagni, snapshot-spec, state-staleness,
# state-track-commit. A hook OUTSIDE that set must source _telemetry.sh before
# calling harness_tmp; under the hooks' `set +e` an undefined harness_tmp is
# only a `command not found` on stderr, and execution continues with
# HARNESS_TMP unset. Hence the guarded expansion at every use site, which is
# load-bearing rather than style:
#     harness_tmp                      # always returns 0; sets HARNESS_TMP
#     marker="${HARNESS_TMP:-${TMPDIR:-/tmp}}/.claude-focus-check-${SESSION_ID}"
# Unguarded, that same line resolves to "/.claude-focus-check-<id>" — a write
# at the FILESYSTEM ROOT, which is the identical failure shape T-TD1 and
# _telemetry.sh's $(dirname) fix already exist to prevent. T-S12 in
# bin/focus-check-test pins the guarded form across every file that expands
# HARNESS_TMP: it scans ALL of hooks/*.sh and ALL of bin/* (not a hand-picked
# subset of either), plus the two dev-only test harnesses named below when
# testing an emitted cut that would not otherwise contain them — genuinely
# "every file", not an enumeration to keep in sync, so a future consumer
# (another hook, another harness, or an embedded-bash string inside a .py
# tool) is caught the first time it names the variable, with nothing to
# register. (Said "every use site" while scanning only hooks/*.sh, round 6 —
# both harnesses were in fact unguarded. Said "every file", round 7 — scanned
# a hand-picked bin/ subset that still missed bin/state-lock's embedded
# L8-probe bash string. Both were hand-enumerated lists; this one is not.)
# Test harnesses that need the path without running a hook DO source it
# directly (bin/focus-check-test, bin/e2e-smoke) — deriving the path by hand
# instead would miss the fallback below and silently aim their resets at a
# location the hooks are not using. They are in T-S12's scan for the same
# reason the hooks are: bin/e2e-smoke runs under `set +e` with no `set -u`,
# so an unset HARNESS_TMP there is silent, not fatal.
#
# Sets:
#   HARNESS_TMP — the scoped dir, or the shared temp root as a fallback.
# Returns:
#   Always 0. Callers must never have to branch: when the scoped dir can't
#   be created or isn't safely ours, HARNESS_TMP degrades to the shared root,
#   which is exactly where these files lived before this helper existed. The
#   worst case is therefore the OLD behavior, never a lost marker.

# _harness_tmp_dir_ok DIR — is DIR a directory we can safely confine our temp
# files to? Rejects: symlinks (following one would redirect every marker
# write), non-directories, anything not owned by us, and — on POSIX only —
# anything group- or other-writable.
#
# That last check is NOT belt-and-braces. An earlier revision omitted it,
# reasoning that these files already sat in a world-writable /tmp so any
# confinement could only improve matters. A reviewer disproved that
# empirically: /tmp is protected by the sticky bit AND fs.protected_symlinks,
# and BOTH key on sticky+world-writable, so neither extends into a non-sticky
# world-writable SUBdirectory. In that state a co-located user can plant a
# symlink at one of our marker paths and have us truncate the target —
# demonstrated end-to-end against a 600-mode file in the victim's home, while
# the identical attack aimed at /tmp itself is refused with EPERM. A
# world-writable scoped dir is therefore strictly WORSE than the root it
# replaced, and this check is what keeps it from being reachable. It also
# matches what bin/state-lock's _posix_lock_dir has always enforced.
#
# Costs one stat fork per call, POSIX only — where forks are cheap and the
# shared-root threat is real. Windows skips it: %TEMP% is per-user, there is
# no co-located attacker, and msys forks are the expensive ones.
_harness_tmp_dir_ok() {
    # -w/-x are not redundant with -O: a directory we OWN can still be
    # unusable (mode 500, a `u::rx` default ACL on the parent, a remounted
    # read-only temp fs). Accepting one would be strictly worse than the
    # fallback it is supposed to trigger — every marker write silently fails,
    # so focus-check's counter never persists and its re-anchor stops firing
    # forever, while the stamp write fails too and the full shared-root scan
    # returns on every session start. `mkdir -p` is a no-op on an existing
    # directory, so nothing downstream ever repairs it.
    [ ! -L "$1" ] && [ -d "$1" ] && [ -O "$1" ] && [ -w "$1" ] && [ -x "$1" ] || return 1
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) return 0 ;;
    esac
    local mode
    mode=$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)
    # Empty (stat unavailable or failed) fails CLOSED: degrade to the
    # documented fallback rather than trust a directory whose mode we could
    # not read.
    [ -n "$mode" ] || return 1
    # Reject group/other WRITABLE — the octal write bit (2) set in either of
    # the last two digits, i.e. 2,3,6,7. Deliberately narrower than
    # bin/state-lock's `st_mode & 0o077`, which refuses any group/other
    # access at all: that stricter rule is right for a lock whose integrity
    # is the point, but applying it here would reject an ordinary 0755
    # directory and silently drop the whole install back to the unscoped
    # shared root — trading a real, measured performance fix for protection
    # against reading counter files that carry no secrets. Write is what the
    # symlink-plant attack needs, so write is what this refuses.
    case "${mode: -2:1}" in 2|3|6|7) return 1 ;; esac
    case "${mode: -1}"   in 2|3|6|7) return 1 ;; esac
    return 0
}

harness_tmp() {
    HARNESS_TMP="${TMPDIR:-/tmp}"
    local dir
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) dir="${HARNESS_TMP}/.claude-harness" ;;
        *)                    dir="${HARNESS_TMP}/.claude-harness-${UID:-0}" ;;
    esac

    # -O rejects a directory at our path owned by somebody else. On msys it
    # reports true indiscriminately (verified: true for C:/Windows), so it is
    # a no-op there — correctly, since %TEMP% is per-user and there is no
    # shared-root threat, the same carve-out bin/state-lock documents for its
    # own win32 branch.
    if _harness_tmp_dir_ok "$dir"; then
        HARNESS_TMP="$dir"
        return 0
    fi

    # Something is already at that path that is not our own plain directory —
    # a symlink (possibly planted), a regular file, or another uid's dir.
    # Leave it strictly alone and keep the shared-root fallback. The -L arm
    # catches a DANGLING symlink, which -e would miss.
    if [ -e "$dir" ] || [ -L "$dir" ]; then
        return 0
    fi

    # First use. umask (not `mkdir -m 700`) because -m makes msys emit
    # "cannot change permissions" on stderr while still creating the dir.
    # The trailing `|| :` is required, not cosmetic: without it a failing
    # mkdir is an uncaught non-zero statement that kills any caller running
    # under `set -e` — turning the documented "always returns 0, never
    # branch" fallback into a dead hook, in exactly the degraded case the
    # fallback exists to handle. H3 covers this under `bash -e`.
    ( umask 077; mkdir -p "$dir" ) 2>/dev/null || :
    # Re-verified rather than assumed: a `umask 077` mkdir still yields a
    # world-writable dir when the parent carries a POSIX default ACL, which
    # is one of the ways the attack above becomes reachable.
    if _harness_tmp_dir_ok "$dir"; then
        HARNESS_TMP="$dir"
    fi
    return 0
}

# --- Self-test (mirrors the hooks/_python.sh --test precedent, and is
# registered in .github/workflows/test.yml's hook --test loop). --------------
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--test" ]; then
    _ht_pass=0
    _ht_fail=0
    _ht_skip=0
    _ht_ok()   { _ht_pass=$((_ht_pass + 1)); echo "  PASS: $1"; }
    _ht_bad()  { _ht_fail=$((_ht_fail + 1)); echo "  FAIL: $1"; }
    _ht_skipped() { _ht_skip=$((_ht_skip + 1)); echo "  SKIP: $1"; }

    echo "=== _tmpdir.sh self-test ==="

    _ht_root="$(mktemp -d)"
    trap 'rm -rf "$_ht_root" 2>/dev/null' EXIT

    # Expected basename, per the documented platform split.
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) _ht_expect=".claude-harness" ;;
        *)                    _ht_expect=".claude-harness-${UID:-0}" ;;
    esac

    # H1: a fresh temp root gets the scoped dir created, and HARNESS_TMP
    # points INSIDE it — not at the shared root itself.
    _ht_h1="$_ht_root/h1"; mkdir -p "$_ht_h1"
    if ( TMPDIR="$_ht_h1"; harness_tmp
         [ -d "$HARNESS_TMP" ] && [ "$HARNESS_TMP" != "$_ht_h1" ] \
         && [ "$HARNESS_TMP" = "$_ht_h1/$_ht_expect" ] ) 2>/dev/null; then
        _ht_ok "H1: scoped dir created under a fresh TMPDIR"
    else
        _ht_bad "H1: scoped dir not created (HARNESS_TMP should be \$TMPDIR/$_ht_expect)"
    fi

    # H2: resolution is idempotent — a second call against an ALREADY
    # existing dir yields the same path and leaves it in place. This is the
    # steady-state hot path (every focus-check fire re-resolves). The plain
    # mkdir below deliberately uses the ambient umask (0755 on a typical
    # box), so this doubles as the case that pins the mode check to
    # group/other-WRITABLE: a merely group-readable dir must still be
    # accepted, or the fix would silently disable itself on ordinary installs.
    # chmod, not the ambient umask: under umask 002 (the pam_umask default on
    # Debian/Ubuntu private-group installs) a plain mkdir yields 0775, which
    # the mode check correctly rejects — so this assertion would flip red for
    # a reason that has nothing to do with idempotence. State the mode.
    _ht_h2="$_ht_root/h2"; mkdir -p "$_ht_h2/$_ht_expect"; chmod 755 "$_ht_h2/$_ht_expect"
    if ( TMPDIR="$_ht_h2"; harness_tmp; _first="$HARNESS_TMP"
         harness_tmp
         [ "$HARNESS_TMP" = "$_first" ] && [ -d "$HARNESS_TMP" ] \
         && [ "$HARNESS_TMP" = "$_ht_h2/$_ht_expect" ] ) 2>/dev/null; then
        _ht_ok "H2: re-resolution reuses the existing dir (same path)"
    else
        _ht_bad "H2: re-resolution did not reuse the existing dir"
    fi

    # H3: creation failure degrades to the shared root instead of failing.
    # A regular FILE sitting at the scoped-dir path makes mkdir impossible.
    # The contract is "never worse than the old behavior", so HARNESS_TMP
    # must be the temp root and the function must still return 0.
    _ht_h3="$_ht_root/h3"; mkdir -p "$_ht_h3"; : > "$_ht_h3/$_ht_expect"
    if ( TMPDIR="$_ht_h3"; harness_tmp && [ "$HARNESS_TMP" = "$_ht_h3" ] ) 2>/dev/null; then
        _ht_ok "H3: uncreatable scoped dir falls back to the temp root (rc 0)"
    else
        _ht_bad "H3: no fallback when the scoped dir cannot be created"
    fi

    # H3b: the same fallback under `set -e`. Asserted separately because the
    # contract ("always returns 0; callers never branch") is worth nothing if
    # a failing mkdir aborts the caller instead — and H3 above cannot see
    # that, since this harness does not run with -e.
    #
    # TMPDIR must be a REGULAR FILE here, not H3's fixture. H3 puts a file at
    # the scoped path, so harness_tmp returns at the `[ -e "$dir" ]` early
    # exit and never reaches the mkdir this test exists to guard — an earlier
    # version of H3b did exactly that and still scored 8/8 with the `|| :`
    # stripped out. A file at TMPDIR makes the mkdir itself fail with ENOTDIR,
    # which is also root-proof (a chmod 555 parent is not: root's mkdir
    # succeeds and the assertion passes for the wrong reason).
    _ht_h3b="$_ht_root/h3b-file"; : > "$_ht_h3b"
    if bash -e -c '
        . "$1" || exit 3
        export TMPDIR="$2"
        harness_tmp
        [ "$HARNESS_TMP" = "$2" ] || exit 4
    ' _ "${BASH_SOURCE[0]}" "$_ht_h3b" 2>/dev/null; then
        _ht_ok "H3b: fallback does not abort a caller running under set -e"
    else
        _ht_bad "H3b: harness_tmp aborted its caller under set -e (contract says it always returns 0)"
    fi

    # H4: an unset TMPDIR resolves against /tmp, matching every existing
    # writer's `${TMPDIR:-/tmp}` idiom (they must not diverge, or the sweep
    # and the writers would disagree about where the litter lives).
    if ( unset TMPDIR; harness_tmp; case "$HARNESS_TMP" in /tmp*) exit 0 ;; *) exit 1 ;; esac ) 2>/dev/null; then
        _ht_ok "H4: unset TMPDIR resolves under /tmp"
    else
        _ht_bad "H4: unset TMPDIR did not resolve under /tmp"
    fi

    # H5 (POSIX-only): a symlink planted AT the scoped-dir path is refused —
    # following it would let a co-located user redirect our marker writes.
    # We fall back to the root rather than writing through the link. Windows
    # git-bash `ln -s` silently copies (#79), so a -L check there is a false
    # pass; SKIP unless a REAL symlink was created.
    _ht_h5="$_ht_root/h5"; mkdir -p "$_ht_h5" "$_ht_root/h5-target"
    if ln -s "$_ht_root/h5-target" "$_ht_h5/$_ht_expect" 2>/dev/null && [ -L "$_ht_h5/$_ht_expect" ]; then
        if ( TMPDIR="$_ht_h5"; harness_tmp && [ "$HARNESS_TMP" = "$_ht_h5" ] ) 2>/dev/null; then
            _ht_ok "H5: symlink at the scoped-dir path refused (falls back to root)"
        else
            _ht_bad "H5: symlinked scoped dir was followed instead of refused"
        fi
    else
        _ht_skipped "H5 (symlink refusal) — no real symlink available on this platform"
    fi

    # H6 (POSIX-only): the created dir is 0700. On Windows the mode is
    # meaningless (%TEMP% is already per-user) and `mkdir -m` errors noisily
    # on msys, so mode is only asserted where it means something.
    case "$(uname -s 2>/dev/null)" in
      Linux*|Darwin*)
        _ht_h6="$_ht_root/h6"; mkdir -p "$_ht_h6"
        _ht_mode=$( TMPDIR="$_ht_h6"; harness_tmp; ls -ld "$HARNESS_TMP" 2>/dev/null | cut -c1-10 )
        if [ "$_ht_mode" = "drwx------" ]; then
            _ht_ok "H6: scoped dir created at mode 0700"
        else
            _ht_bad "H6: scoped dir mode is '$_ht_mode', expected drwx------"
        fi
        ;;
      *) _ht_skipped "H6 (0700 mode) — POSIX-only" ;;
    esac

    # H7 (POSIX-only): a group/other-writable dir we own is REFUSED. Reaching
    # that state does not require an attacker — a POSIX default ACL on the
    # parent suppresses our umask, and some mount types force a mode — but
    # once reached, a co-located user can plant a symlink at any marker path
    # inside it and have us follow it. Neither the sticky bit nor
    # fs.protected_symlinks reaches into a non-sticky subdirectory, so this
    # check is the only thing standing between that state and a write
    # primitive. Windows has no co-located-user threat in per-user %TEMP%.
    case "$(uname -s 2>/dev/null)" in
      Linux*|Darwin*)
        _ht_h7="$_ht_root/h7"; mkdir -p "$_ht_h7"
        mkdir -m 777 "$_ht_h7/$_ht_expect" 2>/dev/null
        if ( TMPDIR="$_ht_h7"; harness_tmp && [ "$HARNESS_TMP" = "$_ht_h7" ] ) 2>/dev/null; then
            _ht_ok "H7: world-writable scoped dir refused (falls back to root)"
        else
            _ht_bad "H7: accepted a group/other-writable scoped dir — symlink-plant surface"
        fi
        ;;
      *) _ht_skipped "H7 (mode refusal) — POSIX-only" ;;
    esac

    # H7b (POSIX-only): the accept/reject boundary pinned from the other side.
    # H2 proves 0755 is accepted; this proves 0775 is not. Without both, a
    # future tightening to state-lock's `& 0o077` would silently disable the
    # scoping on every ordinary install and no test would notice.
    case "$(uname -s 2>/dev/null)" in
      Linux*|Darwin*)
        _ht_h7b="$_ht_root/h7b"; mkdir -p "$_ht_h7b/$_ht_expect"; chmod 775 "$_ht_h7b/$_ht_expect"
        if ( TMPDIR="$_ht_h7b"; harness_tmp && [ "$HARNESS_TMP" = "$_ht_h7b" ] ) 2>/dev/null; then
            _ht_ok "H7b: group-writable (0775) scoped dir refused"
        else
            _ht_bad "H7b: accepted a group-writable scoped dir"
        fi
        ;;
      *) _ht_skipped "H7b (group-writable refusal) — POSIX-only" ;;
    esac

    # H8 (POSIX-only): a dir we own but cannot WRITE to must fall back, not be
    # accepted. Accepting it silently drops every marker write — focus-check's
    # counter stops persisting, so its re-anchor never fires again — and the
    # stamp write fails too, putting the full shared-root scan back on every
    # session start. Explicit chmod so the fixture is umask-independent.
    case "$(uname -s 2>/dev/null)" in
      Linux*|Darwin*)
        if [ "${UID:-0}" = "0" ]; then
            _ht_skipped "H8 (unwritable dir refusal) — root bypasses mode bits"
        else
            _ht_h8="$_ht_root/h8"; mkdir -p "$_ht_h8/$_ht_expect"; chmod 500 "$_ht_h8/$_ht_expect"
            if ( TMPDIR="$_ht_h8"; harness_tmp && [ "$HARNESS_TMP" = "$_ht_h8" ] ) 2>/dev/null; then
                _ht_ok "H8: unwritable scoped dir refused (falls back to root)"
            else
                _ht_bad "H8: accepted a scoped dir we cannot write to — every marker would be lost"
            fi
            chmod 700 "$_ht_h8/$_ht_expect" 2>/dev/null
        fi
        ;;
      *) _ht_skipped "H8 (unwritable dir refusal) — POSIX-only" ;;
    esac

    echo "=== _tmpdir.sh self-test: $_ht_pass passed, $_ht_fail failed, $_ht_skip skipped ==="
    [ "$_ht_fail" -eq 0 ]
    exit $?
fi
