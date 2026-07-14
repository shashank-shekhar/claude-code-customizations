#!/bin/sh
# Install Claude Code customizations (CLAUDE.md + slash commands) into the
# user-level Claude Code config dir. Version-aware: never silently overwrites a
# copy on disk that is newer than this repo's. macOS + Linux (POSIX sh).
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

# --- read the "<!-- vMAJOR.MINOR -->" marker from a file -------------------
# Prints "MAJOR MINOR", or "0 0" if the file is missing / has no marker.
read_version() {
    _file=$1
    if [ ! -f "$_file" ]; then
        echo "0 0"
        return
    fi
    _line=$(grep -m1 -E '<!--[[:space:]]*v[0-9]+\.[0-9]+[[:space:]]*-->' "$_file" 2>/dev/null || true)
    if [ -z "$_line" ]; then
        echo "0 0"
        return
    fi
    _ver=$(printf '%s\n' "$_line" | sed -n 's/.*<!--[[:space:]]*v\([0-9]*\)\.\([0-9]*\)[[:space:]]*-->.*/\1 \2/p')
    [ -z "$_ver" ] && _ver="0 0"
    echo "$_ver"
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

# copy preserving the executable bit (statusline script must stay runnable)
copy_file() { # $1=src $2=dst
    cp "$1" "$2"
    [ -x "$1" ] && chmod +x "$2"
    return 0
}

# --- summary buckets (newline-separated path lists) ------------------------
B_INSTALLED=""
B_UPDATED=""
B_UNCHANGED=""
B_KEPT=""
B_OVERWRITTEN=""

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
    _rel=${_dst#"$TARGET"/}

    if [ ! -f "$_dst" ]; then
        mkdir -p "$(dirname -- "$_dst")"
        copy_file "$_src" "$_dst"
        add B_INSTALLED "$_rel"
        return
    fi

    _rver=$(read_version "$_src")
    _dver=$(read_version "$_dst")
    _c=$(cmp_version "$_rver" "$_dver")

    if [ "$_c" = "1" ]; then
        copy_file "$_src" "$_dst"
        add B_UPDATED "$_rel ($(vstr "$_dver") -> $(vstr "$_rver"))"
    elif [ "$_c" = "0" ]; then
        add B_UNCHANGED "$_rel ($(vstr "$_rver"))"
    else
        # destination is NEWER -> defer to a prompt after the main pass
        _entry=$(printf '%s\t%s\t%s\t%s' "$_src" "$_dst" "$_dver" "$_rver")
        if [ -z "$CONFLICTS" ]; then CONFLICTS=$_entry; else CONFLICTS="$CONFLICTS
$_entry"; fi
    fi
}

# Top-level dirs of markdown customizations, each mirrored recursively into the
# target (structure preserved for namespaced commands/agents). Add a dir here to
# manage a new markdown-based customization type.
MANAGED_DIRS="commands agents output-styles"

# Top-level files installed by the same name (add extensionless/non-md files here).
MANAGED_FILES="statusline-command.sh"

# --- main copy pass --------------------------------------------------------
process "$SCRIPT_DIR/_CLAUDE.md" "$TARGET/CLAUDE.md"

for _mf in $MANAGED_FILES; do
    [ -f "$SCRIPT_DIR/$_mf" ] || continue
    process "$SCRIPT_DIR/$_mf" "$TARGET/$_mf"
done

_list=$(mktemp "${TMPDIR:-/tmp}/cc-files.XXXXXX")
for _d in $MANAGED_DIRS; do
    [ -d "$SCRIPT_DIR/$_d" ] || continue
    find "$SCRIPT_DIR/$_d" -type f -name '*.md' >>"$_list"
done
# redirect (not a pipe) so process()'s bucket mutations stay in this shell
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    process "$_f" "$TARGET/${_f#"$SCRIPT_DIR"/}"
done <"$_list"
rm -f "$_list"

# --- resolve deferred conflicts (dest newer than repo) ---------------------
if [ -n "$CONFLICTS" ]; then
    printf '\n%s\n' "The following files on disk are NEWER than this repo's copy:"
    _cf=$(mktemp "${TMPDIR:-/tmp}/cc-conflicts.XXXXXX")
    printf '%s\n' "$CONFLICTS" >"$_cf"
    # Read the conflict list on FD 3 so stdin stays free for the user's answer
    # (works both interactively and with piped input).
    while IFS='	' read -r _src _dst _dver _rver <&3; do
        [ -n "$_src" ] || continue
        _rel=${_dst#"$TARGET"/}
        printf '\n  %s: on disk %s  vs  repo %s\n' "$_rel" "$(vstr "$_dver")" "$(vstr "$_rver")"
        printf '  Overwrite with older repo version? [y/N] '
        read -r _ans || _ans=""
        case $_ans in
            [yY]|[yY][eE][sS]) copy_file "$_src" "$_dst"; add B_OVERWRITTEN "$_rel" ;;
            *) add B_KEPT "$_rel" ;;
        esac
    done 3<"$_cf"
    rm -f "$_cf"
fi

# --- summary ---------------------------------------------------------------
print_bucket() { # $1=title $2=list
    [ -n "$2" ] || return 0
    printf '\n%s:\n' "$1"
    printf '%s\n' "$2" | while IFS= read -r _l; do
        [ -n "$_l" ] && printf '  - %s\n' "$_l"
    done
}

printf '\n==== Summary ====\n'
if [ -z "$B_INSTALLED$B_UPDATED$B_KEPT$B_OVERWRITTEN" ]; then
    printf '\nNothing changed. All files already up to date.\n'
fi
print_bucket "Installed (new)" "$B_INSTALLED"
print_bucket "Updated (repo newer)" "$B_UPDATED"
print_bucket "Unchanged (equal)" "$B_UNCHANGED"
print_bucket "Kept (newer on disk, not overwritten)" "$B_KEPT"
print_bucket "Overwritten (older repo forced over newer disk)" "$B_OVERWRITTEN"
printf '\n'
