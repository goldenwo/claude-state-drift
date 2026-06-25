# claude-state-drift — OpenAI Codex CLI

This directory adds Codex CLI support to `claude-state-drift`. The same
`.claude/state.json` that drives Claude Code's orientation blocks is read by Codex
lifecycle hooks, so project state surfaces the same way across both tools.

## Install

claude-state-drift installs as a Codex plugin from its marketplace:

```bash
codex plugin marketplace add goldenwo/claude-state-drift
codex plugin add claude-state-drift@claude-state-drift
```

`marketplace add` registers this repo as a Codex plugin marketplace; `plugin add`
installs and enables the plugin — its four lifecycle hooks plus the `update-state` and
`re-anchor` skills — caching it under `~/.codex/plugins/cache/`. On first run Codex
asks you to trust the plugin's hooks; approve them. To remove:

```bash
codex plugin remove claude-state-drift@claude-state-drift
```

**Windows:** the hooks are bash scripts, so the plugin runs them through **git-bash**,
which it locates automatically from your `git` installation — make sure
[Git for Windows](https://gitforwindows.org/) is installed. (Codex spawns bare `bash`,
which on Windows can resolve to the WSL launcher rather than git-bash; the plugin's
`commandWindows` launcher resolves git-bash explicitly so the hooks run.)

## What the Codex CLI port does (mechanism)

### Full tier — Codex CLI

Codex supports lifecycle hooks that inject `additionalContext` into the model. This
port registers four:

| Hook | Codex event | What it runs |
|---|---|---|
| Orientation | `SessionStart` | `session-start-orient.sh` reads `.claude/state.json` and emits the "WHERE YOU ARE" block. Silent when no `state.json`. |
| Commit-transition | `PostToolUse` (matcher `Bash`) | `state-track-commit.sh` — when a `git commit` subject contains a transition keyword (ship, release, complete, done, finish, deliver, or a version tag), emits a nudge pointing at the `update-state` skill. Silent otherwise. |
| Focus re-inject | `UserPromptSubmit` | `focus-check.sh` re-emits the objective + current focus every Nth prompt (default 6). |
| Staleness / bloat | `Stop` | `state-staleness.sh` flags a stale or bloated `state.json` at session end. |

Two skills ship with the plugin and are discoverable by Codex:

| Skill | What it does |
|---|---|
| `update-state` | Drafts an edit to `.claude/state.json` and shows the diff. Never auto-writes. |
| `re-anchor` | Audits the current session against the objective and reports alignment. |

Invoke them via `/update-state` / `/re-anchor`, `$update-state`, or in plain words.

### Lite tier — Codex in IDE / no git-bash (static AGENTS.md only)

Where lifecycle hooks don't run, paste the contents of `codex/AGENTS.snippet.md`
into your project's `AGENTS.md`. Codex reads `AGENTS.md` natively, placing the
objective and `current_focus` pointer in context — no hook-driven injection.

## What it costs

The `SessionStart` hook runs `where-am-i` once and emits the orientation block
(~700–2,000 tokens depending on `state.json` size). `PostToolUse` reads each tool
call via stdin and exits silently on non-commit calls; matched commits emit a short
nudge (~50 tokens). `UserPromptSubmit` emits the focus block every Nth prompt; `Stop`
emits at most one staleness nudge per session. No network access; nothing leaves your
machine. Details in the root [README.md](../README.md).

## Honesty note

This documentation describes the mechanism: what each hook reads, what it emits, and
what the model receives. It makes no claims about outcomes such as "keeps you on
track" — those depend on how the model uses the injected context, which this tool
does not control.
