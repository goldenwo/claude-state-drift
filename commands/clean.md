---
description: Keep state.json lean by archiving old done deliverables -- dry-run first, confirm, then apply. Use when state.json feels bloated or the state-bloat nudge fires.
allowed-tools: Bash(state-clean:*), Bash(python:*)
---

Archive stale `done` deliverables out of `.claude/state.json` to keep it lean, using the propose-then-apply pattern (never a blind write).

1. Run `state-clean` (dry-run — no flags) against the current project. It prints which `done` deliverables are old enough to archive; it keeps the most-recent N plus everything in-progress / deferred / blocked, open questions, and the current focus.
2. Show the user that list and the counts. If nothing is archivable, say so and stop.
3. Ask the user to confirm. Offer to tune `--keep N` (default 10 most-recent done kept) or `--older-than DAYS` (default 30) if they want a different cut.
4. Only after explicit approval, run `state-clean --apply` (with any agreed flags). Archived entries go to an append-only `.claude/state-archive.jsonl`; git is the backstop, so it is reversible.
5. Confirm what was archived. (Note: `state-clean` does not touch `last_updated` — it is housekeeping, not a state change.)

Never run `--apply` before the user has seen the dry-run and approved. `state-clean` is on the Bash tool's PATH while the plugin is enabled.
