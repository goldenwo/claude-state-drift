---
name: handoff
description: "Compose an end-of-session handoff — updates state.json first (with approval), then writes a narrative handoff that the next session in this project auto-loads. Use at session end, when context runs high, when the user says 'write a handoff', 'wrap up', 'hand off', or after the context-pressure nudge fires."
allowed-tools: Read, Bash(git status), Bash(git log:*), Bash(git diff:*), Bash(where-am-i:*), Bash(python:*), Bash(state-handoff:*), Bash(state-validate:*), Bash(state-history:*), Edit, Write
---

# handoff

End the session cleanly: state.json catches up, then a narrative handoff is composed and parked for the next session. The NEXT session's orientation auto-loads it (same project only) until a newer handoff or state write supersedes it.

## Procedure

1. **Update state first.** Run the full `update-state` skill contract (draft → show diff → WAIT for approval → write → `state-validate` → `state-history` appends). If nothing material changed, say so and skip the write.
2. **Compose the narrative.** Write the handoff body in THIS session's voice — the things state.json deliberately excludes. Use exactly this shape:
   - `# Handoff — <date>: <one-line theme>`
   - `> **TL;DR:**` 2-3 sentences: where things stand + the single honest next move
   - `## Where we are` — commits/branches/PRs landed this session, working-tree state
   - `## What's NEXT` — the next move and why; an honest STOP if nothing validated remains
   - `## What's LEFT` — blockers, flakes, dangling threads, don't-re-attempt items
   - `## Resume notes` — gotchas, how-to-verify, carry-forward context
   Keep it under ~5KB — the orient render truncates at 6KB.
3. **Write it.** Save the body to a temp file, then:
   `state-handoff write --body-file <tmpfile>`
   (session id defaults from `CLAUDE_CODE_SESSION_ID`). Confirm the tool's output line to the user.
4. **Tell the user** the handoff is parked and will auto-load in the next session for this project.

## Anti-patterns
- Composing from the transcript summary instead of your live understanding (compaction-grade output).
- Writing the handoff WITHOUT the state update — the supersession rule keys on state.json freshness.
- Padding with content already in state.json (deliverable lists, version history) — the orient block carries those.
