#!/usr/bin/env pwsh
# Install Claude Code customizations (CLAUDE.md, commands, agents, output-styles,
# rules, hooks, workflows, themes, skills, statusline) into the user-level Claude
# Code config dir. Only ever writes these user-authored customization surfaces;
# user data/config/secrets (settings*.json, projects/, history, credentials, ...)
# are never touched. Version-aware: never silently overwrites a newer on-disk
# copy. Windows PowerShell / pwsh.
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- resolve the target .claude directory ----------------------------------
if ($env:CLAUDE_CONFIG_DIR) {
    $Target = $env:CLAUDE_CONFIG_DIR
} else {
    $home_ = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $Target = Join-Path $home_ '.claude'
}

if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    Write-Host "Claude Code config dir not found at: $Target"
    $Target = Read-Host 'Enter the path to your Claude Code config directory'
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        Write-Error "Directory does not exist: $Target"
        exit 1
    }
}

Write-Host "Target: $Target`n"

# --- read the "<!-- vMAJOR.MINOR -->" marker from a file -------------------
# Returns [version] object, or v0.0 if missing / no marker.
function Read-Version {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return [version]'0.0' }
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match '<!--\s*v(\d+)\.(\d+)\s*-->') {
            return [version]"$($Matches[1]).$($Matches[2])"
        }
    }
    return [version]'0.0'
}

function VStr([version]$v) { "v$($v.Major).$($v.Minor)" }

# --- summary buckets --------------------------------------------------------
$Installed   = [System.Collections.Generic.List[string]]::new()
$Updated     = [System.Collections.Generic.List[string]]::new()
$Unchanged   = [System.Collections.Generic.List[string]]::new()
$Kept        = [System.Collections.Generic.List[string]]::new()
$Overwritten = [System.Collections.Generic.List[string]]::new()
$Conflicts   = [System.Collections.Generic.List[object]]::new()

# --- process one managed file ----------------------------------------------
function Invoke-Process {
    param([string]$Src, [string]$Dst)
    $rel = $Dst.Substring($Target.Length).TrimStart('\', '/')

    if (-not (Test-Path -LiteralPath $Dst -PathType Leaf)) {
        $dir = Split-Path -Parent $Dst
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $Src -Destination $Dst
        $Installed.Add($rel)
        return
    }

    $rver = Read-Version $Src
    $dver = Read-Version $Dst

    if ($rver -gt $dver) {
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
        $Updated.Add("$rel ($(VStr $dver) -> $(VStr $rver))")
    } elseif ($rver -eq $dver) {
        $Unchanged.Add("$rel ($(VStr $rver))")
    } else {
        $Conflicts.Add([pscustomobject]@{ Src = $Src; Dst = $Dst; Rel = $rel; DVer = $dver; RVer = $rver })
    }
}

# Managed customization directories, one row per surface: the directory, the file
# globs to copy, and whether to recurse (mirror the whole subtree) or stay flat.
# Add a row to manage a new file-based customization type. NEVER add a directory
# that holds user data or tool state (settings*.json, projects/, agent-memory/,
# history.jsonl, plugins/, sessions/, caches, logs) -- those must stay untouched.
# skills/ is handled separately below (whole-directory copy, not a simple glob).
$ManagedDirs = @(
    @{ Dir = 'commands';      Globs = @('*.md');                Recursive = $true  }
    @{ Dir = 'agents';        Globs = @('*.md');                Recursive = $true  }
    @{ Dir = 'output-styles'; Globs = @('*.md');                Recursive = $false }
    @{ Dir = 'rules';         Globs = @('*.md');                Recursive = $true  }
    @{ Dir = 'hooks';         Globs = @('*.sh', '*.py', '*.js'); Recursive = $true  }
    @{ Dir = 'workflows';     Globs = @('*.js');                Recursive = $true  }
    @{ Dir = 'themes';        Globs = @('*.json');              Recursive = $false }
)

# Top-level files installed by the same name (add extensionless/non-md files here).
$ManagedFiles = @('statusline-command.sh')

# --- main copy pass --------------------------------------------------------
Invoke-Process (Join-Path $ScriptDir '_CLAUDE.md') (Join-Path $Target 'CLAUDE.md')

foreach ($f in $ManagedFiles) {
    $src = Join-Path $ScriptDir $f
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        Invoke-Process $src (Join-Path $Target $f)
    }
}

foreach ($spec in $ManagedDirs) {
    $dir = Join-Path $ScriptDir $spec.Dir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    foreach ($glob in $spec.Globs) {
        $items = if ($spec.Recursive) {
            Get-ChildItem -LiteralPath $dir -Filter $glob -File -Recurse
        } else {
            Get-ChildItem -LiteralPath $dir -Filter $glob -File
        }
        foreach ($item in $items) {
            $rel = $item.FullName.Substring($ScriptDir.Length).TrimStart('\', '/')
            Invoke-Process $item.FullName (Join-Path $Target $rel)
        }
    }
}

# skills/: copy each authored skill directory wholesale (SKILL.md + supporting
# scripts/json/templates, any extension) so we never ship a half-installed skill,
# but exclude tool-written runtime state (*.log, e.g. *-invocations.log).
$skillsDir = Join-Path $ScriptDir 'skills'
if (Test-Path -LiteralPath $skillsDir -PathType Container) {
    Get-ChildItem -LiteralPath $skillsDir -File -Recurse |
        Where-Object { $_.Extension -ne '.log' } |
        ForEach-Object {
            $rel = $_.FullName.Substring($ScriptDir.Length).TrimStart('\', '/')
            Invoke-Process $_.FullName (Join-Path $Target $rel)
        }
}

# --- resolve deferred conflicts (dest newer than repo) ---------------------
if ($Conflicts.Count -gt 0) {
    Write-Host "`nThe following files on disk are NEWER than this repo's copy:"
    foreach ($c in $Conflicts) {
        Write-Host "`n  $($c.Rel): on disk $(VStr $c.DVer)  vs  repo $(VStr $c.RVer)"
        $ans = Read-Host '  Overwrite with older repo version? [y/N]'
        if ($ans -match '^(y|yes)$') {
            Copy-Item -LiteralPath $c.Src -Destination $c.Dst -Force
            $Overwritten.Add($c.Rel)
        } else {
            $Kept.Add($c.Rel)
        }
    }
}

# --- summary ---------------------------------------------------------------
function Write-Bucket {
    param([string]$Title, $List)
    if ($List.Count -eq 0) { return }
    Write-Host "`n${Title}:"
    foreach ($item in $List) { Write-Host "  - $item" }
}

Write-Host "`n==== Summary ===="
if ($Installed.Count -eq 0 -and $Updated.Count -eq 0 -and $Kept.Count -eq 0 -and $Overwritten.Count -eq 0) {
    Write-Host "`nNothing changed. All files already up to date."
}
Write-Bucket 'Installed (new)' $Installed
Write-Bucket 'Updated (repo newer)' $Updated
Write-Bucket 'Unchanged (equal)' $Unchanged
Write-Bucket 'Kept (newer on disk, not overwritten)' $Kept
Write-Bucket 'Overwritten (older repo forced over newer disk)' $Overwritten
Write-Host ''
