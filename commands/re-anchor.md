---
description: Drift mitigation — re-read project objective from .claude/state.json and audit the current session for alignment. Use when you sense scope drift, after long stretches of work, or before declaring a task done. Reports an alignment audit; does not modify state.
allowed-tools: Read, Bash(git log:*), Bash(git status), Bash(where-am-i:*), Bash(python:*)
---

Invoke the Skill tool with `claude-harness-toolkit:re-anchor` against the current project. Do not inline or paraphrase the procedure — defer to the skill for the full contract (objective re-read → recent-work audit → alignment categories on-track/mild/significant → handoff to `update-state` if needed).

If `.claude/state.json` doesn't exist in the current project, report that and skip the audit (no enforcement on uninstrumented projects).
