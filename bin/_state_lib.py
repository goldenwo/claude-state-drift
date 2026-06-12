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
