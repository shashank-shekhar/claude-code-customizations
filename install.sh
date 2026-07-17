#!/bin/sh
# Install Claude Code customizations (CLAUDE.md, commands, agents, output-styles,
# rules, hooks, workflows, themes, skills, statusline) into the user-level Claude
# Code config dir. Only ever writes these user-authored customization surfaces;
# user data/config/secrets (settings*.json, projects/, history, credentials, ...)
# are never touched. Version-aware: never silently overwrites a newer on-disk
# copy. macOS + Linux (POSIX sh).
set -eu

# --- locate the repo (this script's own directory) -------------------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# --- resolve the target .claude directory ----------------------------------
if [ "${CLAUDE_CONFIG_DIR:-}" != "" ]; then
    TARGET=$CLAUDE_CONFIG_DIR
else
    TARGET=$HOME/.claude
fi

if [ ! -d "$TARGET" ]; then
    printf 'Claude Code config dir not found at: %s\n' "$TARGET" >&2
    printf 'Enter the path to your Claude Code config directory: ' >&2
    read -r TARGET
    # expand a leading ~
    case $TARGET in
        "~") TARGET=$HOME ;;
        "~/"*) TARGET=$HOME/${TARGET#~/} ;;
    esac
    if [ ! -d "$TARGET" ]; then
        printf 'Directory does not exist: %s\n' "$TARGET" >&2
        exit 1
    fi
fi

printf 'Target: %s\n\n' "$TARGET"

# --- resolve a file's version ----------------------------------------------
# Prints "MAJOR MINOR". Prefers an inline "<!-- vMAJOR.MINOR -->" marker; for
# files that cannot hold a comment (e.g. *.json themes) it falls back to a
# sidecar "<file>.version" containing a bare "vMAJOR.MINOR". "0 0" if neither is
# present (such a file installs once and is then left untouched).
# Echo "MAJ MIN" only if both components are <=9 digits (safely within a signed
# 32-bit int, so sh's arithmetic and PowerShell's [version] cast always agree);
# otherwise "0 0". A wildly out-of-range marker is thus treated as unversioned
# (never auto-overwrites) instead of crashing or comparing inconsistently across
# the two installers.
clamp_version() {
    _cm=${1%% *}; _cn=${1##* }
    if [ ${#_cm} -le 9 ] && [ ${#_cn} -le 9 ]; then echo "$1"; else echo "0 0"; fi
}

read_version() {
    _file=$1
    if [ ! -f "$_file" ]; then
        echo "0 0"
        return
    fi
    # first inline marker anywhere in the file; grep -o extracts each match on
    # its own line, so a second marker on the same line can't shadow the first.
    _mark=$(grep -oE '<!--[[:space:]]*v[0-9]+\.[0-9]+[[:space:]]*-->' "$_file" 2>/dev/null | head -n1)
    if [ -n "$_mark" ]; then
        _ver=$(printf '%s\n' "$_mark" | sed -n 's/.*v\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
        [ -n "$_ver" ] && { clamp_version "$_ver"; return; }
    fi
    if [ -f "$_file.version" ]; then
        _sv=$(sed -n 's/^[[:space:]]*v\{0,1\}\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' "$_file.version" 2>/dev/null | head -n1)
        [ -n "$_sv" ] && { clamp_version "$_sv"; return; }
    fi
    echo "0 0"
}

# compare two "MAJ MIN" pairs: echoes -1 (a<b), 0 (a==b), 1 (a>b)
cmp_version() {
    _am=${1%% *}; _an=${1##* }
    _bm=${2%% *}; _bn=${2##* }
    if [ "$_am" -lt "$_bm" ]; then echo -1; return; fi
    if [ "$_am" -gt "$_bm" ]; then echo 1; return; fi
    if [ "$_an" -lt "$_bn" ]; then echo -1; return; fi
    if [ "$_an" -gt "$_bn" ]; then echo 1; return; fi
    echo 0
}

vstr() { echo "v${1%% *}.${1##* }"; }

# copy preserving the executable bit (statusline/hook scripts must stay runnable),
# carrying along a "<file>.version" sidecar when the source has one
copy_file() { # $1=src $2=dst
    cp "$1" "$2"
    [ -x "$1" ] && chmod +x "$2"
    [ -f "$1.version" ] && cp "$1.version" "$2.version"
    return 0
}

# True (0) if the destination itself, or any path component between $TARGET and
# it, is a symlink -- following it would let a pre-existing link in the target
# tree redirect our write outside $TARGET. $TARGET itself is not checked (a user
# may legitimately symlink their whole .claude dir).
dest_via_symlink() { # $1=dst
    [ -L "$1" ] && return 0
    _sub=$(dirname -- "${1#"$TARGET"/}")
    [ "$_sub" = "." ] && return 1
    _walk=$TARGET
    _oifs=$IFS; IFS=/
    for _seg in $_sub; do
        _walk=$_walk/$_seg
        if [ -L "$_walk" ]; then IFS=$_oifs; return 0; fi
    done
    IFS=$_oifs
    return 1
}

# --- summary buckets (newline-separated path lists) ------------------------
B_INSTALLED=""
B_UPDATED=""
B_UNCHANGED=""
B_KEPT=""
B_OVERWRITTEN=""
B_SKIPPED=""

# deferred conflicts: lines of "SRC<TAB>DST<TAB>DVER<TAB>RVER"
CONFLICTS=""

add() { # $1=bucket-var-name $2=value
    eval "_cur=\$$1"
    if [ -z "$_cur" ]; then eval "$1=\"\$2\""; else eval "$1=\"\$_cur
\$2\""; fi
}

# --- process one managed file ----------------------------------------------
# $1 = source path in repo, $2 = destination path
process() {
    _src=$1; _dst=$2
    [ -f "$_src" ] || return 0   # skip a phantom source (e.g. a name split on an embedded newline)
    _rel=${_dst#"$TARGET"/}

    if dest_via_symlink "$_dst"; then
        add B_SKIPPED "$_rel (symlinked path in target -- refused)"
        return
    fi

    if [ ! -f "$_dst" ]; then
        mkdir -p "$(dirname -- "$_dst")"
        copy_file "$_src" "$_dst"
        add B_INSTALLED "$_rel"
        return
    fi

    _rver=$(read_version "$_src")
    _dver=$(read_version "$_dst")

    # Pre-existing destination with no version signal (no marker, no sidecar):
    # it was not written by us, so never silently clobber it. Byte-identical to
    # what we'd install -> unchanged (keeps re-runs idempotent); otherwise defer
    # to the same keep-by-default prompt used for a newer-on-disk copy.
    if [ "$_dver" = "0 0" ] && [ "$_rver" != "0 0" ]; then
        if cmp -s "$_src" "$_dst"; then
            add B_UNCHANGED "$_rel (unversioned)"
        else
            _entry=$(printf '%s\t%s\t%s\t%s\t%s' "$_src" "$_dst" "$_dver" "$_rver" "unversioned")
            if [ -z "$CONFLICTS" ]; then CONFLICTS=$_entry; else CONFLICTS="$CONFLICTS
$_entry"; fi
        fi
        return
    fi

    _c=$(cmp_version "$_rver" "$_dver")

    if [ "$_c" = "1" ]; then
        copy_file "$_src" "$_dst"
        add B_UPDATED "$_rel ($(vstr "$_dver") -> $(vstr "$_rver"))"
    elif [ "$_c" = "0" ]; then
        add B_UNCHANGED "$_rel ($(vstr "$_rver"))"
    else
        # destination is NEWER -> defer to a prompt after the main pass
        _entry=$(printf '%s\t%s\t%s\t%s\t%s' "$_src" "$_dst" "$_dver" "$_rver" "newer")
        if [ -z "$CONFLICTS" ]; then CONFLICTS=$_entry; else CONFLICTS="$CONFLICTS
$_entry"; fi
    fi
}

# Managed customization directories, one row per surface:
#   DIR | GLOBS | RECURSIVE
# GLOBS is a space-separated list of shell patterns; RECURSIVE is 1 (mirror the
# whole subtree, e.g. namespaced commands) or 0 (flat, top level only). Add a row
# to manage a new file-based customization type. NEVER add a directory that holds
# user data or tool state (settings*.json, projects/, agent-memory/, history.jsonl,
# plugins/, sessions/, caches, logs) -- those must stay untouched. skills/ is
# handled separately below (whole-directory copy, not a simple glob). Comment-less
# files (e.g. themes *.json) track updates via a "<file>.version" sidecar.
MANAGED_DIRS='
commands|*.md|1
agents|*.md|1
output-styles|*.md|0
rules|*.md|1
hooks|*.sh *.py *.js|1
workflows|*.js|1
themes|*.json|0
'

# Top-level files installed by the same name (add extensionless/non-md files here).
MANAGED_FILES="statusline-command.sh"

# --- main copy pass --------------------------------------------------------
process "$SCRIPT_DIR/_CLAUDE.md" "$TARGET/CLAUDE.md"

for _mf in $MANAGED_FILES; do
    [ -f "$SCRIPT_DIR/$_mf" ] || continue
    process "$SCRIPT_DIR/$_mf" "$TARGET/$_mf"
done

# Build the list of source files to mirror, then process it via a redirect (not a
# pipe) so process()'s bucket mutations stay in this shell.
_list=$(mktemp "${TMPDIR:-/tmp}/cc-files.XXXXXX")

# noglob so the GLOBS patterns are passed literally to find, never expanded
# against this repo's own files.
set -f
printf '%s\n' "$MANAGED_DIRS" | while IFS='|' read -r _dir _globs _rec; do
    [ -n "$_dir" ] || continue
    [ -d "$SCRIPT_DIR/$_dir" ] || continue
    for _g in $_globs; do
        if [ "$_rec" = "1" ]; then
            find "$SCRIPT_DIR/$_dir" -type f -name "$_g"
        else
            find "$SCRIPT_DIR/$_dir" -maxdepth 1 -type f -name "$_g"
        fi
    done
done >>"$_list"
set +f

# skills/: copy each authored skill directory wholesale (SKILL.md + supporting
# scripts/json/templates, any extension) so we never ship a half-installed skill,
# but exclude tool-written runtime state (*.log, e.g. *-invocations.log).
if [ -d "$SCRIPT_DIR/skills" ]; then
    find "$SCRIPT_DIR/skills" -type f ! -name '*.log' ! -name '*.version' >>"$_list"
fi

while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    process "$_f" "$TARGET/${_f#"$SCRIPT_DIR"/}"
done <"$_list"
rm -f "$_list"

# --- resolve deferred conflicts (dest newer than repo) ---------------------
if [ -n "$CONFLICTS" ]; then
    printf '\n%s\n' "These on-disk files were not written by this installer (newer version, or no version marker) -- confirm before overwriting:"
    _cf=$(mktemp "${TMPDIR:-/tmp}/cc-conflicts.XXXXXX")
    printf '%s\n' "$CONFLICTS" >"$_cf"
    # Read the conflict list on FD 3 so stdin stays free for the user's answer
    # (works both interactively and with piped input).
    while IFS='	' read -r _src _dst _dver _rver _reason <&3; do
        [ -n "$_src" ] || continue
        _rel=${_dst#"$TARGET"/}
        if [ "$_reason" = "unversioned" ]; then
            printf '\n  %s: on disk has no version marker (pre-existing?)  vs  repo %s\n' "$_rel" "$(vstr "$_rver")"
            printf '  Overwrite your existing file? [y/N] '
        else
            printf '\n  %s: on disk %s  vs  repo %s\n' "$_rel" "$(vstr "$_dver")" "$(vstr "$_rver")"
            printf '  Overwrite with older repo version? [y/N] '
        fi
        read -r _ans || _ans=""
        case $_ans in
            [yY]|[yY][eE][sS]) copy_file "$_src" "$_dst"; add B_OVERWRITTEN "$_rel" ;;
            *) add B_KEPT "$_rel" ;;
        esac
    done 3<"$_cf"
    rm -f "$_cf"
fi

# --- summary ---------------------------------------------------------------
# Color the summary so changes stand out at a glance. Disabled when stdout is
# not a TTY (pipes, redirects -- keeps captured output byte-identical to the
# no-color form) or when NO_COLOR is set. Empty vars => plain text.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m');   C_BOLD=$(printf '\033[1m')
    C_DIM=$(printf '\033[2m')
    C_GREEN=$(printf '\033[32m');  C_CYAN=$(printf '\033[36m')
    C_YELLOW=$(printf '\033[33m'); C_MAGENTA=$(printf '\033[35m')
    C_RED=$(printf '\033[31m')
else
    C_RESET=; C_BOLD=; C_DIM=; C_GREEN=; C_CYAN=; C_YELLOW=; C_MAGENTA=; C_RED=
fi

print_bucket() { # $1=title $2=list $3=color
    [ -n "$2" ] || return 0
    printf '\n%s%s%s:%s\n' "$C_BOLD" "$3" "$1" "$C_RESET"
    printf '%s\n' "$2" | while IFS= read -r _l; do
        [ -n "$_l" ] && printf '  %s- %s%s\n' "$3" "$_l" "$C_RESET"
    done
}

printf '\n%s==== Summary ====%s\n' "$C_BOLD" "$C_RESET"
if [ -z "$B_INSTALLED$B_UPDATED$B_KEPT$B_OVERWRITTEN$B_SKIPPED" ]; then
    printf '\nNothing changed. All files already up to date.\n'
fi
print_bucket "Installed (new)" "$B_INSTALLED" "$C_GREEN"
print_bucket "Updated (repo newer)" "$B_UPDATED" "$C_CYAN"
print_bucket "Unchanged (equal)" "$B_UNCHANGED" "$C_DIM"
print_bucket "Kept (existing on disk, not overwritten)" "$B_KEPT" "$C_YELLOW"
print_bucket "Overwritten (older repo forced over newer disk)" "$B_OVERWRITTEN" "$C_MAGENTA"
print_bucket "Skipped (symlinked path in target, refused)" "$B_SKIPPED" "$C_RED"

# one-line color-coded tally of every bucket (zeros included)
count() { # $1=list -> number of entries (non-empty lines)
    if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c .; fi
}
_tally=""
add_tally() { # $1=color $2=label $3=list
    _tally="$_tally$1$2:$(count "$3")$C_RESET | "
}
add_tally "$C_GREEN"   "new"         "$B_INSTALLED"
add_tally "$C_CYAN"    "updated"     "$B_UPDATED"
add_tally "$C_DIM"     "unchanged"   "$B_UNCHANGED"
add_tally "$C_YELLOW"  "kept"        "$B_KEPT"
add_tally "$C_MAGENTA" "overwritten" "$B_OVERWRITTEN"
add_tally "$C_RED"     "skipped"     "$B_SKIPPED"
if [ -n "$_tally" ]; then printf '\n%s\n' "$_tally"; fi
printf '\n'
