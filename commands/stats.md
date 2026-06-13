---
description: Show this project's claude-state-drift telemetry — sessions, per-injection token cost, activity counts, nudge-to-update conversion, and staleness-resolution — computed locally from the opt-in hook log. Use when you want to see what the plugin is doing and what it costs, or to check your own numbers.
allowed-tools: Bash(where-am-i:*), Bash(python:*)
---

Run `where-am-i --stats` (on PATH when the plugin is active) against the current project. It reads the local `.claude/.hook-log.jsonl` (present only when `CLAUDE_HOOK_LOG=1` is set) plus `.claude/state-history.jsonl`, and prints an operational stats block: reach (sessions + window), activity (orientations, focus re-injections, commit and staleness nudges), cost (token estimate p50/p95), nudge-to-update conversion, and staleness-resolution. Pass `--stats --json` instead for a machine-readable form. Everything is computed on the user's machine; nothing is sent anywhere.

If the hook log is absent, the block says "no telemetry yet" — tell the user to set `CLAUDE_HOOK_LOG=1` and run some sessions first so data can accumulate. These are operational metrics (activity + cost), not an effectiveness measure.
