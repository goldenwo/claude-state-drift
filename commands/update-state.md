---
description: Draft an update to `.claude/state.json` based on recent work and show the diff. Use when substantial progress has been made (deliverable shipped, new work started, scope deferred, open question resolved), or when the user says "update state", "log progress", "snapshot where we are", or "checkpoint". Never auto-writes — shows the diff and waits for approval.
allowed-tools: Read, Bash(git status), Bash(git diff:*), Bash(git log:*), Bash(where-am-i:*), Bash(python:*), Bash(state-validate:*), Edit, Write
---

Invoke the Skill tool with `claude-state-drift:update-state` against the current project. Do not inline or paraphrase the procedure — defer to the skill for the full contract (inspect current state + detect candidate transitions + draft a precise edit + show diff + wait for approval + validate after write).

If `.claude/state.json` doesn't exist in the current project, report that and skip (no enforcement on uninstrumented projects).
