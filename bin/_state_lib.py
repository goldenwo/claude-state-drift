#!/usr/bin/env python3
"""_state_lib — shared primitives used across the plugin's Python scripts.

Centralizes ISO timestamp parsing, lag computation, relative-age formatting,
and version normalization so that fixes land in one place instead of four.
Used by: bin/statusline-focus, bin/state-validate, bin/where-am-i,
bin/workflows, and (via CLI mode) hooks/state-staleness.sh.

The CLI mode supports three operations, all read via env vars (never argv)
to avoid shell-injection in bash hooks: `--lag-hours` (legacy single-value
lag, kept for any external caller), `--staleness` (fleet-steward P2 Task
8's two-clause lag+commits-since predicate, used by
hooks/state-staleness.sh and checks/state_staleness.py), and `--test`
(this file's own self-suite).

    LU="$STATE_LAST_UPDATED" HT="$HEAD_COMMIT_ISO" \\
        python "$PLUGIN_ROOT/bin/_state_lib.py" --lag-hours

`--lag-hours` prints an integer (0 if state is newer than HEAD, "-" on any
parse error). `--staleness` additionally reads REPO/HOURS_T/COMMITS_T and
prints `"<lag|-> <commits> <0|1>"` (lag, commits-since, is_stale).
"""

import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


def parse_iso(s):
    """Return tz-aware datetime, or None on any failure.

    Tolerates trailing 'Z' (UTC). Stamps with UTC tzinfo if absent.
    Returns None for None / empty / non-string / unparseable input.
    """
    if not isinstance(s, str) or not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def compute_lag_hours(state_iso, head_iso):
    """Return hours that HEAD is ahead of state, or None on parse failure.

    Always returns a non-negative integer (clamped to 0 if state is newer
    than HEAD, accommodating small clock skew). None signals "couldn't
    parse" — callers should silent-skip in that case.
    """
    a = parse_iso(state_iso)
    b = parse_iso(head_iso)
    if a is None or b is None:
        return None
    delta_h = (b - a).total_seconds() / 3600
    return int(delta_h) if delta_h > 0 else 0


# Default HEAD-lag (hours) before state.json is considered stale. Single home
# for the magic 24 across the Python callers — it used to recur as a local
# STALE_HOURS_DEFAULT in where-am-i / statusline-focus / workflows, as the
# threshold_hours default of compute_lag_days below, and as STATE_DRIFT_HOURS
# in audit-harness. (The bash hook state-staleness.sh keeps its own
# `${STATE_STALENESS_HOURS:-24}` default — it can't source a Python constant
# without a subprocess.) Overridable per call via the STATE_STALENESS_HOURS
# env knob (see resolve_staleness_hours).
STALE_HOURS_DEFAULT = 24


def resolve_staleness_hours():
    """Return the staleness threshold in hours from the env, else the default.

    Reads STATE_STALENESS_HOURS and int-parses it; falls back to
    STALE_HOURS_DEFAULT when the var is unset / None / not an integer. This is
    the shared half of the "resolve threshold" idiom that recurred verbatim in
    the live callers (where-am-i, statusline-focus, workflows).

    Deliberately does NOT consult STATE_STALENESS_DISABLE — the disable kill
    switch is a caller-side concern (the live callers early-return None on it,
    rendering no suffix/line; audit-harness intentionally ignores disable so a
    read-only drift audit still flags drift). Folding disable in here would
    silently change those semantics.
    """
    try:
        return int(os.environ.get("STATE_STALENESS_HOURS", str(STALE_HOURS_DEFAULT)))
    except (TypeError, ValueError):
        return STALE_HOURS_DEFAULT


# Default commits-since-lastupdated threshold before state.json is
# considered stale (the second clause of the two-clause staleness
# predicate -- fleet-steward P2 Task 8, survey cluster 4). Mirrors
# STALE_HOURS_DEFAULT's role exactly: single home for the magic 3,
# overridable per call via the STATE_STALENESS_COMMITS env knob (see
# resolve_staleness_commits). The bash hook keeps its own
# `${STATE_STALENESS_COMMITS:-3}` default for the same reason
# STALE_HOURS_DEFAULT's docstring gives -- it cannot source a Python
# constant without a subprocess.
STALE_COMMITS_DEFAULT = 3


def resolve_staleness_commits():
    """Return the staleness commits-since threshold from the env, else
    the default. Mirrors resolve_staleness_hours() exactly: reads
    STATE_STALENESS_COMMITS and int-parses it, falling back to
    STALE_COMMITS_DEFAULT when the var is unset / None / not an integer.

    fleet-steward P2 Task 8 (survey cluster 4): the commits half of the
    two-clause staleness predicate, ported alongside compute_commits_since
    and evaluate_staleness so the AND lives in exactly one place.
    """
    try:
        return int(os.environ.get(
            "STATE_STALENESS_COMMITS", str(STALE_COMMITS_DEFAULT)))
    except (TypeError, ValueError):
        return STALE_COMMITS_DEFAULT


# --- non-interactive git posture, for compute_commits_since below -----------
#
# Same defense-in-depth shape as checks/unpushed_work.py's own
# _noop_askpass/_empty_global_gitconfig/_git_env trio, duplicated here
# rather than imported: this module is a shared library used OUTSIDE the
# checks/ tree (hooks/state-staleness.sh, bin/where-am-i,
# bin/statusline-focus, bin/workflows), so it must not grow a dependency
# on checks/ or on bin/_steward.py to reach it. `git log --since` never
# touches the network, so GIT_TERMINAL_PROMPT/GIT_ASKPASS matter less
# here than they do for a `fetch`, but applying the same posture is
# harmless and keeps every git subprocess in this codebase consistent.

_GIT_LOG_TIMEOUT_SECONDS = 30


def _noop_askpass() -> str:
    d = Path(tempfile.gettempdir()) / "steward-noop-askpass"
    d.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        p = d / "askpass.cmd"
        if not p.is_file():
            p.write_text("@echo off\r\nexit /b 0\r\n", encoding="utf-8")
    else:
        p = d / "askpass.sh"
        if not p.is_file():
            p.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            os.chmod(str(p), 0o755)
    return str(p)


def _empty_global_gitconfig() -> str:
    p = Path(tempfile.gettempdir()) / "steward-empty-gitconfig.ini"
    if not p.is_file():
        p.write_text("", encoding="utf-8")
    return str(p)


def _git_env() -> dict:
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GCM_INTERACTIVE"] = "never"
    env["GIT_ASKPASS"] = _noop_askpass()
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = _empty_global_gitconfig()
    return env


def compute_commits_since(repo_root, since_iso):
    """Count commits reachable from HEAD since `since_iso`, via the SAME
    git invocation hooks/state-staleness.sh used inline before this port
    (fleet-steward P2 Task 8, survey cluster 4: "a relocation, not a
    rewrite") -- `git -C <repo_root> log --since=<since_iso> --oneline`,
    with the line count done in PYTHON (no `wc`).

    Returns None on ANY git failure: missing/falsy repo_root or since_iso,
    git not on PATH, a non-zero exit, or a timeout -- deliberately never
    0 on failure, so a caller can distinguish "git failed to answer" from
    "legitimately zero commits since since_iso" (evaluate_staleness's
    decision #4 depends on this distinction: a git failure fails toward
    silence, never toward a false stale-fire).

    This function has no opinion about WHEN it is safe to call --
    evaluate_staleness owns the "only call this when lag_hours > 0" guard
    (the Phase P F6 false-trip guard: `git log --since` with an
    unparseable value returns ALL commits), not this function.
    """
    if not repo_root or not since_iso:
        return None
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo_root), "log",
             f"--since={since_iso}", "--oneline"],
            env=_git_env(), timeout=_GIT_LOG_TIMEOUT_SECONDS,
            capture_output=True, text=True, encoding="utf-8",
            errors="replace")
    except (subprocess.TimeoutExpired, OSError):
        return None
    if proc.returncode != 0:
        return None
    return len(proc.stdout.splitlines())


def evaluate_staleness(state_iso, head_iso, repo_root,
                        hours_threshold=None, commits_threshold=None):
    """The two-clause staleness predicate -- THE ONLY place the AND lives
    (fleet-steward P2 Task 8, survey cluster 4: "so the AND lives in
    exactly one place"). Both `hooks/state-staleness.sh` (via the
    `--staleness` CLI branch below) and `checks/state_staleness.py` (the
    fleet check) call this function; neither reimplements the gate.

    Returns `(lag_hours, commits, is_stale)`:

      lag_hours -- compute_lag_hours(state_iso, head_iso); None on parse
                   failure (mirrors compute_lag_hours's own contract --
                   the CLI's "-" sentinel is _cli's presentation-layer
                   detail, not this function's return shape).
      commits   -- commits reachable since state_iso; 0 when not counted
                   at all (lag_hours <= 0, the F6 guard below) or when
                   compute_commits_since itself failed (git error).
      is_stale  -- True only when lag_hours is not None, commit-counting
                   did not fail, lag_hours >= hours_threshold, AND
                   commits >= commits_threshold. Every other path is
                   False -- silence is the default, never a false fire
                   (module docstring: "callers should silent-skip").

    Preserves exactly the bash hook's prior semantics (module docstring,
    survey cluster 4 "Preserve"):
      - the `lag_hours > 0` guard before counting commits at all: `git
        log --since` with an unparseable value returns ALL commits, a
        false trip (Phase P F6) -- so compute_commits_since is NEVER
        called when lag_hours is not strictly positive, and commits
        stays 0 in that case;
      - parse failure (state_iso/head_iso unparseable) -> skip, not fire:
        `(None, 0, False)`;
      - the clamp-to-0 on negative lag is compute_lag_hours's OWN
        existing behavior (verified above, not re-implemented here).

    A git failure while counting commits (compute_commits_since returns
    None) is reported as commits=0 for the caller's telemetry, but
    is_stale is forced False regardless of the thresholds (decision #4:
    "fail toward silence, matching the hook's current posture") -- this
    matters specifically when commits_threshold is 0, where a naive
    "0 >= 0" would otherwise let a git failure masquerade as a confirmed
    stale-fire.

    `hours_threshold` / `commits_threshold` default to
    resolve_staleness_hours() / resolve_staleness_commits() (the env-var
    resolution) when not given explicitly -- an explicit argument always
    wins, the same "explicit override wins, otherwise the shared
    default" idiom checks/*.py's own `_timeout` helpers already use.
    """
    lag = compute_lag_hours(state_iso, head_iso)
    if lag is None:
        return None, 0, False

    hours_t = (hours_threshold if hours_threshold is not None
               else resolve_staleness_hours())
    commits_t = (commits_threshold if commits_threshold is not None
                 else resolve_staleness_commits())

    if lag > 0:
        commits = compute_commits_since(repo_root, state_iso)
        git_failed = commits is None
        if git_failed:
            commits = 0
    else:
        commits, git_failed = 0, False

    if git_failed:
        return lag, commits, False

    is_stale = lag >= hours_t and commits >= commits_t
    return lag, commits, is_stale


def compute_lag_days(state_iso, head_iso, threshold_hours=STALE_HOURS_DEFAULT):
    """Return integer days of lag if HEAD is more than threshold_hours
    ahead of state, else None. Minimum return value is 1 when over threshold.

    Used by statusline-focus to render the `· ⚠ stale Nd` suffix.
    """
    h = compute_lag_hours(state_iso, head_iso)
    if h is None or h <= threshold_hours:
        return None
    days = h // 24
    return days if days > 0 else 1


def relative_age(iso_ts, fmt="short"):
    """Convert an ISO timestamp to a human-readable age string.

    fmt='short': `2d` / `5h` / `42m` / `now` / `?`
    fmt='long':  `2d ago` / `5h ago` / `42m ago` / `just now` / `unknown`

    Returns `'?'` (short) or `'unknown'` (long) for unparseable input.
    """
    short = fmt != "long"
    if not iso_ts:
        return "?" if short else "unknown"
    dt = parse_iso(iso_ts)
    if dt is None:
        return iso_ts if not short else "?"
    secs = (datetime.now(timezone.utc) - dt).total_seconds()
    if secs < 0:
        # Defensive: small clock-skew → not negative
        return "now" if short else "just now"
    if secs < 60:
        return f"{int(secs)}s" if short else f"{int(secs)}s ago"
    if secs < 3600:
        m = int(secs // 60)
        return f"{m}m" if short else f"{m}m ago"
    if secs < 86400:
        h = int(secs // 3600)
        return f"{h}h" if short else f"{h}h ago"
    d = int(secs // 86400)
    return f"{d}d" if short else f"{d}d ago"


def normalize_version(v):
    """Strip pre-release/build suffixes for current-version comparison.

    '0.3.0-dev'   -> '0.3.0'
    '0.3.0-rc1'   -> '0.3.0'
    '0.3.0+abc'   -> '0.3.0'
    '0.3.0'       -> '0.3.0'
    None / empty  -> ''
    """
    if not v:
        return ""
    if not isinstance(v, str):
        v = str(v)
    for sep in ("-", "+"):
        if sep in v:
            v = v.split(sep, 1)[0]
    return v


# --- deliverable-history append-only log -----------------------------------
#
# state.json carries deliverables[] but no audit trail for "which session
# transitioned deliverable X from in_progress -> done, and when?". The
# companion file .claude/state-history.jsonl records one compact JSON object
# per status transition (append-only). It is deliberately NOT part of
# state.json (and so is NOT validated by bin/state-validate) — it is a
# growing audit log, not schema state. The WRITE side lives in bin/state-history
# (keeping bin/where-am-i read-only); the READ side is where-am-i --history.
# Both share these helpers so the on-disk format has a single owner.

HISTORY_FILENAME = "state-history.jsonl"


def history_path(root):
    """Return the .claude/state-history.jsonl path under `root`."""
    return Path(root) / ".claude" / HISTORY_FILENAME


def append_history(root, deliverable_id, from_status, to_status,
                   ts=None, session_id=None):
    """Append one transition record to .claude/state-history.jsonl.

    Writes a single compact JSON line ending in '\\n' in APPEND mode, so an
    existing log is never truncated or rewritten. Creates the `.claude` dir
    and the file on first use. `ts` defaults to the current UTC time in ISO
    8601 with a trailing 'Z'; `session_id` defaults to "unknown". Returns the
    record dict that was written.
    """
    if ts is None:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if session_id is None:
        session_id = "unknown"
    record = {
        "deliverable_id": deliverable_id,
        "from": from_status,
        "to": to_status,
        "ts": ts,
        "session_id": session_id,
    }
    path = history_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    return record


def append_event(root, event_type, verdict=None, ts=None, session_id=None):
    """Append one non-transition EVENT record to .claude/state-history.jsonl.

    Observability companion to append_history (csd-observability-stats):
    durable session events — today only re-anchor drift verdicts — share the
    transition log's append-only file. Event records carry an `event` key and
    NO `deliverable_id`, so the `where-am-i --history <id>` read path
    (read_history with a deliverable_id filter) skips them naturally; offline
    stats miners select on `event` instead. Record shape:

        {"event":"re-anchor","verdict":"mild","ts":"...Z","session_id":"..."}

    `verdict` is optional at this layer (domain validation is the CLI's job —
    bin/state-history owns the accepted event types and verdict values).
    Returns the record dict that was written.
    """
    if ts is None:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if session_id is None:
        session_id = "unknown"
    record = {"event": event_type}
    if verdict is not None:
        record["verdict"] = verdict
    record["ts"] = ts
    record["session_id"] = session_id
    path = history_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    return record


def read_history(root, deliverable_id=None):
    """Read .claude/state-history.jsonl, newest record last (file order).

    Returns a list of record dicts. Malformed or blank lines are skipped
    SILENTLY — a single corrupt line must never crash a reader of an
    append-only log. Returns [] if the file does not exist or cannot be read.
    If `deliverable_id` is given, only records with that id are returned.
    """
    path = history_path(root)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    records = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(rec, dict):
            continue
        if deliverable_id is not None and rec.get("deliverable_id") != deliverable_id:
            continue
        records.append(rec)
    return records


# --- observability stats (csd-observability-stats) -------------------------
#
# Two append-only local logs feed the stats:
#   .claude/.hook-log.jsonl    hook-fire telemetry (CLAUDE_HOOK_LOG=1, opt-in)
#   .claude/state-history.jsonl deliverable transitions + re-anchor events
# compute_stats() joins them by session id to derive HONEST OPERATIONAL
# metrics (activity, cost, nudge->update conversion, staleness-resolution).
# These are NOT an effectiveness measure — see compute_stats.__doc__.

HOOK_LOG_FILENAME = ".hook-log.jsonl"
_ORIENT_HOOK = "session-start-orient.sh"
_FOCUS_HOOK = "focus-check.sh"
_COMMIT_HOOK = "state-track-commit.sh"
_STALENESS_HOOK = "state-staleness.sh"
_DECISION_HOOK = "decision-prompt-telemetry.sh"


def hook_log_path(root):
    """Return the .claude/.hook-log.jsonl path under `root`."""
    return Path(root) / ".claude" / HOOK_LOG_FILENAME


def read_hook_log(root):
    """Read .claude/.hook-log.jsonl -> list of record dicts. Malformed/blank
    lines are skipped SILENTLY (append-only telemetry — one corrupt line must
    never crash a reader). [] if the file is absent or unreadable."""
    try:
        text = hook_log_path(root).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    records = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except (ValueError, TypeError):
            continue
        if isinstance(rec, dict):
            records.append(rec)
    return records


def _percentile(values, pct):
    """Nearest-rank percentile of a numeric list (pct 0..100). None if empty."""
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((pct / 100.0) * (len(s) - 1)))))
    return s[k]


def compute_stats(hook_records, history_records, bytes_per_token=3.8):
    """Honest OPERATIONAL stats from the two local logs.

    Measures the plugin's own ACTIVITY and COST, plus two BEHAVIORAL bookkeeping
    signals — nudge->update conversion and staleness-resolution. It is NOT an
    effectiveness measure: drift that a re-injection prevented is unobservable,
    so nothing here proves the plugin keeps a session on goal. Any published
    figure is an operational receipt, never an efficacy claim; re-anchor
    verdicts are self-assessment and must not be published as efficacy.

    Joins are by session: hook-log `session` == history `session_id`. Records
    with a missing or "unknown" session are excluded from joins (unattributable)
    — which is why bin/state-history defaults the session to the real
    CLAUDE_CODE_SESSION_ID, so skill-written updates join the telemetry.
    """
    emits = [r for r in hook_records if r.get("fired_emit") == 1]

    def _emits_for(hook):
        return [r for r in emits if r.get("hook") == hook]

    orient = _emits_for(_ORIENT_HOOK)
    focus = _emits_for(_FOCUS_HOOK)
    commit_nudges = _emits_for(_COMMIT_HOOK)
    staleness_nudges = _emits_for(_STALENESS_HOOK)

    sessions = {r.get("session") for r in emits if r.get("session")}
    sessions.discard("unknown")
    ts_all = [r.get("ts") for r in emits if r.get("ts")]
    span = (min(ts_all), max(ts_all)) if ts_all else (None, None)

    def _ctx_tokens(recs):
        vals = [r["ctx_bytes"] for r in recs
                if isinstance(r.get("ctx_bytes"), (int, float))]
        if not vals:
            return None
        return {"p50_tokens": round(_percentile(vals, 50) / bytes_per_token),
                "p95_tokens": round(_percentile(vals, 95) / bytes_per_token),
                "n": len(vals)}

    # Index transitions by session -> sorted parsed timestamps for the join.
    by_session = {}
    for r in history_records:
        if not r.get("deliverable_id"):
            continue
        sid, dt = r.get("session_id"), parse_iso(r.get("ts"))
        if not sid or sid == "unknown" or dt is None:
            continue
        by_session.setdefault(sid, []).append(dt)
    for sid in by_session:
        by_session[sid].sort()

    def _first_followup(session, after_dt):
        if after_dt is None:
            return None
        for dt in by_session.get(session, ()):
            if dt >= after_dt:
                return dt
        return None

    conv_total = conv_converted = 0
    for r in commit_nudges:
        sid = r.get("session")
        if not sid or sid == "unknown":
            continue
        conv_total += 1
        if _first_followup(sid, parse_iso(r.get("ts"))):
            conv_converted += 1

    res_deltas_min = []
    stale_total = stale_resolved = 0
    for r in staleness_nudges:
        sid, nudge_dt = r.get("session"), parse_iso(r.get("ts"))
        if not sid or sid == "unknown" or nudge_dt is None:
            continue
        stale_total += 1
        follow = _first_followup(sid, nudge_dt)
        if follow:
            stale_resolved += 1
            res_deltas_min.append((follow - nudge_dt).total_seconds() / 60.0)

    # C6 decision-prompt calibration. Counts are validated and clamped PER
    # RECORD (followed_i <= rec_i) so one malformed log line can neither push
    # the override rate negative nor erase genuine override signal from the
    # healthy records around it. Bools are excluded explicitly — bool is a
    # subclass of int, so `"q_rec": true` would otherwise count as 1.
    decisions = _emits_for(_DECISION_HOOK)

    def _count(rec, key):
        v = rec.get(key)
        ok = isinstance(v, int) and not isinstance(v, bool) and v >= 0
        return v if ok else 0

    dec_rec = dec_followed = dec_neutral = 0
    for r in decisions:
        rec_n = _count(r, "q_rec")
        dec_rec += rec_n
        dec_followed += min(_count(r, "q_rec_followed"), rec_n)
        dec_neutral += _count(r, "q_neutral")

    verdicts = {}
    for r in history_records:
        if r.get("event") == "re-anchor":
            v = r.get("verdict", "?")
            verdicts[v] = verdicts.get(v, 0) + 1

    return {
        "sessions": len(sessions),
        "span": span,
        "activity": {"orientations": len(orient),
                     "focus_reinjections": len(focus),
                     "commit_nudges": len(commit_nudges),
                     "staleness_nudges": len(staleness_nudges)},
        "cost": {"orientation": _ctx_tokens(orient), "focus": _ctx_tokens(focus)},
        "conversion": {"total": conv_total, "converted": conv_converted,
                       "rate": (conv_converted / conv_total) if conv_total else None},
        "staleness_resolution": {
            "total": stale_total, "resolved": stale_resolved,
            "median_minutes": (_percentile(res_deltas_min, 50)
                               if res_deltas_min else None)},
        "decision_prompts": {
            "recommended": dec_rec, "followed": dec_followed,
            "overridden": dec_rec - dec_followed,
            "override_rate": (((dec_rec - dec_followed) / dec_rec)
                              if dec_rec else None),
            "neutral": dec_neutral},
        "reanchor_verdicts": verdicts,
    }


def _env_int(name):
    """Parse env var `name` as an int; None if unset OR unparseable (the
    caller's "explicit override wins" fallback then applies) -- used by
    the `--staleness` CLI branch for the optional HOURS_T/COMMITS_T
    overrides."""
    raw = os.environ.get(name)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _cli(argv):
    """Tiny CLI for bash hooks (state-staleness.sh and similar).

    Supports `--lag-hours` (legacy, still used nowhere in this repo after
    fleet-steward P2 Task 8's hook repoint, but kept for any external
    caller) and `--staleness` (Task 8's two-clause predicate). Both read
    every input from ENV VARS ONLY (LU/HT/REPO/HOURS_T/COMMITS_T),
    NEVER argv -- argv beyond the flag itself is inert by construction,
    so a bash caller can pass a tampered state.json value through an env
    var without it ever becoming shell/Python injection (the T47
    regression-guard posture, survey cluster 4: "LU/HT/repo passed by
    env, never shell interpolation").
    """
    if "--test" in argv:
        return run_tests()
    if any(a in ("--help", "-h") for a in argv):
        print(__doc__)
        return 0
    if "--lag-hours" in argv:
        lu = os.environ.get("LU", "")
        ht = os.environ.get("HT", "")
        result = compute_lag_hours(lu, ht)
        # Phase Q F-new-5 (round-4 reviewer): distinguish "parse failed"
        # from "lag is 0" (state newer than HEAD, or sub-hour delta).
        # Print "-" sentinel on parse failure so the caller can react
        # to malformed timestamps without false-tripping the "no nudge"
        # branch. Numeric output remains compatible with prior callers.
        if result is None:
            print("-")
        else:
            print(result)
        return 0
    if "--staleness" in argv:
        lu = os.environ.get("LU", "")
        ht = os.environ.get("HT", "")
        repo = os.environ.get("REPO", "")
        hours_t = _env_int("HOURS_T")
        commits_t = _env_int("COMMITS_T")
        lag, commits, is_stale = evaluate_staleness(
            lu, ht, repo, hours_t, commits_t)
        lag_str = "-" if lag is None else str(lag)
        print(f"{lag_str} {commits} {1 if is_stale else 0}")
        return 0
    print(f"_state_lib: unknown args: {argv}", file=sys.stderr)
    return 2


# --------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------
#
# This file previously shipped with NO in-file test suite -- it was
# covered only indirectly, by its callers' own suites (bin/state-validate,
# bin/where-am-i, bin/workflows, bin/audit-harness, and
# hooks/state-staleness.sh via bin/focus-check-test's Section 8). That
# indirect coverage still stands for parse_iso / compute_lag_hours /
# resolve_staleness_hours / compute_lag_days / relative_age /
# normalize_version / the history + stats helpers -- this suite does NOT
# re-cover them (out of scope for fleet-steward P2 Task 8; scope creep to
# backfill a whole file's test debt in a task about two new functions and
# a CLI branch). It covers ONLY what Task 8 adds: resolve_staleness_commits,
# compute_commits_since, evaluate_staleness, and the `--staleness` CLI
# branch -- direct, in-file tests, added to `_cli` per the task brief's
# own instruction ("add a --test self-suite entry to _cli ONLY if you can
# do it without disturbing existing dispatch semantics" -- `--test` was
# previously unhandled, falling through to the "unknown args" branch, so
# adding it here changes no existing caller's behavior).

def _git(args, cwd):
    return subprocess.run(
        ["git", *args], cwd=str(cwd), env=_git_env(), check=True,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=30)


def _make_commit_repo(base: Path, n_commits: int) -> Path:
    """A real local git repo with exactly `n_commits` commits, all made
    "now" (real wall-clock time) -- sufficient for `--since=<N hours
    ago>` fixtures without needing to fake commit dates, mirroring
    bin/focus-check-test's own T42 fixture shape (old last_updated +
    fresh commits, no GIT_COMMITTER_DATE override needed)."""
    repo = base / "repo"
    base.mkdir(parents=True, exist_ok=True)
    _git(["init", "-q", "-b", "master", str(repo)], base)
    _git(["config", "user.email", "steward-test@example.invalid"], repo)
    _git(["config", "user.name", "steward test"], repo)
    _git(["config", "commit.gpgsign", "false"], repo)
    for i in range(n_commits):
        (repo / f"f{i}.txt").write_text("x\n", encoding="utf-8")
        _git(["add", "-A"], repo)
        _git(["commit", "-q", "-m", f"c{i}"], repo)
    return repo


def _iso_hours_ago(h):
    return (datetime.now(timezone.utc) - timedelta(hours=h)).isoformat()


def run_tests():
    passed = failed = 0
    cases = []

    def check(name, cond):
        nonlocal passed, failed
        if cond:
            passed += 1
        else:
            failed += 1
            cases.append(f"  FAIL  {name}")

    # --- resolve_staleness_commits() -----------------------------------
    orig_env = os.environ.get("STATE_STALENESS_COMMITS")
    try:
        os.environ.pop("STATE_STALENESS_COMMITS", None)
        check("R1 resolve_staleness_commits() default is 3 (no env)",
              resolve_staleness_commits() == 3)
        os.environ["STATE_STALENESS_COMMITS"] = "10"
        check("R2 resolve_staleness_commits() honors STATE_STALENESS_COMMITS=10",
              resolve_staleness_commits() == 10)
        os.environ["STATE_STALENESS_COMMITS"] = "not-a-number"
        check("R3 resolve_staleness_commits() falls back to default on a "
              "malformed env value",
              resolve_staleness_commits() == 3)
    finally:
        if orig_env is None:
            os.environ.pop("STATE_STALENESS_COMMITS", None)
        else:
            os.environ["STATE_STALENESS_COMMITS"] = orig_env

    # --- compute_commits_since() ----------------------------------------
    try:
        with tempfile.TemporaryDirectory() as tmp_s:
            repo = _make_commit_repo(Path(tmp_s), 4)
            n = compute_commits_since(repo, _iso_hours_ago(50))
            check("C1 compute_commits_since() counts real commits made "
                  "since a 50h-ago cutoff (4 commits fixture)", n == 4)
            n_future = compute_commits_since(
                repo, (datetime.now(timezone.utc)
                       + timedelta(hours=1)).isoformat())
            check("C2 compute_commits_since() with a FUTURE since-date "
                  "-> 0 (nothing has happened yet)", n_future == 0)
    except Exception as e:  # noqa: BLE001
        check(f"C1/C2 compute_commits_since real fixture "
              f"({type(e).__name__}: {e})", False)

    check("C3 compute_commits_since() on a nonexistent repo path -> None "
          "(git failure), never 0",
          compute_commits_since("/does/not/exist/at/all", _iso_hours_ago(1))
          is None)
    check("C4 compute_commits_since() with empty repo_root -> None",
          compute_commits_since("", _iso_hours_ago(1)) is None)
    check("C5 compute_commits_since() with empty since_iso -> None",
          compute_commits_since("/tmp", "") is None)

    # --- evaluate_staleness() -- the brief's three falsifiers, verbatim --
    try:
        with tempfile.TemporaryDirectory() as tmp_s:
            repo_and = _make_commit_repo(Path(tmp_s) / "and", 4)
            lag, commits, stale = evaluate_staleness(
                _iso_hours_ago(50), _iso_hours_ago(0), repo_and)
            check("E1 t_evaluate_staleness_and_gate: 4 commits + 50h lag, "
                  "default thresholds -> stale, lag>=24, commits>=3 "
                  "(brief falsifier, verbatim)",
                  stale is True and lag >= 24 and commits >= 3)
    except Exception as e:  # noqa: BLE001
        check(f"E1 and-gate ({type(e).__name__}: {e})", False)

    try:
        with tempfile.TemporaryDirectory() as tmp_s:
            repo_low = _make_commit_repo(Path(tmp_s) / "low", 1)
            result = evaluate_staleness(
                _iso_hours_ago(50), _iso_hours_ago(0), repo_low)
            check("E2 t_evaluate_staleness_low_commits_no_fire: 1 commit + "
                  "50h lag, default thresholds -> NOT stale (T45 "
                  "semantics; brief falsifier, verbatim)",
                  result[2] is False)
    except Exception as e:  # noqa: BLE001
        check(f"E2 low-commits-no-fire ({type(e).__name__}: {e})", False)

    try:
        with tempfile.TemporaryDirectory() as tmp_s:
            repo_garbage = _make_commit_repo(Path(tmp_s) / "garbage", 5)
            lag, commits, stale = evaluate_staleness(
                "garbage", _iso_hours_ago(0), repo_garbage)
            check("E3 t_unparseable_since_guard: unparseable state_iso -> "
                  "(None, 0, False) -- F6 guard preserved (brief "
                  "falsifier, verbatim)",
                  lag is None and commits == 0 and stale is False)

            # Stronger proof (self-review requirement): the F6 guard is
            # not just an output coincidence -- compute_commits_since is
            # NEVER INVOKED at all when lag is unparseable, proven via a
            # spy on the module global (evaluate_staleness resolves
            # `compute_commits_since` from THIS module's globals() at
            # call time, so replacing it here is visible to it). The
            # fixture repo carries 5 REAL recent commits -- if the guard
            # were bypassed and compute_commits_since were called with
            # the literal string "garbage" as --since, git's own
            # unparseable-date behavior would be exercised for real, not
            # just inferred from a mocked return value.
            calls = []
            orig_cc = globals()["compute_commits_since"]

            def _spy(repo_root, since_iso):
                calls.append((repo_root, since_iso))
                return orig_cc(repo_root, since_iso)

            globals()["compute_commits_since"] = _spy
            try:
                evaluate_staleness(
                    "garbage", _iso_hours_ago(0), repo_garbage)
            finally:
                globals()["compute_commits_since"] = orig_cc
            check("E3b F6 guard spy proof: compute_commits_since is NEVER "
                  "invoked when state_iso is unparseable",
                  calls == [])
    except Exception as e:  # noqa: BLE001
        check(f"E3 unparseable-since-guard ({type(e).__name__}: {e})", False)

    # --- F6 guard, second form: lag parses to exactly 0 (state newer
    #     than/equal to HEAD) -- commits must stay 0 and NEVER invoke
    #     compute_commits_since either (the guard is "lag > 0", not
    #     "lag is not None"). ---------------------------------------------
    try:
        with tempfile.TemporaryDirectory() as tmp_s:
            repo_fresh = _make_commit_repo(Path(tmp_s) / "fresh", 5)
            calls = []
            orig_cc = globals()["compute_commits_since"]

            def _spy2(repo_root, since_iso):
                calls.append((repo_root, since_iso))
                return orig_cc(repo_root, since_iso)

            globals()["compute_commits_since"] = _spy2
            try:
                lag, commits, stale = evaluate_staleness(
                    _iso_hours_ago(0), _iso_hours_ago(1), repo_fresh)
            finally:
                globals()["compute_commits_since"] = orig_cc
            check("E4 lag==0 (state newer than HEAD) -> commits stays 0, "
                  "compute_commits_since never invoked, never stale",
                  lag == 0 and commits == 0 and stale is False
                  and calls == [])
    except Exception as e:  # noqa: BLE001
        check(f"E4 lag-zero guard ({type(e).__name__}: {e})", False)

    # --- git-failure-on-commit-count fails toward silence (decision #4) -
    try:
        with tempfile.TemporaryDirectory() as tmp_s:
            # A repo_root that parses fine for lag purposes (lag/head are
            # independent of repo_root) but does not exist on disk, so
            # compute_commits_since fails -> git_failed True.
            bogus_repo = Path(tmp_s) / "does-not-exist"
            lag, commits, stale = evaluate_staleness(
                _iso_hours_ago(50), _iso_hours_ago(0), bogus_repo,
                hours_threshold=1, commits_threshold=0)
            check("E5 a git failure while counting commits forces "
                  "is_stale=False even with commits_threshold=0 (decision "
                  "#4: fail toward silence, never a false stale-fire off "
                  "a git error)",
                  stale is False and commits == 0)
    except Exception as e:  # noqa: BLE001
        check(f"E5 git-failure-fails-toward-silence "
              f"({type(e).__name__}: {e})", False)

    # --- explicit threshold overrides win over the env-derived default --
    try:
        with tempfile.TemporaryDirectory() as tmp_s:
            repo = _make_commit_repo(Path(tmp_s), 2)
            lag, commits, stale = evaluate_staleness(
                _iso_hours_ago(50), _iso_hours_ago(0), repo,
                hours_threshold=1, commits_threshold=2)
            check("E6 explicit hours_threshold/commits_threshold override "
                  "the env-derived defaults (2 commits, threshold=2 -> "
                  "stale)", stale is True)
    except Exception as e:  # noqa: BLE001
        check(f"E6 explicit-threshold-override ({type(e).__name__}: {e})",
              False)

    # --- --staleness CLI branch: env-only inputs, never argv -----------
    def _with_env(pairs, fn):
        backup = {k: os.environ.get(k) for k in pairs}
        os.environ.update({k: v for k, v in pairs.items() if v is not None})
        for k, v in pairs.items():
            if v is None:
                os.environ.pop(k, None)
        try:
            return fn()
        finally:
            for k, v in backup.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    import contextlib
    import io

    def _run_cli_staleness(argv_extra=None):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = _cli(["--staleness", *(argv_extra or [])])
        return rc, buf.getvalue().strip()

    try:
        with tempfile.TemporaryDirectory() as tmp_s:
            repo = _make_commit_repo(Path(tmp_s), 4)
            rc, out = _with_env(
                {"LU": _iso_hours_ago(50), "HT": _iso_hours_ago(0),
                 "REPO": str(repo), "HOURS_T": None, "COMMITS_T": None},
                _run_cli_staleness)
            parts = out.split()
            check("S1 --staleness CLI: env-only LU/HT/REPO -> 'lag commits "
                  "is_stale' one-line, is_stale=1 for a real "
                  "stale-and-4-commits fixture",
                  rc == 0 and len(parts) == 3 and parts[2] == "1"
                  and int(parts[0]) >= 24 and int(parts[1]) >= 3)

            # S2: extraneous argv is INERT -- never interpolated, never
            # changes the outcome (the T47 injection posture, at the CLI
            # layer this time rather than the hook layer).
            rc2, out2 = _with_env(
                {"LU": _iso_hours_ago(50), "HT": _iso_hours_ago(0),
                 "REPO": str(repo), "HOURS_T": None, "COMMITS_T": None},
                lambda: _run_cli_staleness(
                    ["'); import os; os.system('touch /tmp/pwned'); ('"]))
            check("S2 --staleness CLI ignores extraneous argv entirely "
                  "(injection-attempt string has zero effect on output)",
                  out2 == out and rc2 == rc)

            # S3: HOURS_T/COMMITS_T env overrides are honored.
            rc3, out3 = _with_env(
                {"LU": _iso_hours_ago(50), "HT": _iso_hours_ago(0),
                 "REPO": str(repo), "HOURS_T": "999", "COMMITS_T": None},
                _run_cli_staleness)
            check("S3 --staleness CLI honors a HOURS_T override "
                  "(999h threshold on a 50h-lag fixture -> is_stale=0)",
                  rc3 == 0 and out3.split()[2] == "0")
    except Exception as e:  # noqa: BLE001
        check(f"S1-S3 --staleness CLI ({type(e).__name__}: {e})", False)

    try:
        rc4, out4 = _with_env(
            {"LU": "garbage", "HT": _iso_hours_ago(0), "REPO": "",
             "HOURS_T": None, "COMMITS_T": None}, _run_cli_staleness)
        check("S4 --staleness CLI on an unparseable LU -> '- 0 0' "
              "(matching compute_lag_hours's own '-' convention)",
              rc4 == 0 and out4 == "- 0 0")
    except Exception as e:  # noqa: BLE001
        check(f"S4 --staleness CLI parse-failure sentinel "
              f"({type(e).__name__}: {e})", False)

    for line in cases:
        print(line)
    print(f"--- _state_lib --test: {passed} passed, {failed} failed ---")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
