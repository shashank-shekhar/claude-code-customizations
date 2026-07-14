#!/bin/sh
# <!-- v1.2 -->
input=$(cat)

raw_dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir')

# 1. Repo name — git toplevel basename, else current dir basename
repo_root=$(git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$raw_dir" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
if [ -n "$repo_root" ]; then
    repo_str=$(basename "$repo_root")
else
    repo_str=$(basename "$raw_dir")
fi

# 2. Git branch + dirty marker
git_branch=$(git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$raw_dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$git_branch" ]; then
    git_dirty=$(git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$raw_dir" --no-optional-locks status --porcelain 2>/dev/null | head -c1)
    if [ -n "$git_dirty" ]; then
        branch_str="$git_branch *"
    else
        branch_str="$git_branch"
    fi
else
    branch_str="—"
fi

# 3. Model — short display name
model_str=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "?"')

# 4. Used context percentage (0% fresh session -> 100% full)
used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used_pct" ]; then
    u=$(awk -v v="$used_pct" 'BEGIN{v=v+0; if(v<0)v=0; if(v>100)v=100; printf "%.0f", v}')
    ctx_str="${u}%"
else
    ctx_str="0%"
fi

# Strip control bytes (incl. ESC) from path/model-derived strings so a
# maliciously-named directory can't inject terminal escape sequences.
repo_str=$(printf '%s' "$repo_str" | LC_ALL=C tr -d '\000-\037\177')
branch_str=$(printf '%s' "$branch_str" | LC_ALL=C tr -d '\000-\037\177')
model_str=$(printf '%s' "$model_str" | LC_ALL=C tr -d '\000-\037\177')

# --- Powerline rendering (Starship gruvbox-style rounded caps) ---
# Background colors:  Cyan | Yellow | Dim(gray) | Magenta
C_BG=80      # cyan (softer)
Y_BG=179     # yellow (softer)
D_BG=238     # dim gray
M_BG=171     # magenta (softer)
DK=16        # dark text
LT=252       # light text (for dim segment)

E=$(printf '\033')
CAP_L=""    # rounded left cap  (U+E0B6)
CAP_R=""    # rounded right cap (U+E0B4)
SEP=""      # powerline arrow   (U+E0B0)
BR=""       # git branch icon   (U+E0A0)

printf '%s[38;5;%sm%s'          "$E" "$C_BG" "$CAP_L"                       # left cap (cyan)
printf '%s[38;5;%s;48;5;%sm %s ' "$E" "$DK" "$C_BG" "$repo_str"            # repo
printf '%s[38;5;%s;48;5;%sm%s'   "$E" "$C_BG" "$Y_BG" "$SEP"               # -> yellow
printf '%s[38;5;%s;48;5;%sm %s %s ' "$E" "$DK" "$Y_BG" "$BR" "$branch_str" # branch
printf '%s[38;5;%s;48;5;%sm%s'   "$E" "$Y_BG" "$D_BG" "$SEP"               # -> dim
printf '%s[38;5;%s;48;5;%sm %s ' "$E" "$LT" "$D_BG" "$model_str"           # model
printf '%s[38;5;%s;48;5;%sm%s'   "$E" "$D_BG" "$M_BG" "$SEP"               # -> magenta
printf '%s[38;5;%s;48;5;%sm %s ' "$E" "$DK" "$M_BG" "$ctx_str"             # remaining ctx
printf '%s[0m%s[38;5;%sm%s%s[0m' "$E" "$E" "$M_BG" "$CAP_R" "$E"           # right cap (magenta)
