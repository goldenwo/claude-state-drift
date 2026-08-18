# claude-state-drift — `.claude/state.json` schema

`claude-state-drift` keeps a small JSON file, `.claude/state.json`, at the root of
each project. It records the project's master objective, the current focus, and a
list of deliverables with their status. The hooks, commands, and skills in this
plugin read and surface that file at session start and as you work.

This document is the canonical schema. Validate any `state.json` with the bundled
`state-validate` tool — it exits `0` when the file is valid. The tool is on the
Bash tool's `PATH` in any Claude Code session while the plugin is enabled, so
"run state-validate" just works.

## Top-level fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `schema_version` | integer | recommended | Current version is `1`. Omitting it is allowed but warns. |
| `objective` | string | **yes** | The master vision for the project. Changing it is a deliberate act. |
| `objective_set_at` | string (ISO date) | no | When the objective was set. |
| `version` | string | **yes** | Current target version, e.g. `0.1.0-dev`. |
| `current_focus` | string | **yes** | One sentence: what the session is working on right now. |
| `deliverables` | array | no | Deliverable objects (see below). |
| `blocked` | array | no | Items waiting on an external factor. |
| `open_questions` | array | no | Unresolved decisions. |
| `last_updated` | string (ISO timestamp) | **yes** | Must be a valid ISO 8601 timestamp. |

## Deliverable objects

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `id` | string | **yes** | Unique kebab-case id. |
| `title` | string | **yes** | Human-readable title. |
| `status` | string | **yes** | One of `done`, `in_progress`, `deferred`, `blocked`. |
| `version` | string | no | Target version for this deliverable. |
| `started_at` | string (ISO date) | when `in_progress` | |
| `completed_at` | string (ISO date) | when `done` | |
| `status_changed_at` | string (ISO timestamp) | no | Audit trail for status transitions. |
| `deferred_reason` | string | when `deferred` | |
| `blocked_on` | string | when `blocked` | |

## `blocked` and `open_questions`

- `blocked[]`: `{ "id", "title", "blocked_on", "since" }`
- `open_questions[]`: `{ "q", "asked_at", "resolved_at?", "resolution?" }`

## Minimal starter `state.json`

This example passes `state-validate` with zero errors and zero warnings — paste it,
edit the strings, and you have a valid starting point:

```json
{
  "schema_version": 1,
  "objective": "Ship v1 of the widget service",
  "objective_set_at": "2026-01-01",
  "version": "0.1.0-dev",
  "current_focus": "Scaffolding the project and writing the first endpoint",
  "deliverables": [
    {
      "id": "project-scaffold",
      "title": "Project scaffold and CI",
      "status": "in_progress",
      "version": "0.1.0",
      "started_at": "2026-01-01"
    }
  ],
  "blocked": [],
  "open_questions": [],
  "last_updated": "2026-01-01T00:00:00Z"
}
```

## Hook knobs — `hooks-config.json` (project and user level)

Optional. A JSON file that overrides the knobs of the shipped hooks, read from
two places:

- **Project level:** `.claude/hooks-config.json` at the project root.
- **User level:** `~/.claude/hooks-config.json` (or
  `$CLAUDE_CONFIG_DIR/hooks-config.json` when that variable is set) — one file
  for every project on the machine.

Unknown keys are ignored; a missing file means the next layer applies.

| Key | Type | Default | Env override | Controls |
|-----|------|---------|--------------|----------|
| `focus_check_every` | integer ≥ 1 | `6` | `FOCUS_CHECK_EVERY` | How often (in user prompts) `focus-check` re-injects the objective. |
| `focus_check_disable` | boolean | `false` | `FOCUS_CHECK_DISABLE=1` | Disable the `focus-check` hook entirely. |
| `state_track_pattern` | string (regex) | *(see below)* | `STATE_TRACK_PATTERN` | Commit-subject keyword regex (extended POSIX ERE) that makes `state-track-commit` suggest a state update. The built-in default matches subjects containing `ship`/`shipped`/`release`/`released`/`complete`/`completed`/`done`/`finish`/`finished`/`deliver`/`delivered`, or a version tag like `v1.2`. |
| `handoff_nudge_tokens` | integer ≥ 1 | *(none — off)* | `STATE_HANDOFF_NUDGE_TOKENS` | **Arms** the handoff nudge's transcript-size token fallback and sets its threshold. Deliberately no default — see the note in the handoffs section. `150000` ≈ the old 200K-window behavior; `750000` for 1M windows. Setting this at user level is the intended way to opt in machine-wide. |
| `handoff_nudge_pct` | integer ≥ 1 | `75` | `STATE_HANDOFF_NUDGE_PCT` | The handoff nudge's exact-% threshold (used when a session-status file provides the real context %). |
| `handoff_nudge_disable` | boolean | `false` | `STATE_HANDOFF_NUDGE_DISABLE=1` | Disable the handoff-pressure nudge only. |

Precedence per knob: the hook's environment variable **if set** (even set-empty —
a set variable owns its knob), then the project file, then the user-level file,
then the built-in default. The merge is per key, so a project file that sets only
one knob still inherits the rest from the user level — and a project can override
a user-level value in either direction (e.g. `"handoff_nudge_disable": false`
re-enables the nudge in one repo against a user-level `true`).
(`STATE_TRACK_DISABLE=1` also exists, env-only, to turn off
`state-track-commit` entirely.)

## Session handoffs — `.claude/handoffs/`

`/claude-state-drift:handoff` parks a narrative handoff at `.claude/handoffs/latest.md`
(plus a timestamped copy under `.claude/handoffs/archive/`). The bundled
`state-handoff` tool writes the file: the frontmatter is machine-written, the body is
the session's narrative. `state-handoff write` also keeps the directory gitignored
(appending a `handoffs/` entry to `.claude/.gitignore` when needed).

| Frontmatter field | Meaning |
|---|---|
| `project_path` | Absolute path of the project the handoff belongs to. A handoff whose `project_path` doesn't match the current project is never embedded — a one-line warning renders instead. |
| `composed_at` | UTC timestamp of composition. |
| `session_id` | Id of the composing session. |
| `state_last_updated` | `state.json`'s `last_updated` at compose time. |

**Supersession rule:** the next session's orientation embeds `latest.md` only while it
is *fresher* than `state.json`. As soon as `state.json`'s `last_updated` moves past
`composed_at` (with a 5-second tolerance, because the handoff flow updates state
first), or a newer handoff lands, orientation renders plain again. The rendered body
is truncated at the last complete line before 6 KB and always appears inside an
explicit untrusted-content boundary — briefing data, not instructions.

**Nudge knobs:** `STATE_HANDOFF_NUDGE_PCT` (default `75`, exact-% threshold),
`STATE_HANDOFF_NUDGE_TOKENS` (no default — unset means the transcript-size
fallback is off), `STATE_HANDOFF_NUDGE_DISABLE=1` (turn the nudge off). Each has
a `hooks-config.json` twin (`handoff_nudge_pct` / `handoff_nudge_tokens` /
`handoff_nudge_disable` — see the hook-knobs section above), settable per project
or once machine-wide in `~/.claude/hooks-config.json`; a set env var still wins.
The nudge lives in the `focus-check` hook, so `FOCUS_CHECK_DISABLE=1` disables it
as well.

**Why the token fallback is opt-in:** the exact-% path knows the real context-window
size, but a `UserPromptSubmit` hook otherwise cannot learn it — neither the hook input
nor the transcript records the window, and model identity doesn't determine it (the
same model runs 200K and 1M windows). An absolute-token default calibrated to a 200K
window fires ~5x early on a 1M-window session, so the fallback only arms when you set
the threshold yourself — `handoff_nudge_tokens` in `~/.claude/hooks-config.json`
(machine-wide) or `.claude/hooks-config.json` (per project), or the
`STATE_HANDOFF_NUDGE_TOKENS` env var (e.g. `150000` for 200K-window sessions — the
old default — or `750000` for 1M).
