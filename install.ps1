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

# --- resolve a file's version ----------------------------------------------
# Prefers an inline "<!-- vMAJOR.MINOR -->" marker; for files that cannot hold a
# comment (e.g. *.json themes) it falls back to a sidecar "<file>.version"
# containing a bare "vMAJOR.MINOR". Returns [version], or v0.0 if neither is
# present (such a file installs once and is then left untouched).
# Return v0.0 for a component wider than 9 digits: it overflows [int]/[version]
# (which would abort the run under $ErrorActionPreference='Stop') and can't be
# compared consistently with install.sh's arithmetic. Treat it as unversioned.
function ConvertTo-ClampedVersion {
    param([string]$Major, [string]$Minor)
    if ($Major.Length -gt 9 -or $Minor.Length -gt 9) { return [version]'0.0' }
    return [version]"$Major.$Minor"
}

function Read-Version {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return [version]'0.0' }
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match '<!--\s*v(\d+)\.(\d+)\s*-->') {
            return ConvertTo-ClampedVersion $Matches[1] $Matches[2]
        }
    }
    $sidecar = "$File.version"
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $sidecar) {
            if ($line -match '^\s*v?(\d+)\.(\d+)') {
                return ConvertTo-ClampedVersion $Matches[1] $Matches[2]
            }
        }
    }
    return [version]'0.0'
}

# copy a managed file, carrying along a "<file>.version" sidecar when present
function Copy-Managed {
    param([string]$Src, [string]$Dst)
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
    $sidecar = "$Src.version"
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        Copy-Item -LiteralPath $sidecar -Destination "$Dst.version" -Force
    }
}

function VStr([version]$v) { "v$($v.Major).$($v.Minor)" }

function Test-FilesEqual {
    param([string]$A, [string]$B)
    (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
}

function Test-ReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# True if the destination, or any path component between $Target and it, is a
# reparse point/symlink -- following it could redirect our write outside $Target.
# $Target itself is not checked (a user may legitimately symlink their .claude dir).
function Test-DestViaSymlink {
    param([string]$Dst)
    if (Test-ReparsePoint $Dst) { return $true }
    $sub = Split-Path -Parent ($Dst.Substring($Target.Length).TrimStart('\', '/'))
    if ([string]::IsNullOrEmpty($sub)) { return $false }
    $walk = $Target
    foreach ($seg in ($sub -split '[\\/]+')) {
        if ([string]::IsNullOrEmpty($seg)) { continue }
        $walk = Join-Path $walk $seg
        if (Test-ReparsePoint $walk) { return $true }
    }
    return $false
}

# --- summary buckets --------------------------------------------------------
$Installed   = [System.Collections.Generic.List[string]]::new()
$Updated     = [System.Collections.Generic.List[string]]::new()
$Unchanged   = [System.Collections.Generic.List[string]]::new()
$Kept        = [System.Collections.Generic.List[string]]::new()
$Overwritten = [System.Collections.Generic.List[string]]::new()
$Skipped     = [System.Collections.Generic.List[string]]::new()
$Conflicts   = [System.Collections.Generic.List[object]]::new()

# --- process one managed file ----------------------------------------------
function Invoke-Process {
    param([string]$Src, [string]$Dst)
    $rel = $Dst.Substring($Target.Length).TrimStart('\', '/')

    if (Test-DestViaSymlink $Dst) {
        $Skipped.Add("$rel (symlinked path in target -- refused)")
        return
    }

    if (-not (Test-Path -LiteralPath $Dst -PathType Leaf)) {
        $dir = Split-Path -Parent $Dst
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Managed $Src $Dst
        $Installed.Add($rel)
        return
    }

    $rver = Read-Version $Src
    $dver = Read-Version $Dst

    # Pre-existing destination with no version signal (no marker, no sidecar):
    # it was not written by us, so never silently clobber it. Byte-identical to
    # what we'd install -> unchanged (keeps re-runs idempotent); otherwise defer
    # to the same keep-by-default prompt used for a newer-on-disk copy.
    if ($dver -eq [version]'0.0' -and $rver -ne [version]'0.0') {
        if (Test-FilesEqual $Src $Dst) {
            $Unchanged.Add("$rel (unversioned)")
        } else {
            $Conflicts.Add([pscustomobject]@{ Src = $Src; Dst = $Dst; Rel = $rel; DVer = $dver; RVer = $rver; Reason = 'unversioned' })
        }
        return
    }

    if ($rver -gt $dver) {
        Copy-Managed $Src $Dst
        $Updated.Add("$rel ($(VStr $dver) -> $(VStr $rver))")
    } elseif ($rver -eq $dver) {
        $Unchanged.Add("$rel ($(VStr $rver))")
    } else {
        $Conflicts.Add([pscustomobject]@{ Src = $Src; Dst = $Dst; Rel = $rel; DVer = $dver; RVer = $rver; Reason = 'newer' })
    }
}

# Managed customization directories, one row per surface: the directory, the file
# globs to copy, and whether to recurse (mirror the whole subtree) or stay flat.
# Add a row to manage a new file-based customization type. NEVER add a directory
# that holds user data or tool state (settings*.json, projects/, agent-memory/,
# history.jsonl, plugins/, sessions/, caches, logs) -- those must stay untouched.
# skills/ is handled separately below (whole-directory copy, not a simple glob).
# Comment-less files (e.g. themes *.json) track updates via a "<file>.version" sidecar.
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
        # skip symlinks (parity with sh `find -type f`) and pathological newline names
        $items = $items | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.Name -notmatch '[\r\n]' }
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
        Where-Object { $_.Extension -notin '.log', '.version' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.Name -notmatch '[\r\n]' } |
        ForEach-Object {
            $rel = $_.FullName.Substring($ScriptDir.Length).TrimStart('\', '/')
            Invoke-Process $_.FullName (Join-Path $Target $rel)
        }
}

# --- resolve deferred conflicts (dest newer than repo) ---------------------
if ($Conflicts.Count -gt 0) {
    Write-Host "`nThese on-disk files were not written by this installer (newer version, or no version marker) -- confirm before overwriting:"
    foreach ($c in $Conflicts) {
        if ($c.Reason -eq 'unversioned') {
            Write-Host "`n  $($c.Rel): on disk has no version marker (pre-existing?)  vs  repo $(VStr $c.RVer)"
            $ans = Read-Host '  Overwrite your existing file? [y/N]'
        } else {
            Write-Host "`n  $($c.Rel): on disk $(VStr $c.DVer)  vs  repo $(VStr $c.RVer)"
            $ans = Read-Host '  Overwrite with older repo version? [y/N]'
        }
        if ($ans -match '^(y|yes)$') {
            Copy-Managed $c.Src $c.Dst
            $Overwritten.Add($c.Rel)
        } else {
            $Kept.Add($c.Rel)
        }
    }
}

# --- summary ---------------------------------------------------------------
# Color the summary so changes stand out at a glance. Disabled when stdout is
# redirected (pipes, files -- keeps captured output byte-identical to the
# no-color form) or when NO_COLOR is set. Empty vars => plain text.
$e = [char]27
if ((-not $env:NO_COLOR) -and (-not [Console]::IsOutputRedirected)) {
    $C = @{ Reset = "$e[0m"; Bold = "$e[1m"; Dim = "$e[2m"; Green = "$e[32m"; Cyan = "$e[36m"; Yellow = "$e[33m"; Magenta = "$e[35m"; Red = "$e[31m" }
} else {
    $C = @{ Reset = ''; Bold = ''; Dim = ''; Green = ''; Cyan = ''; Yellow = ''; Magenta = ''; Red = '' }
}

function Write-Bucket {
    param([string]$Title, $List, [string]$Color)
    if ($List.Count -eq 0) { return }
    Write-Host "`n$($C.Bold)$Color${Title}:$($C.Reset)"
    foreach ($item in $List) { Write-Host "  $Color- $item$($C.Reset)" }
}

Write-Host "`n$($C.Bold)==== Summary ====$($C.Reset)"
if ($Installed.Count -eq 0 -and $Updated.Count -eq 0 -and $Kept.Count -eq 0 -and $Overwritten.Count -eq 0 -and $Skipped.Count -eq 0) {
    Write-Host "`nNothing changed. All files already up to date."
}
Write-Bucket 'Installed (new)' $Installed $C.Green
Write-Bucket 'Updated (repo newer)' $Updated $C.Cyan
Write-Bucket 'Unchanged (equal)' $Unchanged $C.Dim
Write-Bucket 'Kept (existing on disk, not overwritten)' $Kept $C.Yellow
Write-Bucket 'Overwritten (older repo forced over newer disk)' $Overwritten $C.Magenta
Write-Bucket 'Skipped (symlinked path in target, refused)' $Skipped $C.Red

# one-line color-coded tally of every bucket (zeros included)
$tally = ''
foreach ($c in @(
    @{ Color = $C.Green;   Label = 'new';         List = $Installed   },
    @{ Color = $C.Cyan;    Label = 'updated';     List = $Updated     },
    @{ Color = $C.Dim;     Label = 'unchanged';   List = $Unchanged   },
    @{ Color = $C.Yellow;  Label = 'kept';        List = $Kept        },
    @{ Color = $C.Magenta; Label = 'overwritten'; List = $Overwritten },
    @{ Color = $C.Red;     Label = 'skipped';     List = $Skipped     }
)) {
    $tally += "$($c.Color)$($c.Label):$($c.List.Count)$($C.Reset) | "
}
if ($tally) { Write-Host "`n$tally" }
Write-Host ''
