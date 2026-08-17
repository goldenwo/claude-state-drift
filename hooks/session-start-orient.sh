#!/usr/bin/env bash
# session-start-orient.sh — SessionStart plugin hook that auto-runs
# `where-am-i` for the current project and injects the orientation block
# into the new session's context via additionalContext.
#
# Silent-skip if .claude/state.json doesn't exist (no enforcement —
# uninstrumented projects pay nothing). Caveat: the stale-tracker sweep below
# runs BEFORE that gate, because the litter it reclaims is machine-wide, not
# per-project. It is therefore the one part of this hook an uninstrumented
# project does pay for, and since the scoped-tmpdir change it leaves state
# behind (the scoped dir and its legacy-sweep stamp) rather than only reading.
# Both are ~0 bytes and shared by every project on the box.
#
# Per Claude Code hooks reference: SessionStart fires once per session;
# input JSON includes `cwd`. Output JSON shape for additionalContext:
#   {"hookSpecificOutput": {"hookEventName": "SessionStart",
#                           "additionalContext": "..."}}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

# Observability telemetry (csd-observability-stats): instrument the
# orientation hook so accumulated logs capture the DOMINANT per-session
# context cost — the orientation block itself — which was previously
# uninstrumented (only focus-check / state-track / staleness emitted
# telemetry). Sourced before the early-exit checks so the silent-skip fast
# path is measured too; a no-op unless CLAUDE_HOOK_LOG=1. TELEM_EMIT flips
# to 1 only when the block is actually injected. The trap reads PROJECT_DIR
# at exit time (set below); for the rare pre-resolution exit it falls back
# to the env cwd, matching where telemetry would be written anyway.
# shellcheck disable=SC1091
source "$(dirname "$0")/_telemetry.sh"
telem_start
trap 'telem_end session-start-orient.sh "${TELEM_EMIT:-0}" "${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"' EXIT

if ! command -v jq >/dev/null 2>&1; then
    # Fail-open: missing jq shouldn't bork session start
    exit 0
fi

# Phase P C1 (round-3 reviewer): probe [python3, python, py] via shared
# _python.sh helper. The earlier `command -v python` check accepted the
# Windows Microsoft Store stub (which fails at invocation), silently
# breaking session-start orientation on this machine.
# shellcheck disable=SC1091
source "$(dirname "$0")/_python.sh"
ensure_python || exit 0

HOOK_INPUT="$(cat)"
PROJECT_DIR=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')
[[ -n "$PROJECT_DIR" ]] || PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // .sessionId // ""' 2>/dev/null)

# Periodic cleanup of stale tracker files (>7 days old) so they don't
# accumulate forever. Three passes, ordered by cost.
#
# This used to be a single `find "$TMPDIR" -maxdepth 1 ...` over the SHARED
# system temp root, on every session start. That is O(everything any program
# on the box ever left there): measured at 4.196s across an 88,527-entry temp
# dir on a dev machine — where only 3,471 files were ours and the scan
# deleted nothing — which blew this hook's 2000ms budget by ~2.4x. The
# writers now confine their litter to a directory we own (hooks/_tmpdir.sh),
# so the everyday sweep is bounded by OUR churn instead of the box's.
# harness_tmp arrives via _telemetry.sh (sourced at line 34), which loads
# _tmpdir.sh for its own warn-marker path — one owner, no duplicate source.
harness_tmp
# Read once through the guarded form. harness_tmp is defined only for the 8
# hooks that source _telemetry.sh (see _tmpdir.sh's header), and a bare
# "$HARNESS_TMP" here would aim `find -delete` at the FILESYSTEM ROOT if this
# hook ever stopped sourcing it. T-S12 pins the form across all of hooks/.
HTMP="${HARNESS_TMP:-${TMPDIR:-/tmp}}"

# Pass 1 — our own scoped dir. Everything this plugin writes to temp lands
# here: focus-check counters + warn markers, state-track nudges,
# state-staleness session markers + parsefail warns, the paired _guard_skip
# cwd-guard markers, hook-log warn markers, and (Windows) state-lock's lock
# files. That list is the invariant this pass depends on — a new hook temp
# writer that skips harness_tmp is invisible to it. Scope note: this covers
# the FILES the hooks write, not temp directories that bin/ dev tooling
# creates (perf-bench, publish-public-plugin, regen-drift-gate and
# version-bump all mkdtemp their own trees). Those must self-clean via
# bin/_fsutil.py — `find -delete` cannot remove a non-empty tree, so widening
# a glob here would not help them.
# A blanket `.claude-*` glob is safe
# HERE, and only here, precisely because nothing else writes to this
# directory — which is also why the per-name glob list below is still
# required for the shared root. Skipped when _tmpdir.sh fell back to the
# root, where that broad glob could match another tool's files.
# -mindepth 1 is load-bearing, not decoration: `find DIR -maxdepth 1 -name X`
# tests DIR ITSELF at depth 0, and DIR *is* `.claude-harness[-uid]`, which
# matches `.claude-*`. Without it, a scoped dir whose own mtime and whose every
# child had aged past 7 days was rmdir'd by the sweep that had just resolved it
# — and the stamp write below then failed into the missing directory, so the
# expensive shared-root scan ran anyway, on exactly the fire the stamp exists
# to protect. Found by the round-1 correctness reviewer; locked by T-S10.
if [ "$HTMP" != "${TMPDIR:-/tmp}" ]; then
    find "$HTMP" -mindepth 1 -maxdepth 1 -name '.claude-*' -mtime +7 -delete 2>/dev/null || true
fi

# Pass 2 — POSIX state-lock's per-uid 0700 dirs (Phase O #74), which live one
# level deeper than a maxdepth-1 root sweep can reach. Unchanged: that dir is
# hardened security code, already scoped, and already cheap. The 0700 dir
# itself is kept (reused, ~0 bytes). The unquoted glob degrades to a literal
# when no such dir exists; find then errors harmlessly into the 2>/dev/null.
find "${TMPDIR:-/tmp}"/.claude-state-locks-* -maxdepth 1 \
    -name '.claude-state-lock-*' -mtime +7 -delete 2>/dev/null || true

# Pass 3 — the legacy shared-root sweep. Trackers written by toolkit versions
# from before the scoped dir existed still sit at the root, so dropping this
# outright would orphan them on every installed machine. It therefore
# survives, but rate-limited behind a stamp instead of running on every
# session start — the scan itself is the cost described above. "Weekly" here
# is `-mtime +7`, i.e. once the stamp is strictly MORE than 7×24h old, so the
# real cadence is every 8 days; the same +7 sets the deletion age. Called
# weekly throughout for readability, not because it is exactly 7 days.
#
# The name list must cover every writer of the pre-scoped era, and this list
# has been wrong twice. Phase R #7 caught `.claude-state-lock-*` missing while
# a comment claimed the sweep covered it (Phase Q had reverted
# unlink-on-release per round-4 C-new-3), so the claim was false for a full
# phase. The round-1 correctness reviewer then caught `.claude-guardskip-*`
# missing — _guard_skip's cwd-guard marker, which the #78 comment in
# state-track-commit.sh says tripped on every real Windows fire for ~10 weeks,
# so it was accumulating unbounded and matched by nothing. Both are listed now.
legacy_root_sweep() {
    find "${TMPDIR:-/tmp}" -maxdepth 1 \
        \( -name '.claude-focus-check-*' \
           -o -name '.claude-state-track-*' \
           -o -name '.claude-state-staleness-*' \
           -o -name '.claude-state-lock-*' \
           -o -name '.claude-guardskip-*' \
           -o -name '.claude-hook-log-warned-*' \) \
        -mtime +7 -delete 2>/dev/null || true
}

LEGACY_STAMP=""
if [ "$HTMP" != "${TMPDIR:-/tmp}" ]; then
    # Stamp has no `.claude-` prefix on purpose — pass 1's blanket glob runs
    # over this same directory and must not be able to delete it.
    LEGACY_STAMP="${HTMP}/legacy-sweep-stamp"
elif [ -n "${CLAUDE_CONFIG_DIR:-}" ] || [ -n "${HOME:-}" ]; then
    # Degraded: no scoped dir. Keep the rate limit anyway, but put the stamp
    # somewhere the cause of the degradation cannot reach. On a shared POSIX
    # box the usual cause IS hostile — one `mkdir .claude-harness-<victim-uid>`
    # by a co-located user makes us fall back permanently (sticky /tmp means
    # the victim cannot even remove it), and a stamp kept in that same root
    # would then be suppressible, handing the attacker the every-fire
    # shared-root scan this whole change exists to eliminate. Under the config
    # dir they get the loss of confinement but not the O(shared temp) rescan.
    # The `elif` guard above matters: with both unset this would otherwise
    # aim the write at /.claude/ at the filesystem root. Named consequence,
    # so it is a decision rather than an oversight: with BOTH unset AND the
    # scoped dir unavailable, LEGACY_STAMP stays empty and the pass-3 block
    # below is skipped entirely — pass 1 is already skipped under fallback,
    # so the legacy sweep goes from "every session" to "never". That is the
    # one place this section is not "never worse than the old behavior", and
    # it is accepted deliberately: the alternative is a write at `/`, the
    # affected files are >7-day-old pre-scoped-era trackers, and an
    # environment with no HOME and no CLAUDE_CONFIG_DIR is not one where a
    # best-effort housekeeping sweep is the priority.
    LEGACY_STAMP="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.legacy-sweep-stamp"
    # Nothing guarantees the config dir exists (fresh box, or a
    # CLAUDE_CONFIG_DIR pointing somewhere not yet created). Without this the
    # stamp write fails every time and the sweep below runs on EVERY session
    # start — silently reinstating the exact cost this change removes.
    mkdir -p "${LEGACY_STAMP%/*}" 2>/dev/null || :
fi

if [ -n "$LEGACY_STAMP" ]; then
    # Never follow a symlink at the stamp path: `: >` below opens
    # O_CREAT|O_TRUNC, so anyone able to write into the stamp's directory
    # could aim it at a file of ours and have this hook truncate it. Unlink
    # first, and do it BEFORE the -f test, which would itself follow the link.
    [ -L "$LEGACY_STAMP" ] && rm -f "$LEGACY_STAMP" 2>/dev/null
    if [ ! -f "$LEGACY_STAMP" ] || [ -n "$(find "$LEGACY_STAMP" -mtime +7 -print 2>/dev/null)" ]; then
        # Sweep ONLY if the stamp actually persisted. If it cannot be written
        # (read-only config dir, unwritable scoped dir) an unconditional sweep
        # would run the full shared-root scan on every single session start,
        # forever, with nothing to record that it had. Skipping a best-effort
        # >7-day cleanup of pre-scoped-era litter is strictly the lesser harm:
        # pass 1 still reclaims everything this version writes.
        if : > "$LEGACY_STAMP" 2>/dev/null; then
            legacy_root_sweep
        fi
    fi
fi

# --- fleet-steward dead-man/aborted stat (fleet-steward P2 Task 12,
# design spec §7/§8) --------------------------------------------------------
# BEFORE the state.json early-exit below, deliberately: the steward's
# store is fleet-global (one nightly audit covers every repo on the
# machine), so an UNINSTRUMENTED project still needs to see a dead-man/
# aborted warning -- see part (c) just below the early-exit.
#
# Store resolution: a machine-global POINTER FILE at
# ~/.claude/steward-home (one line, the absolute steward-home dir --
# written by `bin/fleet-steward` at run-start and by `steward
# init-canary`), never CLAUDE_PLUGIN_ROOT (round-4 rationale: that only
# equals the real clone for a source:directory install). No pointer file
# -> STEWARD_HOME_DIR stays unset -> every block below this point that
# tests it is skipped -> ZERO further cost, BYTE-IDENTICAL output to a
# pre-steward build (public-cut contract: this hook ships in the [SHIP]
# allowlist, so a steward-home-absent read must be a silent no-op for
# every consumer who never installs the steward).
#
# STEWARD_POINTER_PATH is a TEST SEAM ONLY (matched on the Python writer
# side by bin/_steward.py's identically-named env var read) -- it
# relocates WHERE THE POINTER FILE ITSELF LIVES for an isolated test
# fixture; production always resolves $HOME/.claude/steward-home and
# this seam bypasses no gate, it only lets a test point both the writer
# and this reader at the same temp file instead of a real machine path.
STEWARD_POINTER="${STEWARD_POINTER_PATH:-$HOME/.claude/steward-home}"
DEADMAN_LINE=""
ABORTED_LINE=""
if [ -f "$STEWARD_POINTER" ]; then
    # Read defensively: first line only, and it must resolve to an
    # EXISTING directory -- a stale/hand-edited/corrupted pointer is
    # treated exactly like "no pointer at all" (silent no-op), never an
    # error this hook could fail loudly on.
    STEWARD_HOME_DIR=$(head -n 1 "$STEWARD_POINTER" 2>/dev/null | tr -d '\r\n')
    if [ -z "$STEWARD_HOME_DIR" ] || [ ! -d "$STEWARD_HOME_DIR" ]; then
        STEWARD_HOME_DIR=""
    fi
fi

if [ -n "${STEWARD_HOME_DIR:-}" ]; then
    # ONE guarded jq call resolves BOTH §10 constants together (fallback
    # 36h/2h on ANY parse failure -- absent/malformed config.json is
    # silent, no stderr noise, matching every other guarded read in this
    # hook). `@tsv` keeps this a single-line, single-jq-invocation read.
    STEWARD_HOURS_TSV=""
    STEWARD_CFG="$STEWARD_HOME_DIR/config.json"
    if [ -f "$STEWARD_CFG" ]; then
        STEWARD_HOURS_TSV=$(jq -r '[(.dead_man_hours // 36), (.aborted_orient_hours // 2)] | @tsv' "$STEWARD_CFG" 2>/dev/null)
    fi
    DEAD_MAN_HOURS=$(printf '%s' "$STEWARD_HOURS_TSV" | awk -F'\t' '{print $1}')
    ABORTED_ORIENT_HOURS=$(printf '%s' "$STEWARD_HOURS_TSV" | awk -F'\t' '{print $2}')
    case "$DEAD_MAN_HOURS" in ''|*[!0-9]*) DEAD_MAN_HOURS=36 ;; esac
    case "$ABORTED_ORIENT_HOURS" in ''|*[!0-9]*) ABORTED_ORIENT_HOURS=2 ;; esac

    # Dead-man: `last-run` is stamped at run-end ONLY (bin/fleet-steward),
    # so its own filesystem mtime IS the last-completed-run clock --
    # `find -mmin` is an O(1) stat, no content parsing needed. Missing
    # entirely counts as dead (a steward that has never once completed).
    LAST_RUN_FILE="$STEWARD_HOME_DIR/last-run"
    DEAD_MAN_MIN=$((DEAD_MAN_HOURS * 60))
    if [ ! -f "$LAST_RUN_FILE" ] || [ -n "$(find "$LAST_RUN_FILE" -mmin "+$DEAD_MAN_MIN" 2>/dev/null)" ]; then
        DEADMAN_LINE="DEAD-MAN: no completed fleet-steward run in over ${DEAD_MAN_HOURS}h"
    fi

    # Aborted: orient-line.txt is rewritten write-temp-then-os.replace at
    # run-start (status=running) and run-end (status=complete|degraded)
    # -- a "running" line whose file mtime is stale IS a run that started
    # and never finished (crash/kill), so the SAME O(1) mtime stat
    # decides this too; no timestamp parsing of the file's own content.
    ORIENT_LINE_FILE="$STEWARD_HOME_DIR/orient-line.txt"
    if [ -f "$ORIENT_LINE_FILE" ]; then
        ORIENT_LINE_RAW=$(head -n 1 "$ORIENT_LINE_FILE" 2>/dev/null)
        case "$ORIENT_LINE_RAW" in
            status=running*)
                ABORTED_MIN=$((ABORTED_ORIENT_HOURS * 60))
                if [ -n "$(find "$ORIENT_LINE_FILE" -mmin "+$ABORTED_MIN" 2>/dev/null)" ]; then
                    ABORTED_LINE="ABORTED: fleet-steward run appears stuck (status=running for over ${ABORTED_ORIENT_HOURS}h) -- check the journal"
                fi
                ;;
        esac
    fi
fi

# Skip if no state.json — no enforcement on uninstrumented projects.
# fleet-steward P2 Task 12: an uninstrumented project STILL surfaces a
# DEAD-MAN/ABORTED warning when one was computed above -- everything
# else about this branch is UNCHANGED. No pointer file (the overwhelming
# majority of installs) -> DEADMAN_LINE/ABORTED_LINE both stay empty ->
# this is the bare `exit 0` of every prior build, byte-for-byte (the
# public-cut falsifier: t_orient_hook_silent_without_pointer).
if [[ ! -f "${PROJECT_DIR}/.claude/state.json" ]]; then
    if [[ -n "$DEADMAN_LINE" || -n "$ABORTED_LINE" ]]; then
        STEWARD_MINIMAL=""
        [[ -n "$DEADMAN_LINE" ]] && STEWARD_MINIMAL="steward: ${DEADMAN_LINE}"
        if [[ -n "$ABORTED_LINE" ]]; then
            STEWARD_MINIMAL="${STEWARD_MINIMAL:+$STEWARD_MINIMAL$'\n'}steward: ${ABORTED_LINE}"
        fi
        jq -n --arg ctx "$STEWARD_MINIMAL" \
            '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
    fi
    exit 0
fi

# where-am-i lives in the plugin's bin/. Use ${CLAUDE_PLUGIN_ROOT} so this
# resolves correctly when fired as a plugin hook.
WHERE_AM_I="${CLAUDE_PLUGIN_ROOT:-}/bin/where-am-i"
if [[ ! -x "$WHERE_AM_I" ]]; then
    # Fall back to PATH (plugin auto-PATH adds bin/)
    if command -v where-am-i >/dev/null 2>&1; then
        WHERE_AM_I=$(command -v where-am-i)
    else
        # Can't find it — silent skip rather than crash
        exit 0
    fi
fi

ORIENT=$("$PYTHON_BIN" "$WHERE_AM_I" "$PROJECT_DIR" 2>/dev/null)
[[ -n "$ORIENT" ]] || exit 0

# Phase M #64 (audit round-1 reviewer top-3 #3): prompt-injection defense.
# The orient block from where-am-i contains state.json-derived strings
# (objective, current_focus, deliverable titles, blocked-on reasons). A
# poisoned state.json could include </state-tracking-orientation> or
# similar close-tag markup; sanitize by replacing ASCII < > with Unicode
# angle quotes (U+2039 ‹, U+203A ›) so the rendered text reads naturally
# but markup interpretation breaks.
SAFE_ORIENT="${ORIENT//</‹}"; SAFE_ORIENT="${SAFE_ORIENT//>/›}"

# fleet-steward P2 Task 12 (spec §7): for an INSTRUMENTED project, append
# the steward's own one-line status (+ the DEADMAN/ABORTED line(s) when
# set above) INSIDE the existing orientation block, before WRAPPED is
# built below. Gated on STEWARD_HOME_DIR (set above only when the
# pointer file resolved to a real, existing directory) -- absent pointer
# -> this whole block is skipped, SAFE_ORIENT unchanged, preserving the
# byte-identical-when-absent contract for instrumented projects too.
if [ -n "${STEWARD_HOME_DIR:-}" ]; then
    if [ -f "$ORIENT_LINE_FILE" ]; then
        # O(1) read of the SAME orient-line.txt already stat'd above.
        # Defanged with this file's OWN :218 idiom (same substitution,
        # reused rather than re-derived) before ever entering the block a
        # session reads.
        RAW_STEWARD_LINE=$(head -n 1 "$ORIENT_LINE_FILE" 2>/dev/null)
        SAFE_STEWARD_LINE="${RAW_STEWARD_LINE//</‹}"; SAFE_STEWARD_LINE="${SAFE_STEWARD_LINE//>/›}"
        SAFE_ORIENT="${SAFE_ORIENT}
steward: ${SAFE_STEWARD_LINE}"
    fi
    if [ -n "$DEADMAN_LINE" ]; then
        SAFE_ORIENT="${SAFE_ORIENT}
steward: ${DEADMAN_LINE}"
    fi
    if [ -n "$ABORTED_LINE" ]; then
        SAFE_ORIENT="${SAFE_ORIENT}
steward: ${ABORTED_LINE}"
    fi
fi

# Wrap in a clear marker block for the model
WRAPPED=$(printf '<state-tracking-orientation>\n%s\n</state-tracking-orientation>\n\nThis is the auto-injected orientation block from the state-tracking plugin. Treat it as the source of truth for the project'\''s current objective + version + deliverables. Update via the `update-state` skill or by editing .claude/state.json directly after substantial work.' "$SAFE_ORIENT")

# Observability enrichment: record the injected orientation size (the
# dominant per-session context cost) + session id, so accumulated logs can
# report a real per-session cost distribution and count distinct sessions /
# join to state-history transitions. session id is sanitized to a
# whitelist-safe charset so a malformed id can never corrupt the JSONL.
CTX_BYTES=$(printf '%s' "$WRAPPED" | wc -c 2>/dev/null | tr -d '[:space:]')
case "$CTX_BYTES" in ''|*[!0-9]*) CTX_BYTES=0 ;; esac
telem_safe_sid "$SESSION_ID"
# "scoped" records whether the temp confinement actually took effect. Without
# it the triage procedure hooks/perf-budget.json documents is unexecutable:
# it tells an operator that an over-budget reading means either the ~weekly
# legacy sweep or a fallback to the shared root, and under fallback every
# write still SUCCEEDS, so nothing else distinguishes the two. Costs nothing
# when CLAUDE_HOOK_LOG is off (this whole block is emit-path only). Fallback
# is permanent once triggered on a shared box — a squatted dir in sticky /tmp
# cannot be removed by its victim — so it is worth being able to see.
SCOPED=1; [ "$HTMP" = "${TMPDIR:-/tmp}" ] && SCOPED=0
TELEM_EXTRA=$(printf '"ctx_bytes":%s,"session":"%s","scoped":%s' "$CTX_BYTES" "$SAFE_SID" "$SCOPED")
TELEM_EMIT=1

jq -n --arg ctx "$WRAPPED" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

exit 0
