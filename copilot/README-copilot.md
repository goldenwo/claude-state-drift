# claude-state-drift — GitHub Copilot CLI

This directory adds Copilot CLI support to `claude-state-drift`. The same
`.claude/state.json` that drives Claude Code's orientation blocks is read by two
Copilot hooks — one at session start, one after each tool call — so project state
surfaces in the same way across both tools.

## Install

claude-state-drift installs as a Copilot plugin from its marketplace:

```bash
copilot plugin marketplace add goldenwo/claude-state-drift
copilot plugin install claude-state-drift@claude-state-drift
```

`marketplace add` registers this repo as a Copilot plugin marketplace; `plugin
install` installs the plugin — its `sessionStart` and `postToolUse` hooks plus the
`update-state` and `re-anchor` skills — caching it under
`~/.copilot/installed-plugins/`. To remove:

```bash
copilot plugin uninstall claude-state-drift
copilot plugin marketplace remove claude-state-drift
```

**Windows:** Copilot runs the PowerShell hook variant natively — no git-bash is
needed. `where-am-i` is a Python script, so make sure Python is on your `PATH`
(`py`, `python3`, or `python`); without it the orientation hook stays silent. On
Linux/macOS the hooks run under bash and also use `jq`.

## What the Copilot CLI port does (mechanism)

### Full tier — Copilot CLI

Copilot CLI supports two hooks that inject `additionalContext` into the model:

| Hook | Copilot event | What it runs |
|---|---|---|
| `sessionStart` | Session opens | `orient-hook.sh` / `orient-hook.ps1` reads `.claude/state.json` and emits the "WHERE YOU ARE" orientation block as `additionalContext`. Silent when no `state.json` is present. |
| `postToolUse` | After each tool call | `transition-hook.sh` / `transition-hook.ps1` reads the tool call's stdin payload. When the call is a `git commit` whose subject contains a transition keyword (ship, release, complete, done, finish, deliver, or a version tag), it emits a nudge pointing at the `update-state` skill. Silent for all other tool calls. |

Two skills are also installed and discoverable by Copilot's skill search:

| Skill | What it does |
|---|---|
| `update-state` | Drafts an edit to `.claude/state.json` based on recent work and shows the diff. Never auto-writes — you approve every change. |
| `re-anchor` | Audits the current session against the project objective and reports alignment. |

Invoke them via `/update-state` or `/re-anchor` in the Copilot CLI prompt, or ask
in plain words.

**What Copilot CLI does NOT inject** (by design — verified against live docs):

- `userPromptSubmitted` — Copilot CLI does not inject `additionalContext` for this
  hook. The focus-check re-injection from the Claude Code port is therefore not
  available in Copilot CLI.
- `agentStop` — block-only; no injection.

Both gaps are covered by the Lite tier below.

### Lite tier — Copilot in IDE (static AGENTS.md only)

Copilot in the IDE (VS Code, JetBrains, etc.) does not run session-start hooks or
inject `additionalContext`. The only mechanism available is a static instruction
file read at the start of each request.

To use it: paste the contents of `copilot/AGENTS.snippet.md` into your project's
`AGENTS.md` (or `.github/copilot-instructions.md`). This places the objective and
`current_focus` pointer in every request's context as a static instruction — no
session-start injection, no hook-driven nudges.

## After install

1. Start a Copilot CLI session in a project that has a `.claude/state.json`.
   The orientation block appears at session start via the `sessionStart` hook.
2. Optionally paste `copilot/AGENTS.snippet.md` into your project's `AGENTS.md`
   to anchor the objective in every request (covers the hooks that cannot inject).
3. Use `/update-state` or `/re-anchor` on demand to update project state or check
   session alignment.

## What it costs

The `sessionStart` hook runs `where-am-i` once at session start and emits the
orientation block as `additionalContext` — the same token range as the Claude Code
port (~700–2,000 tokens depending on `state.json` size). The `postToolUse` hook
reads the tool call payload via stdin and exits silently on non-commit calls;
on matched commits it emits a short nudge (~50 tokens). No network access. No
data leaves your machine. Cost details and token breakdowns are in the root
[README.md](../README.md).

## Honesty note

This documentation describes the mechanism: what each hook reads, what it emits,
and what the model receives. It does not make claims about outcomes such as "keeps
you on track" or "prevents drift" — those depend on how the model uses the
injected context, which this tool does not control.
