---
name: update-state
description: Draft an update to `<project>/.claude/state.json` based on recent work and show the diff. Triggers on substantial progress (new in-progress deliverable, transition to done, new deferral, resolved open question, blocked item); user phrases like "update state", "log progress", "snapshot where we are", "checkpoint"; natural-language signals "we just shipped X", "Y is done", "Z is blocked", "marking W deferred", "moving on to V", "X is complete"; a commit landing whose subject mentions ship/release/complete/done/finish/deliver/vX.Y when `.claude/state.json` wasn't in the commit (surfaced by the `state-track-commit.sh` hook). Inspects current state.json + git diff/log + recent session intent; produces a precise edit. Never auto-writes — shows the diff, waits for approval.
allowed-tools: Read, Bash(git status), Bash(git diff:*), Bash(git log:*), Bash(where-am-i:*), Bash(python:*), Bash(state-validate:*), Bash(state-history:*), Edit, Write
---

# update-state

Draft a precise edit to `.claude/state.json` and stop. Do not auto-write.

## When to invoke

- After substantial work in the session: a deliverable shipped, a new one started, scope deferred, an open question resolved.
- When the user asks to "update state", "log progress", "snapshot where we are", "checkpoint".
- Before declaring a major task done — so the state.json catches up to reality.

Skip for trivial updates (typo fixes, single-line refactors). Trust the SessionStart auto-orientation; only intervene when meaningful state changes.

## Procedure

1. **Read current state.** `Read .claude/state.json`. If absent, create the initial scaffold per `SCHEMA.md` (ask the user for `objective` + `version` + first `current_focus` if needed).

2. **Inspect what's changed.**
   - `git status` and `git diff --cached` for staged work.
   - `git log --since="<last_updated value>" --oneline` for commits since the last state update (ISO timestamp goes after `--since=`; do NOT use `<ts>..HEAD` syntax — that's for refs, not timestamps).
   - Re-read recent assistant turns / TodoWrite list to spot status changes the agent itself made.

3. **Detect candidate transitions.**
   - In-progress deliverables that look done (commits/PRs landed, tests pass, files exist as planned) → propose `status: done` + `completed_at: <today>`.
   - New work not in `deliverables[]` → propose new entry. Ask the user for `id`, `title`, `version` (or infer from current focus / commits).
   - Open questions resolved by recent work → propose `resolved_at` + `resolution`.
   - New deferrals discovered (scope explicitly punted) → propose new deliverable with `status: deferred` + `deferred_reason`.
   - Items waiting on external factor → `status: blocked` with `blocked_on` + `since`.

4. **Draft the diff.** Compose a single `Edit` that updates `.claude/state.json`:
   - Always update `last_updated` to current ISO timestamp.
   - Update `current_focus` if it's stale.
   - Apply the deliverable/question changes from step 3.
   - Preserve order and formatting (2-space indent, trailing newline).

5. **Show the user.** Print a one-paragraph plain-English summary of the proposed changes (what's transitioning to what, what's new, what's resolved). Then show the actual `Edit` block ready to apply. **Wait for approval.**

6. **On approval, apply.** Run the `Edit` tool. Then **run `state-validate` (on PATH while the plugin is enabled) to verify the write produced a schema-valid state.json**. If validate reports errors, fix them before continuing (the diff likely missed a required field or has a malformed timestamp). Confirm with `where-am-i` to show the new orientation block.

7. **Status-transition tracking.** When changing a deliverable's `status` field, also set `status_changed_at` to the current ISO timestamp. This is the audit trail for "when did X transition" queries.

8. **Append to the deliverable-history log.** After the state.json `Edit` + `state-validate` pass, for **each** deliverable whose `status` changed — and each **newly added** deliverable — append one transition record to the append-only companion log `.claude/state-history.jsonl`:

   ```
   state-history append --id <deliverable_id> --from <old_status> --to <new_status>
   ```

   Use `--from none` for a brand-new deliverable that had no prior status. (Optionally pass `--ts <iso>` / `--session <id>`; both default sensibly — `ts` to now-UTC, `session` to `$CLAUDE_SESSION_ID` or `"unknown"`.) The log is a **companion** to state.json — append-only, NOT part of `state.json`, and **NOT validated by `state-validate`**. It answers "which session moved deliverable X from in_progress → done, and when?"; surface it later via `where-am-i --history <id>`. Treat the append as **best-effort**: if it fails, do NOT roll back or block the state update — the state.json write is the source of truth; the history line is an audit augment. (The skill's `allowed-tools` already permits `Bash(state-history:*)`.)

## Anti-patterns

- Marking work `done` without verification (tests pass? commit landed? file exists?). When uncertain, ask the user.
- Bulk-rewriting state.json from scratch — preserve existing entries; only edit what changed.
- Inventing new deliverables to make progress look better. Every new entry must trace to actual work.
- Auto-writing without showing the diff. The skill exists to surface intent; the user owns the write.
- Updating `objective` without explicit user confirmation. The objective is the master vision — changing it is a deliberate act, not a side-effect.

## Schema reference

Canonical schema in `SCHEMA.md` (`.claude/state.json` section). **Validate any write via `state-validate`** (stdlib-only checker; exit 0 = valid, 1 = errors). Quick reference:

```json
{
  "schema_version": 1,
  "objective": "string (master vision)",
  "objective_set_at": "ISO date",
  "version": "string (current target, e.g. 0.3.0-dev)",
  "current_focus": "string (one sentence)",
  "deliverables": [
    {
      "id": "kebab-case-unique",
      "title": "Human-readable",
      "status": "done|in_progress|deferred|blocked",
      "version": "string (target version, no -dev suffix typical)",
      "started_at": "ISO date (in_progress)",
      "completed_at": "ISO date (done)",
      "status_changed_at": "ISO timestamp (auto-populated by this skill on any status transition)",
      "deferred_reason": "string (deferred)",
      "blocked_on": "string (blocked)"
    }
  ],
  "blocked": [{"id", "title", "blocked_on", "since"}],
  "open_questions": [{"q", "asked_at", "resolved_at?", "resolution?"}],
  "last_updated": "ISO timestamp"
}
```

## Per-project overrides

If `.claude/state-style.md` exists, follow its conventions for: `id` naming scheme, `version` format, additional fields (e.g., `owner`, `priority`, `effort_estimate`), or skip-conditions. Default style is the canonical schema above.
