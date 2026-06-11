# claude-state-drift

[![ci](https://github.com/goldenwo/claude-state-drift/actions/workflows/ci.yml/badge.svg)](https://github.com/goldenwo/claude-state-drift/actions/workflows/ci.yml)

State-tracking and drift-mitigation for [Claude Code](https://docs.claude.com/en/docs/claude-code).

Long agent sessions lose the plot: the original goal scrolls out of context, scope
creeps, and you drift far from where you meant to be. `claude-state-drift` keeps a
small, human-readable `.claude/state.json` per project — the objective, the current
focus, and the deliverables — and continuously surfaces it so every session stays
anchored.

## What it does

- **Orientation on every session start.** A `SessionStart` hook prints a "WHERE YOU
  ARE" block: objective, version, current focus, in-progress / deferred / blocked
  deliverables, and recent commits.
- **Drift checks while you work.** A `UserPromptSubmit` hook (`focus-check`) re-injects
  the objective and current focus every few prompts so the goal never fully leaves
  context.
- **Staleness nudges.** A `Stop` hook flags when `state.json` looks out of date
  relative to recent work, and a `PostToolUse` hook notices commits whose subject
  suggests a deliverable transition.
- **Commands + skills to manage state:**
  - `/where-am-i` — print the orientation block on demand.
  - `/update-state` — draft a reviewed edit to `state.json` after meaningful progress.
  - `/re-anchor` — audit the current session against the objective and report drift.

## Install

```
/plugin marketplace add goldenwo/claude-state-drift
/plugin install claude-state-drift
```

## The `state.json` model

The whole system revolves around one file, `.claude/state.json`:

- `objective` — the master vision; rarely changes.
- `current_focus` — one sentence on what you're doing right now.
- `deliverables[]` — units of work, each with a `status` (`done` / `in_progress` /
  `deferred` / `blocked`).

See [SCHEMA.md](SCHEMA.md) for the full schema, a copy-paste starter file, and the
optional per-project `.claude/hooks-config.json` knobs. Validate any state file with
the bundled `state-validate` tool.

## License

MIT — see [LICENSE](LICENSE).

## This repo is a generated mirror

Every byte here — including the CI workflow — is emitted by the (private)
`claude-harness-toolkit`'s build from a pinned toolkit commit (see
`.build-provenance`). CI re-runs that build from the pin and fails on any
difference, so **hand-edits to this repo are rejected by design**: pull
requests that touch files will fail the regeneration-drift gate. Bug reports
and feature requests are welcome as issues; fixes land in the toolkit source
and arrive here via a regenerated release.

