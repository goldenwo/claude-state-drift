#!/usr/bin/env python3
"""_state_lib — shared primitives used across the plugin's Python scripts.

Centralizes ISO timestamp parsing, lag computation, relative-age formatting,
and version normalization so that fixes land in one place instead of four.
Used by: bin/statusline-focus, bin/state-validate, bin/where-am-i,
bin/workflows, and (via CLI mode) hooks/state-staleness.sh.

The CLI mode supports a single operation today — `--lag-hours` — read via
env vars to avoid shell-injection in bash hooks:

    LU="$STATE_LAST_UPDATED" HT="$HEAD_COMMIT_ISO" \\
        python "$PLUGIN_ROOT/bin/_state_lib.py" --lag-hours

Prints an integer (0 if state is newer than HEAD, or on any parse error).
"""

import json
import os
import sys
from datetime import datetime, timezone
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


def compute_stats(hook_records, history_records, bytes_per_token=4):
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
        "reanchor_verdicts": verdicts,
    }


def _cli(argv):
    """Tiny CLI for bash hooks (state-staleness.sh and similar).

    Currently supports `--lag-hours` only. Reads timestamps from env vars
    (LU = state last_updated, HT = HEAD commit ISO) to avoid shell-injection
    when bash callers pass user-controlled state values.
    """
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
    print(f"_state_lib: unknown args: {argv}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
