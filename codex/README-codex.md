# claude-state-drift — OpenAI Codex CLI

This directory adds Codex CLI support to `claude-state-drift`. The same
`.claude/state.json` that drives Claude Code's orientation blocks is read by Codex
lifecycle hooks, so project state surfaces the same way across both tools.

## Install

From the root of the `claude-state-drift` distribution:

```bash
bash codex/install.sh
```

On Windows you can also run `pwsh codex/install.ps1` (it locates git-bash and
delegates — the hooks themselves run via bash). Both are idempotent. To remove:

```bash
bash codex/install.sh --uninstall      # or: pwsh codex/install.ps1 -Uninstall
```

The installer copies the hooks, the `where-am-i` helper, and a launcher into
`~/.codex/state-drift/`, copies the `update-state` and `re-anchor` skills into
`~/.agents/skills/`, and merges four hook entries into `~/.codex/hooks.json`
(existing hooks are preserved). On first run, Codex asks you to trust the hooks —
approve them via `/hooks`.

## What the Codex CLI port does (mechanism)

### Full tier — Codex CLI

Codex supports lifecycle hooks that inject `additionalContext` into the model. This
port registers four:

| Hook | Codex event | What it runs |
|---|---|---|
| Orientation | `SessionStart` | `session-start-orient.sh` reads `.claude/state.json` and emits the "WHERE YOU ARE" block. Silent when no `state.json`. |
| Commit-transition | `PostToolUse` (matcher `Bash`) | `state-track-commit.sh` — when a `git commit` subject contains a transition keyword (ship, release, complete, done, finish, deliver, or a version tag), emits a nudge pointing at the `update-state` skill. Silent otherwise. |
| Drift re-inject | `UserPromptSubmit` | `focus-check.sh` re-emits the objective + current focus every Nth prompt (default 6). |
| Staleness / bloat | `Stop` | `state-staleness.sh` flags a stale or bloated `state.json` at session end. |

Two skills are installed into `~/.agents/skills/` and discoverable by Codex:

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
