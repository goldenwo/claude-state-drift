#!/usr/bin/env bash
# install.sh — idempotent install/uninstall of claude-state-drift for OpenAI Codex CLI.
#
# Ships in the CUT at cut-root/codex/install.sh; sibling dirs: cut-root/{bin,hooks,skills}.
# Installs:
#   $CODEX_HOME/state-drift/run-hook.sh     — launcher
#   $CODEX_HOME/state-drift/hooks/          — the 4 lifecycle hooks + _python/_telemetry/_hooks_config
#   $CODEX_HOME/state-drift/bin/            — where-am-i + deps
#   $AGENTS_SKILLS_HOME/{update-state,re-anchor}/SKILL.md   — skills (Codex reads ~/.agents/skills)
# and MERGES 4 hook entries into $CODEX_HOME/hooks.json (existing hooks preserved).
#
# Usage: bash install.sh [--yes] [--uninstall]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AGENTS_SKILLS_HOME="${AGENTS_SKILLS_HOME:-$HOME/.agents/skills}"
INSTALL_DIR="$CODEX_HOME/state-drift"
HOOKS_JSON="$CODEX_HOME/hooks.json"
# Uniquely identifies OUR entries in a merged hooks.json. NO leading slash: jq 1.8.x
# `contains`/`index` mishandle a needle that starts with "/" (returns false even when
# present). "state-drift/run-hook.sh" is still unique to us and matches reliably.
MARK="state-drift/run-hook.sh"

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

YES=0; UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "install.sh: unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# --- Uninstall ---
if [ "$UNINSTALL" = "1" ]; then
  if [ "$YES" != "1" ]; then
    printf 'Remove claude-state-drift from %s? [y/N] ' "$CODEX_HOME"; read -r ans
    case "$ans" in [Yy]*) ;; *) echo "Aborted."; exit 0 ;; esac
  fi
  rm -rf "$INSTALL_DIR"
  rm -rf "$AGENTS_SKILLS_HOME/update-state" "$AGENTS_SKILLS_HOME/re-anchor"
  if [ -f "$HOOKS_JSON" ]; then
    tmp="$(mktemp)"
    jq --arg mark "$MARK" '
      .hooks = ((.hooks // {})
        | map_values(map(select(.hooks | map(.command // "" | contains($mark)) | any | not)))
        | with_entries(select(.value | length > 0)))
    ' "$HOOKS_JSON" > "$tmp" && mv "$tmp" "$HOOKS_JSON"
  fi
  echo "claude-state-drift uninstalled from $CODEX_HOME"
  exit 0
fi

# --- Install ---
if [ "$YES" != "1" ]; then
  printf 'Install claude-state-drift into %s? [Y/n] ' "$CODEX_HOME"; read -r ans
  case "$ans" in [Nn]*) echo "Aborted."; exit 0 ;; esac
fi

CUT_ROOT="$SCRIPT_DIR/.."
mkdir -p "$INSTALL_DIR/hooks" "$AGENTS_SKILLS_HOME"

cp "$SCRIPT_DIR/run-hook.sh" "$INSTALL_DIR/run-hook.sh"; chmod +x "$INSTALL_DIR/run-hook.sh"

for f in session-start-orient.sh state-track-commit.sh focus-check.sh state-staleness.sh \
         _python.sh _telemetry.sh _hooks_config.sh; do
  cp "$CUT_ROOT/hooks/$f" "$INSTALL_DIR/hooks/$f"
done
chmod +x "$INSTALL_DIR/hooks/"*.sh 2>/dev/null || true

if [ -d "$CUT_ROOT/bin" ]; then
  cp -r "$CUT_ROOT/bin" "$INSTALL_DIR/bin"
  chmod -R +x "$INSTALL_DIR/bin" 2>/dev/null || true
fi

for s in update-state re-anchor; do
  if [ -d "$CUT_ROOT/skills/$s" ]; then
    mkdir -p "$AGENTS_SKILLS_HOME/$s"
    cp -r "$CUT_ROOT/skills/$s/." "$AGENTS_SKILLS_HOME/$s/"
  fi
done

# Path forms for the hook JSON: command keeps POSIX (MSYS) form; commandWindows uses
# cygpath -m Windows form (C:/...) so Codex's git-bash launch resolves it. Same on POSIX.
INSTALL_DIR_POSIX="$INSTALL_DIR"
INSTALL_DIR_WIN="$INSTALL_DIR"
if command -v cygpath >/dev/null 2>&1; then
  INSTALL_DIR_WIN="$(cygpath -m "$INSTALL_DIR" 2>/dev/null || printf '%s' "$INSTALL_DIR")"
fi

TEMPLATE="$SCRIPT_DIR/hooks.json.template"
[ -f "$TEMPLATE" ] || { echo "install.sh: template not found: $TEMPLATE" >&2; exit 1; }
# Substitute _WIN FIRST (it is a superstring of the POSIX placeholder), then take
# .hooks. Two simple steps via a temp file — avoids nesting a piped multi-line
# command substitution inside the assignment quotes.
SUBST="$(mktemp)"
sed -e "s|\$CODEX_STATE_DRIFT_HOME_WIN|$INSTALL_DIR_WIN|g" \
    -e "s|\$CODEX_STATE_DRIFT_HOME|$INSTALL_DIR_POSIX|g" \
    "$TEMPLATE" > "$SUBST"
OURS="$(jq '.hooks' "$SUBST")"
rm -f "$SUBST"

[ -f "$HOOKS_JSON" ] || echo '{"hooks":{}}' > "$HOOKS_JSON"
tmp="$(mktemp)"
jq --argjson add "$OURS" --arg mark "$MARK" '
  .hooks = ((.hooks // {}) as $h | reduce ($add | to_entries[]) as $e ($h;
    .[$e.key] = (((.[$e.key] // []) | map(select(.hooks | map(.command // "" | contains($mark)) | any | not))) + $e.value)))
' "$HOOKS_JSON" > "$tmp" && mv "$tmp" "$HOOKS_JSON"

echo "claude-state-drift installed into $CODEX_HOME"
echo ""
echo "Next steps:"
echo "  1. First run only: start 'codex' and trust the hooks via /hooks."
echo "  2. Open Codex in a project with .claude/state.json — orientation appears at session start."
echo "  3. Optional: paste codex/AGENTS.snippet.md into your project's AGENTS.md (lite anchor)."
