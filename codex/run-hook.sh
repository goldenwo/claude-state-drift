#!/usr/bin/env bash
# run-hook.sh — Codex CLI hook launcher for claude-state-drift.
# Codex invokes: bash <INSTALL_DIR>/run-hook.sh <hook-filename>
# Sets CLAUDE_PLUGIN_ROOT to its own dir so session-start-orient.sh resolves
# bin/where-am-i, then execs the real hook (stdin flows through).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export CLAUDE_PLUGIN_ROOT="$ROOT"
exec bash "$ROOT/hooks/$1"
