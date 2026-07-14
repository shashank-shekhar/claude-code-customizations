---
description: Audit Claude Code permissions for this repo, categorize by security impact, then propose an exact patch to clean them up
argument-hint: "[global] [audit-only]"
allowed-tools: Read, Bash(ls:*)
---
<!-- v1.1 -->

# Permissions Security Audit

Audit the Claude Code permissions that apply to **this repository**, categorize each by security impact, recommend cleanups, and emit an exact patch you can apply yourself. **This command is read-only — it never edits your files.** Work through the phases in order.

## Phase 0 — Scope
Argument: `$ARGUMENTS`. Tokens are order-independent and composable (e.g. `global audit-only`).
- **default** (no `global` token) → discovery is **restricted to pwd**: only the project files below. Never read anything outside the repo.
- `global` → also look **outside the repo**: add the user-global file (and managed policy, read-only) to discovery. Project-file changes are proposed by default; any user-global change is proposed in its own separate block.
- `audit-only` → report only; skip the Phase 5 patch. Composes with either scope above.

## Phase 1 — Collect
Read each settings file **in scope** that exists and tag every rule with its source. Precedence (high→low): `deny` > `ask` > `allow`; and file precedence: local > project > user > managed.

Always in scope (pwd):
- `.claude/settings.json` — project, checked in
- `.claude/settings.local.json` — project, personal / gitignored

Only when invoked with `global`:
- `~/.claude/settings.json` — user global (applies to **every** repo)
- Managed policy — **report only, never edit**: macOS `/Library/Application Support/ClaudeCode/managed-settings.json`, Linux `/etc/claude-code/managed-settings.json`

Without `global`, do not read, stat, or reference any path outside the repo. From each in-scope file pull `permissions.allow`, `permissions.ask`, `permissions.deny`. Flag any rule shadowed by a higher-precedence rule (e.g. an `allow` overridden by a `deny`).

Also peek at repo manifests (`package.json`, `*.csproj`/`*.sln`, `go.mod`, `pyproject.toml`, `Cargo.toml`, `Dockerfile`, etc.) to infer the actual tech stack — used later to spot permissions the repo doesn't need.

## Phase 2 — Categorize
Classify every `allow` and `ask` rule into one tier. Judge blast radius: can it run arbitrary code, reach the network, escalate privilege, or cause irreversible change?

| Tier | Meaning | Example patterns |
|---|---|---|
| 🔴 Critical | Arbitrary code exec, privilege escalation, or unrestricted network / exfiltration | any bare wildcard e.g. `Bash(*)` or `Bash(:*)`, `Bash(sudo:*)`, `Bash(su:*)`, `Bash(eval:*)`, `Bash(exec:*)`, `Bash(sh:*)`/`Bash(bash:*)`, `Bash(find:*)` (`-exec`/`-delete`/`-fprintf` run arbitrary code), `Bash(curl:*)`, `Bash(wget:*)`, `WebFetch` with no domain / `WebFetch(*)`, `Write`/`Edit` on paths outside the repo (`~/**`, `/**`) |
| 🟠 High | Destructive / irreversible, remote access, infra control, or fetch-and-run installers | `Bash(rm:*)`, `Bash(git push:*)`, `Bash(git reset --hard:*)`, `Bash(ssh:*)`, `Bash(scp:*)`, `Bash(rsync:*)`, `Bash(docker:*)`, `Bash(kubectl:*)`, `Bash(npm install:*)`, `Bash(pip install:*)`, `Bash(npx:*)`, `Bash(uvx:*)`, `Bash(brew:*)`, `Bash(chmod:*)`, `Bash(chown:*)` |
| 🟡 Medium | Runs project code or mutates the local repo / files | `Bash(npm run:*)`, `Bash(make:*)`, `Bash(dotnet:*)`, `Bash(cargo:*)`, `Bash(go run:*)`, `Bash(git commit:*)`, `Bash(git add:*)`, `Bash(mv:*)`, `Bash(cp:*)`, `Edit`/`Write` scoped to the repo |
| 🟢 Low | Read-only inspection or tightly-scoped safe tasks | `Read(...)`, `Bash(ls:*)`, `Bash(cat:*)`, `Bash(grep:*)`, `Bash(rg:*)`, `Bash(git status:*)`, `Bash(git diff:*)`, `Bash(git log:*)`, `Bash(npm run test:*)`, `Bash(eslint:*)` |

Unlisted patterns: reason by analogy to the nearest example, and lean toward the higher tier when unsure.

## Phase 3 — Report
Emit a single table, sorted 🔴→🟢:

| Permission | Source file | Tier | Why | Recommendation |
|---|---|---|---|---|

Then a one-line count per tier, and a deduplicated **Proposed changes** list.

## Phase 4 — Recommend (removals & narrowings)
- Remove every 🔴 Critical rule, or replace it with a narrowly-scoped equivalent.
- Narrow 🟠 High rules to the exact command/target actually needed (e.g. pin `git push` to one remote+branch); remove entirely if the stack doesn't need them.
- Remove rules irrelevant to the detected stack (e.g. `Bash(pip install:*)` in a .NET-only repo).
- Remove redundant rules already covered by a broader rule, plus duplicates across files.
- Move occasionally-needed-but-risky rules from `allow` → `ask`.
- **Never** propose removing `deny` rules — they are protective.
- *(Optional hardening, clearly marked as optional)* suggest `deny` additions for obvious footguns (e.g. secrets like `Read(./.env)`, `Bash(rm -rf:*)`).

## Phase 5 — Propose the patch
**This command never edits your files** — it hands you an exact patch to apply yourself. Present:

1. The change set as a table (file → rule → action: remove / narrow-to-X / move-to-ask).
2. For each affected file, a copy-pasteable block containing either the **full edited JSON** or a unified diff against the current file — with all other keys and existing key order preserved, and only the named keys changed. Put project-file changes and — only under `global` scope — user-global changes in **separate, clearly-labeled blocks** so the user can apply or skip each independently.
3. A one-line apply hint per file (e.g. "review, then paste over `.claude/settings.json`") and a reminder to back up first if wanted (`cp <file> <file>.bak-$(date +%Y%m%d-%H%M%S)`).

Never emit a patch for managed policy files (report only). Keep any `~/.claude/settings.json` change in its own block under `global` scope so the user opts into it separately.

If run as `audit-only`, end after Phase 4 without proposing a patch.