# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A versioned home for **user-level Claude Code customizations** (global instructions, slash commands, subagents, output styles, rules, hooks, workflows, themes, skills, statusline) plus two installer scripts that copy them into the user's Claude Code config dir (`$CLAUDE_CONFIG_DIR`, else `~/.claude` / `%USERPROFILE%\.claude`). There is no application code, build step, or test framework — the deliverable is the installers and the markdown/script payload they ship.

`README.md` is the user-facing guide and can lag the scripts; **the install scripts are the source of truth** for what is actually managed.

## Two invariants (do not break these)

1. **`install.sh` (POSIX sh) and `install.ps1` (pwsh) must stay behaviorally identical.** They are deliberate line-for-line parallels. Any change to one must be mirrored in the other, and both must produce the same install/summary output. Two intentional platform differences exist: `install.sh` preserves the executable bit (`chmod +x`) and expands a leading `~` on manual path entry; neither applies on Windows.
2. **The installer only ever writes an explicit whitelist of customization surfaces, and must NEVER touch user data/config/secrets.** Off-limits and not to be added to the whitelist: `settings.json`, `settings.local.json`, `keybindings.json`, `.credentials.json`, `.claude.json`, `projects/`, `agent-memory/`, `history.jsonl`, `plugins/`, and all session/cache/log dirs. When in doubt, a file is *not* safe to manage.

## Verify changes

No unit tests. Verify installer edits with a syntax check plus a dry run into a throwaway target:

```sh
sh -n install.sh                                   # POSIX syntax check
pwsh -NoProfile -Command '[scriptblock]::Create((Get-Content -Raw install.ps1)) > $null'  # ps1 parse check

CLAUDE_CONFIG_DIR=/tmp/cc-test sh   install.sh     # dry run (sh);  target dir must exist
CLAUDE_CONFIG_DIR=/tmp/cc-test pwsh install.ps1    # dry run (ps1)
```

Re-running against the same target must report everything `Unchanged` (idempotent). To exercise safety, pre-seed the target with a fake `settings.json` / `.credentials.json` and confirm they are byte-for-byte untouched after a run.

## Install architecture

Both scripts share this shape:

- **Target resolution** → `$CLAUDE_CONFIG_DIR` if set, else `~/.claude`; prompts if missing.
- **`_CLAUDE.md` → `CLAUDE.md`** (special-cased). The payload is underscore-prefixed so it does *not* govern coding sessions inside this repo — only the installed copy governs other projects. (This root `CLAUDE.md` is separate and is ignored by the installer.)
- **`MANAGED_DIRS`** — a per-surface table (`DIR|GLOBS|RECURSIVE` rows in sh; array of `@{Dir;Globs;Recursive}` in ps1). Each row mirrors matching files into the target, structure preserved. Recursive rows keep subfolder namespacing (e.g. `commands/dir:name`); flat rows copy top level only. `set -f` (noglob) guards the sh loop so patterns reach `find` literally.
- **`MANAGED_FILES`** — top-level non-markdown files copied by the same name (e.g. `statusline-command.sh`).
- **`skills/`** — special-cased: whole authored skill directories are copied wholesale (any file type), **excluding** tool-written runtime state (`*.log`, `*.version`). Never fold skills into the flat `*.md` rule — that would ship broken, partial skills.

## Versioning discipline

Every managed file carries a version; the installer overwrites only when the repo's version is **newer**. Equal → skip; **disk newer → left alone, prompts per file**. So **an edit that doesn't bump the version will not be picked up.**

- **Inline marker** `<!-- vMAJOR.MINOR -->` — first such comment in the file. Placement: line 1 for `_CLAUDE.md`; immediately after the closing `---` of YAML frontmatter for command/agent files (frontmatter stays on line 1); after the shebang for scripts (`# <!-- v1.0 -->`).
- **`.version` sidecar** — for files that can't hold a comment (e.g. themes `*.json`). Put a sibling `<file>.version` containing a bare `vMAJOR.MINOR`; it is copied alongside the file and read as its version. A comment-less file with no sidecar installs once, then is never overwritten.

## Common edits

- **New item of an existing type** → drop a file matching the row's glob into that dir (with a version marker); no script change.
- **New markdown surface** → add a row to the `MANAGED_DIRS` table in **both** scripts.
- **New non-markdown surface** → add a row with the right glob; if the type can't hold an inline marker, use `.version` sidecars.
