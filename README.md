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
these versioned **markdown** files, mirroring the repo's structure (including nested
folders, e.g. namespaced commands):

| In the repo | Installs to | What it is |
|-------------|-------------|------------|
| `_CLAUDE.md` | `CLAUDE.md` | Global instructions for every session |
| `commands/**/*.md` | `commands/**` | Slash commands (`/name`, or `/dir:name` when nested) |
| `agents/**/*.md` | `agents/**` | Custom subagents |
| `output-styles/**/*.md` | `output-styles/**` | Output styles |
| `statusline-command.sh` | `statusline-command.sh` | Statusline renderer (referenced by `settings.json`) |

The managed directories are listed in each install script (`MANAGED_DIRS` /
`$ManagedDirs`) — add a directory name there to manage a new markdown-based type.
Top-level non-markdown files (like the statusline script) are listed in
`MANAGED_FILES` / `$ManagedFiles`. The executable bit is preserved on copy.
The global instructions live in **`_CLAUDE.md`** (underscore-prefixed so they don't
govern coding sessions *inside this repo*); the installer writes them to `CLAUDE.md`.

**Not yet handled by the installer:** JSON-based customizations (`settings.json`
hooks/permissions/env, `keybindings.json`) and skill directories (`skills/<name>/`).
These need a merge/version strategy of their own; keep them out of the managed dirs
for now. Note the statusline script is installed, but the `statusLine` entry in
`settings.json` that points to it is not — configure that once by hand.

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

Every managed file carries a `<!-- vMAJOR.MINOR -->` version marker. The installer
compares the repo's version against what's already installed:

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
- **Add an item to an existing type**: drop a `*.md` into `commands/`, `agents/`, or
  `output-styles/` (subfolders allowed) with a version marker. No script change needed.
- **Manage a new markdown type**: add its directory name to `MANAGED_DIRS` in
  `install.sh` and `$ManagedDirs` in `install.ps1`.

The version marker must be the first `<!-- vX.Y -->` in the file. For `CLAUDE.md` it's
line 1; for files with YAML frontmatter it sits right after the closing `---` (the
frontmatter must stay on line 1); for scripts it goes in a comment right after the
shebang (e.g. `# <!-- v1.0 -->`).
