# claude-code-customizations

A versioned home for your user-level [Claude Code](https://claude.com/claude-code)
customizations — global instructions, slash commands, subagents, output styles, and
more — with installer scripts that copy them into your Claude Code config directory
(`~/.claude/`).

The install is **version-aware and safe**: it never silently overwrites a file on
disk that is newer than the repo's copy, and it prints a summary of exactly what it
changed.

## Quick start

Clone the repo, then from its root run the script for your OS:

```sh
# macOS / Linux
sh install.sh

# Windows (PowerShell)
pwsh install.ps1
```

Re-run any time you pull updates; only changed files are touched.

## What this repo manages

Each customization type maps to a location under `~/.claude/`. The installer copies
these versioned files, mirroring the repo's structure (including nested folders, e.g.
namespaced commands):

| In the repo | Installs to | What it is |
|-------------|-------------|------------|
| `_CLAUDE.md` | `CLAUDE.md` | Global instructions for every session |
| `commands/**/*.md` | `commands/**` | Slash commands (`/name`, or `/dir:name` when nested) |
| `agents/**/*.md` | `agents/**` | Custom subagents |
| `output-styles/*.md` | `output-styles/` | Output styles (flat) |
| `rules/**/*.md` | `rules/**` | Topic-scoped global instructions |
| `hooks/**/*.{sh,py,js}` | `hooks/**` | Standalone hook scripts (referenced from `settings.json`) |
| `workflows/**/*.js` | `workflows/**` | Dynamic workflow scripts (each becomes a `/command`) |
| `themes/*.json` | `themes/` | Color themes (flat) |
| `skills/<name>/` | `skills/<name>/` | Skills — whole directory, minus runtime state |
| `statusline-command.sh` | `statusline-command.sh` | Statusline renderer (referenced by `settings.json`) |

Managed surfaces are declared as a table in each install script (`MANAGED_DIRS` /
`$ManagedDirs`) — one row per directory giving its file glob(s) and whether to
recurse. Add a row to manage a new type. `skills/` is special-cased (whole-directory
copy, excluding tool-written runtime state like `*.log`). Top-level non-directory
files (like the statusline script) are listed in `MANAGED_FILES` / `$ManagedFiles`.
The executable bit is preserved on copy. The global instructions live in
**`_CLAUDE.md`** (underscore-prefixed so they don't govern coding sessions *inside
this repo*); the installer writes them to `CLAUDE.md`.

**Intentionally not managed:** files the installer must never overwrite because they
hold your own settings, data, or secrets — `settings.json` / `settings.local.json`
(permissions, hooks, env), `keybindings.json`, `.credentials.json`, `.claude.json`,
`projects/`, `history.jsonl`, and every session/cache/log directory. These would need
a *merge* strategy rather than a copy, so they stay out of the managed surfaces. Note
the statusline script is installed, but the `statusLine` entry in `settings.json` that
points to it is not — configure that once by hand.

## Where it installs

The target `.claude` directory is resolved as:

1. `$CLAUDE_CONFIG_DIR` if set, otherwise
2. `~/.claude` (`%USERPROFILE%\.claude` on Windows).

If that directory doesn't exist, the script prompts you for a custom path. For a dry
run against a throwaway location, point the env var at a temp dir:

```sh
CLAUDE_CONFIG_DIR=/tmp/claude-test sh install.sh
```

## How it decides what to copy

Every managed file carries a version: an inline `<!-- vMAJOR.MINOR -->` marker, or —
for files that can't hold a comment (e.g. themes `*.json`) — a sibling
`<file>.version` sidecar. The installer compares the repo's version against what's
already installed:

| Repo vs. installed | Action |
|--------------------|--------|
| not installed yet  | install |
| repo newer         | overwrite |
| equal              | skip |
| **disk newer**     | left alone by default; you're prompted per file (default: keep your newer copy) |

Files are **not** backed up — this repo is the source of truth. Nothing under your
config directory is modified unless you run the script yourself. Every run ends with
a summary grouped into *installed / updated / unchanged / kept / overwritten*.

## Adding customizations

- **Edit global instructions**: change `_CLAUDE.md`, then **bump its version marker**
  (`<!-- v1.1 -->` → `<!-- v1.2 -->`) so the installer picks it up.
- **Add an item to an existing type**: drop a file matching that surface's glob into
  its directory (subfolders allowed where the surface recurses) with a version marker.
  No script change needed.
- **Manage a new type**: add a row — directory, file glob(s), and whether to recurse —
  to the managed-surface table in **both** `install.sh` (`MANAGED_DIRS`) and
  `install.ps1` (`$ManagedDirs`). Keep the two scripts in sync.

The version marker must be the first `<!-- vX.Y -->` in the file. For `CLAUDE.md` it's
line 1; for files with YAML frontmatter it sits right after the closing `---` (the
frontmatter must stay on line 1); for scripts it goes in a comment right after the
shebang (e.g. `# <!-- v1.0 -->`). For file types that can't hold a comment (e.g.
`*.json`), put the version in a `<file>.version` sidecar instead.
