---
description: Print a "WHERE YOU ARE" orientation block for the current project — objective, version, current focus, in-progress deliverables, deferred items, blocked items, open questions, recent commits, and recent snapshots. Use when you need a quick project-state overview at the start of a session or after context switches.
allowed-tools: Bash(where-am-i:*), Bash(python:*)
---

Run `where-am-i` (on PATH when the plugin is active) against the current project. The tool reads `.claude/state.json` + recent `git log` + recent snapshot entries, then prints the orient block to stdout.

If `.claude/state.json` doesn't exist in the current project, the tool silently skips (no enforcement on uninstrumented projects).
