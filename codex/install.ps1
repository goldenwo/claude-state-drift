# install.ps1 — Windows convenience shim for the Codex CLI port of claude-state-drift.
#
# The Codex hooks run via git-bash (Codex executes commandWindows = "bash ..."), so the
# installer also uses bash. This locates bash and delegates to install.sh with the same
# flags — one real installer, no duplicated merge logic.
#
#   Usage: pwsh install.ps1 [-Yes] [-Uninstall]
param(
    [switch]$Yes,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Write-Error "git-bash is required (Codex runs the hooks via bash). Install Git for Windows, then run: bash install.sh"
    exit 1
}

$rest = @()
if ($Yes)       { $rest += '--yes' }
if ($Uninstall) { $rest += '--uninstall' }

& $bash.Source (Join-Path $ScriptDir 'install.sh') @rest
exit $LASTEXITCODE
