# claude-state-drift

[![ci](https://github.com/goldenwo/claude-state-drift/actions/workflows/ci.yml/badge.svg)](https://github.com/goldenwo/claude-state-drift/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/goldenwo/claude-state-drift)](https://github.com/goldenwo/claude-state-drift/releases)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

State-tracking and drift-mitigation for [Claude Code](https://docs.claude.com/en/docs/claude-code).
Every session opens with your project's actual state — not a cold start:

```
=== WHERE YOU ARE ===
Project: my-api
Version: 1.4.0 | Objective: Ship the v2 billing pipeline with usage-based invoicing
Focus:   Webhook retry queue done; now wiring the invoice-preview endpoint
In progress: invoice-preview-endpoint
Deferred:    csv-export (until billing v2 ships)
Recent: 3 commits today, last: "Add retry backoff to webhook queue"
```

Long agent sessions measurably lose the plot: models retrieve worst from the middle of
long inputs ([Liu et al., TACL 2024](https://arxiv.org/abs/2307.03172)), grow
unreliable as inputs lengthen ([Chroma, 2025](https://www.trychroma.com/research/context-rot)),
and drift from their goal as context grows ([Arike et al., 2025](https://arxiv.org/abs/2505.02709)).
`claude-state-drift` keeps a small, human-readable `.claude/state.json` per project and
continuously re-surfaces it so the goal never depends on what's still in context.

## Highlights

- **Orientation on every session start** — the "WHERE YOU ARE" block above, generated
  from your project's real state.
- **Drift checks while you work** — the objective and current focus are re-injected
  every few prompts, so the goal never fully leaves context.
- **Staleness nudges** — get flagged when `state.json` looks out of date relative to
  recent work, or when a commit looks like it finished a deliverable.
- **Three commands** — `/where-am-i`, `/update-state` (drafts a reviewed state edit;
  never auto-writes), `/re-anchor` (audits the session against the objective).

## Install

```
/plugin marketplace add goldenwo/claude-state-drift
/plugin install claude-state-drift
```

Then drop a starter `.claude/state.json` into your project — copy one from
[SCHEMA.md](SCHEMA.md) — and start a session. Uninstall any time with
`/plugin uninstall claude-state-drift`.

## How it works

Four hooks and three commands, all reading one file:

```mermaid
flowchart LR
    S[(".claude/state.json")] -->|SessionStart| O["WHERE YOU ARE<br/>orientation block"]
    O --> W["you + Claude work"]
    W -->|"every N prompts"| F["focus-check<br/>re-injects the objective"]
    F --> W
    W -->|"commit lands"| C["state-track-commit<br/>spots deliverable transitions"]
    W -->|"session ends"| Z["state-staleness<br/>flags stale state"]
    C --> U["/update-state<br/>reviewed edit, never auto-writes"]
    Z --> U
    U --> S
```

- A `SessionStart` hook prints the orientation block.
- A `UserPromptSubmit` hook (`focus-check`) re-injects the objective on a cadence you
  can tune per project (`.claude/hooks-config.json`).
- A `Stop` hook flags stale state; a `PostToolUse` hook notices commits whose subject
  suggests a deliverable transition and points you at `/update-state`.
- Everything is computed from local files and local git.

## With and without

No magic — just the difference between state that lives in a file and state that
lives in a scrolling context window:

| Moment | With claude-state-drift | Without |
|---|---|---|
| Session start | Orientation block from your real project state | Cold start; you re-explain or the agent re-derives |
| 40 prompts in | Objective re-injected on a cadence; still in context | Goal relies on whatever survived context compaction |
| After a milestone commit | Nudge to record the transition in `state.json` | Project state lives only in git archaeology |
| Next week's session | Picks up exactly where the file says you left off | Reconstruction from memory and scrollback |

## Built with itself

This plugin's own release pipeline was built while running the plugin — every
session opened by its orientation block, drift-checked by its own `focus-check`.
The receipts, as of June 2026: **50 deliverables tracked (49 shipped) and 69
commits across the six-phase milestone** that produced this repo, June 6–11 2026:

```mermaid
timeline
    title Six phases in six days — tracked in state.json the whole way
    2026-06-06 : Curation build engine : Content transforms + gates
    2026-06-07 : Emitted-cut validation : Clean-install acceptance
    2026-06-10 : Public repo + regeneration-drift CI
    2026-06-11 : v0.1.0 published
```

That's heavy real-world use, not a controlled study — a measured with/without
comparison is planned, and this section will carry the results when they exist.

## The `state.json` model

The whole system revolves around one file, `.claude/state.json`:

- `objective` — the master vision; rarely changes.
- `current_focus` — one sentence on what you're doing right now.
- `deliverables[]` — units of work, each with a `status` (`done` / `in_progress` /
  `deferred` / `blocked`).

See [SCHEMA.md](SCHEMA.md) for the full schema, a copy-paste starter file, and the
per-project `.claude/hooks-config.json` knobs. Validate any state file with the
bundled `state-validate` tool.

## Requirements

- Claude Code with plugin support.
- `bash`, `git`, `jq`, and Python 3 (found automatically as `py`, `python3`, or
  `python` — no configuration needed).
- CI-verified on Linux and Windows (git-bash). macOS is expected to work (the hooks
  are POSIX bash) but is not currently CI-covered.

## Troubleshooting

- **No orientation block at session start?** Your project has no `.claude/state.json`
  (the plugin stays silent rather than nagging) or the file is invalid — run the
  bundled `state-validate` to check it.
- **Focus-check fires too often / not often enough?** Set the cadence in
  `.claude/hooks-config.json` — see [SCHEMA.md](SCHEMA.md).
- **Does anything leave my machine?** No. All signals are computed from local files
  and local git; there is no network access, and nothing is sent anywhere.

## License

MIT — see [LICENSE](LICENSE).

## About this repo

This repo is generated: every byte — including the CI workflow — is built from a
pinned commit of a private source toolkit (see `.build-provenance`), and CI verifies
the tree byte-for-byte against a fresh rebuild on every push. **File issues here —
they're read and acted on.** Fixes land in the source toolkit and ship in the next
release, which is why pull requests against this repo can't be merged directly.
