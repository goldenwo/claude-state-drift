# codex/run-hook.ps1 — Windows launcher for the claude-state-drift Codex plugin hooks.
#
# Why this exists: Codex spawns a hook command by PATH-resolving its first token. On
# Windows, bare `bash` frequently resolves to C:\Windows\System32\bash.exe (the WSL
# launcher), NOT git-bash — so a `bash <hook>.sh` command never runs the hook. The
# hooks.json `commandWindows` therefore calls this launcher, which resolves git-bash
# deterministically from the on-PATH `git` location and execs the hook — forwarding
# stdin (the hook reads cwd / session_id / tool_response from it) and preserving
# CLAUDE_PLUGIN_ROOT so the hook can locate bin/where-am-i.
#
# macOS/Linux never use this — there the hooks.json `command` runs `bash` directly.
param([Parameter(Mandatory = $true)][string]$Hook)

# Plugin root: Codex exports CLAUDE_PLUGIN_ROOT / PLUGIN_ROOT = the install dir.
$root = $env:CLAUDE_PLUGIN_ROOT
if (-not $root) { $root = $env:PLUGIN_ROOT }
if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }   # codex/ -> plugin root
$root = $root -replace '\\', '/'   # git-bash-friendly; avoids backslash-escape issues

# Resolve git-bash: derive from the on-PATH git (…/Git/cmd/git.exe -> …/Git/bin/bash.exe),
# then fall back to common install locations.
$bash = $null
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    $cand = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin\bash.exe'
    if (Test-Path $cand) { $bash = $cand }
}
if (-not $bash) {
    foreach ($c in @("$env:ProgramFiles\Git\bin\bash.exe",
                     "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
                     "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if ($c -and (Test-Path $c)) { $bash = $c; break }
    }
}
if (-not $bash) { exit 0 }   # no git-bash -> silent no-op, never break the session

$script = "$root/hooks/$Hook"
if (-not (Test-Path $script)) { exit 0 }

$env:CLAUDE_PLUGIN_ROOT = $root   # ensure the hook can locate bin/where-am-i
& $bash $script                   # stdin (the hook payload) is inherited by the child
exit $LASTEXITCODE
