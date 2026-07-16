---
description: Compose an end-of-session handoff -- state.json update (with approval) first, then a narrative handoff the next session in this project auto-loads. Use at session end, when context runs high, or after the context-pressure nudge fires.
allowed-tools: Read, Bash(git status), Bash(git log:*), Bash(git diff:*), Bash(state-handoff:*), Bash(state-validate:*), Bash(state-history:*), Edit, Write
---

Invoke the `claude-state-drift:handoff` skill against the current project. Follow the skill contract exactly: state update with approval first, then compose the narrative in this session's voice, then `state-handoff write --body-file <tmpfile>`. Confirm to the user that the handoff is parked and will auto-load in the next session for this project.
