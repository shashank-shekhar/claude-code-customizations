---
description: Audit Claude Code permissions for this repo, categorize by security impact, then clean up on confirmation
argument-hint: "[global] [audit-only]"
allowed-tools: Read, Edit, Bash(ls:*), Bash(find:*), Bash(cat:*), Bash(cp:*)
---
<!-- v1.0 -->

# Permissions Security Audit — v1.1

Audit the Claude Code permissions that apply to **this repository**, categorize each by security impact, recommend cleanups, and — only after explicit confirmation — remove or narrow them. Work through the phases in order. **Never skip the Phase 5 confirmation gate.**

## Phase 0 — Scope
Argument: `$ARGUMENTS`. Tokens are order-independent and composable (e.g. `global audit-only`).
- **default** (no `global` token) → discovery is **restricted to pwd**: only the project files below. Never read or edit anything outside the repo.
- `global` → also look **outside the repo**: add the user-global file (and managed policy, read-only) to discovery. Project files remain cleanable by default; the global file is only edited after its own separate confirmation.
- `audit-only` → report only; never edit any file. Composes with either scope above.

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
| 🔴 Critical | Arbitrary code exec, privilege escalation, or unrestricted network / exfiltration | any bare wildcard e.g. `Bash(*)` or `Bash(:*)`, `Bash(sudo:*)`, `Bash(su:*)`, `Bash(eval:*)`, `Bash(exec:*)`, `Bash(sh:*)`/`Bash(bash:*)`, `Bash(curl:*)`, `Bash(wget:*)`, `WebFetch` with no domain / `WebFetch(*)`, `Write`/`Edit` on paths outside the repo (`~/**`, `/**`) |
| 🟠 High | Destructive / irreversible, remote access, infra control, or fetch-and-run installers | `Bash(rm:*)`, `Bash(git push:*)`, `Bash(git reset --hard:*)`, `Bash(ssh:*)`, `Bash(scp:*)`, `Bash(rsync:*)`, `Bash(docker:*)`, `Bash(kubectl:*)`, `Bash(npm install:*)`, `Bash(pip install:*)`, `Bash(npx:*)`, `Bash(uvx:*)`, `Bash(brew:*)`, `Bash(chmod:*)`, `Bash(chown:*)` |
| 🟡 Medium | Runs project code or mutates the local repo / files | `Bash(npm run:*)`, `Bash(make:*)`, `Bash(dotnet:*)`, `Bash(cargo:*)`, `Bash(go run:*)`, `Bash(git commit:*)`, `Bash(git add:*)`, `Bash(mv:*)`, `Bash(cp:*)`, `Edit`/`Write` scoped to the repo |
| 🟢 Low | Read-only inspection or tightly-scoped safe tasks | `Read(...)`, `Bash(ls:*)`, `Bash(cat:*)`, `Bash(grep:*)`, `Bash(rg:*)`, `Bash(find:*)`, `Bash(git status:*)`, `Bash(git diff:*)`, `Bash(git log:*)`, `Bash(npm run test:*)`, `Bash(eslint:*)` |

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

## Phase 5 — Confirm & clean
**STOP.** Present the exact change set as a table (file → rule → action: remove / narrow-to-X / move-to-ask), then ask for a single yes/no confirmation. Ask **one question at a time**:
1. Confirm the project-file changes.
2. Only under `global` scope, if user-global changes are proposed: ask separately to confirm those.

After confirmation, and only then:
- Back up each file first: `cp <file> <file>.bak-$(date +%Y%m%d-%H%M%S)`.
- Edit only the named keys; preserve all other JSON and existing key order.
- Re-read each edited file and show a concise before/after diff of what changed.
- Never edit managed policy. Only touch `~/.claude/settings.json` under `global` scope and after the user explicitly confirmed that global change.

If run as `audit-only`, end after Phase 4 without offering edits.