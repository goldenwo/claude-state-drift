---
name: re-anchor
description: Drift-mitigation skill. Re-reads the project's master objective from `.claude/state.json` and audits the current session's recent work for alignment. Use after a long stretch (>30 minutes of intensive work, or many tool calls without checking back), when noticing scope drift, before declaring a task done, or when the user asks to "re-anchor", "check we're on track", "sanity check direction", "are we still on the right path". Reports a short alignment audit; does not modify state.
allowed-tools: Read, Bash(git log:*), Bash(git status), Bash(where-am-i:*), Bash(python:*)
---

# re-anchor

Pause, re-read the master objective, audit the current session's recent work for alignment, report. Inspired by Reflexion's "re-pass the original task each iteration" pattern.

## When to invoke

- After ~30+ minutes of intensive work without checking back to the objective.
- When noticing scope drift mid-session (extra refactors, shaving yaks, exploratory rabbit holes).
- Before declaring a task complete — sanity-check that what was built is what was asked for.
- On user request: "re-anchor", "check we're on track", "are we still on the right path", "sanity check direction".
- After resuming a session that was paused for hours/days.

This skill is read-only and side-effect-free. It does NOT modify state.json — that's `update-state`'s job.

## Procedure

1. **Re-read the master objective.** `Read .claude/state.json` and extract `objective`, `version`, `current_focus`, and the IDs of `in_progress` deliverables.

2. **Inspect recent work.** Recent assistant turns (the last 10-20 messages of the session), `git log --oneline -10`, `git status` for uncommitted changes. Identify what was actually worked on.

3. **Compare and assess.** Produce a short audit with this structure:

   ```
   === RE-ANCHOR AUDIT ===
   Original objective: <verbatim from state.json>
   Current version:    <state.version>
   State.json current_focus: <verbatim>
   In-progress deliverables: <list of titles>

   Recent work (this session): <one-paragraph summary of what was actually done>

   Drift assessment: <on-track | mild | significant>
   - On-track: recent work directly advances in-progress deliverables AND current_focus
   - Mild: recent work is adjacent (e.g., refactor that supports the deliverable) but not on the critical path
   - Significant: recent work is unrelated to the objective; new scope discovered or attention captured elsewhere

   Recommendations:
   - <one to three concrete next moves>
   ```

4. **Stop. Print the audit.** Do not auto-update state.json — if changes are warranted, the user invokes `update-state` next.

## Drift patterns to look for

- **Scope creep**: new sub-deliverables added in-session that aren't in state.json's `deliverables[]`. Flag for explicit add-or-defer decision.
- **Yak shaving**: long detours into adjacent fixes (refactoring a helper, fixing a peripheral bug) that don't advance the in-progress item. Flag for "back to main task" or "new deliverable: X" decision.
- **Premature optimization**: optimizing things not on the critical path. Cite YAGNI.
- **Tool-use loops**: many sequential reads/greps without making progress. Possible context confusion — recommend asking the user a clarifying question.
- **Context-rot dilution** (HumanLayer's term): the agent has been making progress but the original ask is no longer in the context window. The audit itself re-anchors by re-stating the objective.

## What this skill does NOT do

- Does not modify state.json. Use `update-state` for that.
- Does not undo work or roll back changes. The audit is informational.
- Does not interrupt the session — it's invoked on demand or at the agent's own initiative.
- Does not replace tests/lint/CI. Those check correctness; this checks alignment.

## Anti-patterns

- Invoking re-anchor every few minutes. The point is occasional re-anchoring, not constant interruption.
- Producing a long audit report. The format above is a tight one-screen output. Longer = ignored.
- Recommending action without flagging the drift category. "On-track" is a valid recommendation; so is "Significant: stop and discuss with user."
- Treating mild drift as a problem. Adjacent work that supports the deliverable IS progress. Only flag when the work is actually divergent.

## Schema reference

State.json schema in `SCHEMA.md`. The objective field is the master vision — re-read at every invocation. Other fields (deliverables, current_focus) provide the alignment basis.
