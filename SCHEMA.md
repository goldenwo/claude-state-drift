# claude-state-drift — `.claude/state.json` schema

`claude-state-drift` keeps a small JSON file, `.claude/state.json`, at the root of
each project. It records the project's master objective, the current focus, and a
list of deliverables with their status. The hooks, commands, and skills in this
plugin read and surface that file to keep long Claude Code sessions anchored to
their goal.

This document is the canonical schema. Validate any `state.json` with the bundled
`state-validate` tool — it exits `0` when the file is valid.

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

## Per-project hook knobs — `.claude/hooks-config.json`

Optional. A per-project JSON file that overrides the knobs of the shipped hooks.
Unknown keys are ignored; a missing file means every hook uses its built-in default.

| Key | Type | Default | Controls |
|-----|------|---------|----------|
| `focus_check_every` | integer ≥ 1 | `6` | How often (in user prompts) `focus-check` re-injects the objective. |
| `focus_check_disable` | boolean | `false` | Disable the `focus-check` hook entirely. |
| `state_track_pattern` | string (regex) | *(see below)* | Commit-subject keyword regex (extended POSIX ERE) that makes `state-track-commit` suggest a state update. The built-in default matches subjects containing `ship`/`shipped`/`release`/`released`/`complete`/`completed`/`done`/`finish`/`finished`/`deliver`/`delivered`, or a version tag like `v1.2`. |

Precedence per knob: the hook's environment variable (if set) wins, then this file,
then the hook's built-in default.
