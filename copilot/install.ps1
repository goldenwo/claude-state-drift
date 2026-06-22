# install.ps1 — idempotent install/uninstall of claude-state-drift Copilot hooks (PowerShell).
#
# The installer ships in the CUT at: cut-root/copilot/install.ps1
# Sibling directories in the CUT:    cut-root/bin/    (contains where-am-i + helpers)
#                                     cut-root/skills/ (contains update-state, re-anchor)
#
# Installs into COPILOT_HOME (default: $env:USERPROFILE\.copilot):
#   $COPILOT_HOME\hooks\claude-state-drift.json         — hook registration (from template)
#   $COPILOT_HOME\state-drift\                          — adapter scripts + bin tools
#     orient-hook.sh / orient-hook.ps1
#     transition-hook.sh / transition-hook.ps1
#     bin\                                              — where-am-i + helpers (from ..\bin)
#   $COPILOT_HOME\skills\update-state\SKILL.md          — skills (from ..\skills)
#   $COPILOT_HOME\skills\re-anchor\SKILL.md
#
# The hook JSON is written with $COPILOT_STATE_DRIFT_HOME substituted to the
# absolute path of $COPILOT_HOME\state-drift, sourced from the template at
# copilot\hooks\claude-state-drift.json.template (single source of truth).
#
# Usage:
#   pwsh install.ps1 [--yes] [--uninstall]
#
# Flags:
#   --yes        non-interactive (skip confirmation prompts)
#   --uninstall  remove all installed files
#
# Note: if Phase 0 spike confirms that the existing Claude-format plugin loads
# natively in Copilot CLI, the bin/skills copy below becomes optional.

param(
    [switch]$Yes,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Resolve COPILOT_HOME (testable via env; production default: %USERPROFILE%\.copilot)
$CopilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
$InstallDir  = Join-Path $CopilotHome 'state-drift'
$HooksDir    = Join-Path $CopilotHome 'hooks'
$SkillsDir   = Join-Path $CopilotHome 'skills'
$HookJson    = Join-Path $HooksDir 'claude-state-drift.json'

# --- Uninstall ---
if ($Uninstall) {
    if (-not $Yes) {
        $ans = Read-Host "Remove claude-state-drift from $CopilotHome? [y/N]"
        if ($ans -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }
    }
    if (Test-Path $HookJson)   { Remove-Item -Force $HookJson }
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    # Remove skills copied by this installer
    $updateStatePath = Join-Path $SkillsDir 'update-state'
    $reAnchorPath    = Join-Path $SkillsDir 're-anchor'
    if (Test-Path $updateStatePath) { Remove-Item -Recurse -Force $updateStatePath }
    if (Test-Path $reAnchorPath)    { Remove-Item -Recurse -Force $reAnchorPath }
    Write-Host "claude-state-drift uninstalled from $CopilotHome"
    exit 0
}

# --- Install ---
if (-not $Yes) {
    $ans = Read-Host "Install claude-state-drift into $CopilotHome? [Y/n]"
    if ($ans -match '^[Nn]') { Write-Host "Aborted."; exit 0 }
}

# Create directories
New-Item -ItemType Directory -Force $HooksDir   | Out-Null
New-Item -ItemType Directory -Force $InstallDir | Out-Null
New-Item -ItemType Directory -Force $SkillsDir  | Out-Null

# Copy adapter scripts
$SrcHooks = Join-Path $ScriptDir 'hooks'
Copy-Item (Join-Path $SrcHooks 'orient-hook.sh')      (Join-Path $InstallDir 'orient-hook.sh')      -Force
Copy-Item (Join-Path $SrcHooks 'orient-hook.ps1')     (Join-Path $InstallDir 'orient-hook.ps1')     -Force
Copy-Item (Join-Path $SrcHooks 'transition-hook.sh')  (Join-Path $InstallDir 'transition-hook.sh')  -Force
Copy-Item (Join-Path $SrcHooks 'transition-hook.ps1') (Join-Path $InstallDir 'transition-hook.ps1') -Force

# Copy bin/ and skills/ from the cut layout so where-am-i resolves without PATH edits.
# In the CUT: installer is at cut-root\copilot\install.ps1; bin\ and skills\ are at cut-root\.
$CutRoot = Split-Path -Parent $ScriptDir
$CutBin    = Join-Path $CutRoot 'bin'
$CutSkills = Join-Path $CutRoot 'skills'

if (Test-Path $CutBin) {
    $destBin = Join-Path $InstallDir 'bin'
    if (Test-Path $destBin) { Remove-Item -Recurse -Force $destBin }
    Copy-Item -Recurse $CutBin $destBin
}

$updateStateSrc = Join-Path $CutSkills 'update-state'
if (Test-Path $updateStateSrc) {
    $dest = Join-Path $SkillsDir 'update-state'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse $updateStateSrc $dest
}
$reAnchorSrc = Join-Path $CutSkills 're-anchor'
if (Test-Path $reAnchorSrc) {
    $dest = Join-Path $SkillsDir 're-anchor'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse $reAnchorSrc $dest
}

# Write hook registration JSON by substituting $COPILOT_STATE_DRIFT_HOME in the
# template (single source of truth: copilot\hooks\claude-state-drift.json.template).
# Use forward slashes in paths for JSON cross-platform compatibility.
$TemplatePath = Join-Path $SrcHooks 'claude-state-drift.json.template'
if (-not (Test-Path $TemplatePath)) {
    Write-Error "install.ps1: template not found: $TemplatePath"; exit 1
}
$installDirFwd = $InstallDir -replace '\\', '/'
$hookContent = (Get-Content $TemplatePath -Raw -Encoding UTF8) `
    -replace [regex]::Escape('$COPILOT_STATE_DRIFT_HOME'), $installDirFwd `
    -replace [regex]::Escape('$env:COPILOT_STATE_DRIFT_HOME'), $installDirFwd
[System.IO.File]::WriteAllText($HookJson, $hookContent, [System.Text.UTF8Encoding]::new($false))

Write-Host "claude-state-drift installed into $CopilotHome"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Start a Copilot CLI session in a project with .claude/state.json."
Write-Host "  2. Optional: paste AGENTS.snippet.md content into your project's AGENTS.md"
Write-Host "     for an always-on objective anchor (covers userPromptSubmitted, which"
Write-Host "     Copilot CLI does not inject additionalContext for)."
