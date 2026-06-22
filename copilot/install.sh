#!/usr/bin/env bash
# install.sh — idempotent install/uninstall of claude-state-drift Copilot hooks.
#
# The installer ships in the CUT at: cut-root/copilot/install.sh
# Sibling directories in the CUT:    cut-root/bin/    (contains where-am-i + helpers)
#                                     cut-root/skills/ (contains update-state, re-anchor)
#
# Installs into COPILOT_HOME (default: ~/.copilot):
#   $COPILOT_HOME/hooks/claude-state-drift.json         — hook registration (from template)
#   $COPILOT_HOME/state-drift/                          — adapter scripts + bin tools
#     orient-hook.sh / orient-hook.ps1
#     transition-hook.sh / transition-hook.ps1
#     bin/                                              — where-am-i + helpers (from ../bin)
#   $COPILOT_HOME/skills/update-state/SKILL.md          — skills (from ../skills)
#   $COPILOT_HOME/skills/re-anchor/SKILL.md
#
# The hook JSON is written with $COPILOT_STATE_DRIFT_HOME substituted to the
# absolute path of $COPILOT_HOME/state-drift, sourced from the template at
# copilot/hooks/claude-state-drift.json.template (single source of truth).
# The absolute path is embedded directly in the hook command strings; the adapters
# self-locate bin/where-am-i via ${BASH_SOURCE[0]}/$PSScriptRoot at runtime.
#
# Usage:
#   bash install.sh [--yes] [--uninstall]
#
# Flags:
#   --yes        non-interactive (skip confirmation prompts)
#   --uninstall  remove all installed files
#
# Note: if Phase 0 spike confirms that the existing Claude-format plugin loads
# natively in Copilot CLI, the bin/skills copy below becomes optional — the
# hooks could call Claude's own where-am-i instead. The explicit copy works
# either way and keeps the Copilot port self-contained.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve COPILOT_HOME (testable via env; production default: ~/.copilot)
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"

YES=0
UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --yes)       YES=1 ;;
        --uninstall) UNINSTALL=1 ;;
        *) echo "install.sh: unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# Resolve the state-drift install dir (absolute)
INSTALL_DIR="$COPILOT_HOME/state-drift"

# --- Uninstall ---
if [ "$UNINSTALL" = "1" ]; then
    if [ "$YES" != "1" ]; then
        printf 'Remove claude-state-drift from %s? [y/N] ' "$COPILOT_HOME"
        read -r ans
        case "$ans" in [Yy]*) ;; *) echo "Aborted."; exit 0 ;; esac
    fi
    rm -f "$COPILOT_HOME/hooks/claude-state-drift.json"
    rm -rf "$INSTALL_DIR"
    # Remove skills copied by this installer
    rm -rf "$COPILOT_HOME/skills/update-state"
    rm -rf "$COPILOT_HOME/skills/re-anchor"
    echo "claude-state-drift uninstalled from $COPILOT_HOME"
    exit 0
fi

# --- Install ---
if [ "$YES" != "1" ]; then
    printf 'Install claude-state-drift into %s? [Y/n] ' "$COPILOT_HOME"
    read -r ans
    case "$ans" in [Nn]*) echo "Aborted."; exit 0 ;; esac
fi

# Create directories
mkdir -p "$COPILOT_HOME/hooks"
mkdir -p "$INSTALL_DIR"
mkdir -p "$COPILOT_HOME/skills"

# Copy adapter scripts
cp "$SCRIPT_DIR/hooks/orient-hook.sh"      "$INSTALL_DIR/orient-hook.sh"
cp "$SCRIPT_DIR/hooks/orient-hook.ps1"     "$INSTALL_DIR/orient-hook.ps1"
cp "$SCRIPT_DIR/hooks/transition-hook.sh"  "$INSTALL_DIR/transition-hook.sh"
cp "$SCRIPT_DIR/hooks/transition-hook.ps1" "$INSTALL_DIR/transition-hook.ps1"
chmod +x "$INSTALL_DIR/orient-hook.sh" "$INSTALL_DIR/transition-hook.sh"

# Copy bin/ and skills/ from the cut layout so where-am-i resolves without PATH edits.
# In the CUT: installer is at cut-root/copilot/install.sh; bin/ and skills/ are at cut-root/
# (i.e. one directory up from SCRIPT_DIR).
CUT_ROOT="$SCRIPT_DIR/.."
if [ -d "$CUT_ROOT/bin" ]; then
    cp -r "$CUT_ROOT/bin" "$INSTALL_DIR/bin"
    chmod -R +x "$INSTALL_DIR/bin" 2>/dev/null || true
fi
if [ -d "$CUT_ROOT/skills/update-state" ]; then
    mkdir -p "$COPILOT_HOME/skills/update-state"
    cp -r "$CUT_ROOT/skills/update-state/." "$COPILOT_HOME/skills/update-state/"
fi
if [ -d "$CUT_ROOT/skills/re-anchor" ]; then
    mkdir -p "$COPILOT_HOME/skills/re-anchor"
    cp -r "$CUT_ROOT/skills/re-anchor/." "$COPILOT_HOME/skills/re-anchor/"
fi

# Write the hook registration JSON by substituting $COPILOT_STATE_DRIFT_HOME in the
# template (copilot/hooks/claude-state-drift.json.template) — single source of truth.
# The resolved absolute path is embedded so hooks self-locate at runtime.
TEMPLATE="$SCRIPT_DIR/hooks/claude-state-drift.json.template"
if [ ! -f "$TEMPLATE" ]; then
    echo "install.sh: template not found: $TEMPLATE" >&2; exit 1
fi
# Resolve the path EMBEDDED IN THE HOOK JSON. On Windows (MSYS/git-bash) Copilot
# runs the PowerShell hook variant, and native PowerShell cannot resolve a git-bash
# drive-mount path (the leading "/c/" form); convert it to mixed Windows form
# (drive-letter + forward slashes) via cygpath. git-bash accepts that form too, so
# the bash variant still resolves. On real POSIX cygpath is absent and the path is
# left unchanged. (Filesystem ops above intentionally keep using $INSTALL_DIR.)
INSTALL_DIR_JSON="$INSTALL_DIR"
if command -v cygpath >/dev/null 2>&1; then
    INSTALL_DIR_JSON="$(cygpath -m "$INSTALL_DIR" 2>/dev/null || printf '%s' "$INSTALL_DIR")"
fi

# Substitute both the bash form ($COPILOT_STATE_DRIFT_HOME) and the ps1 form
# ($env:COPILOT_STATE_DRIFT_HOME) with the absolute install dir.
# Use | as sed delimiter to avoid clashes with path slashes.
sed \
    -e "s|\$COPILOT_STATE_DRIFT_HOME|$INSTALL_DIR_JSON|g" \
    -e "s|\$env:COPILOT_STATE_DRIFT_HOME|$INSTALL_DIR_JSON|g" \
    "$TEMPLATE" > "$COPILOT_HOME/hooks/claude-state-drift.json"

echo "claude-state-drift installed into $COPILOT_HOME"
echo ""
echo "Next steps:"
echo "  1. Start a Copilot CLI session in a project with .claude/state.json."
echo "  2. Optional: paste AGENTS.snippet.md content into your project's AGENTS.md"
echo "     for an always-on objective anchor (covers userPromptSubmitted, which"
echo "     Copilot CLI does not inject additionalContext for)."
