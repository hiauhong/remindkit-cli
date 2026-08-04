# remindkit — Apple Reminders data pipeline CLI

[![Vibe coded](https://img.shields.io/badge/vibe-coded-%23ff69b4?style=flat-square)](https://en.wikipedia.org/wiki/Vibe_coding)

[中文版](README.md)

remindkit is a macOS command-line tool that exports structured data from Apple Reminders and supports the full write hierarchy (lists / groups / sections / tasks / subtasks). **Designed for AI agents**: unified JSON output, machine-parseable error contract, and a bundled agent skill.

> 🎨 This project is **vibe coded** (AI-assisted development) — features, tests, and docs are all iterated in collaboration with an AI agent.

> **⚠️ Disclaimer**
> - remindkit reads data through Apple's **private framework** `ReminderKit.framework` (`dlopen` + Objective-C runtime messaging; no Apple code or headers included). Private APIs are **unsupported by Apple and may break with any macOS update** — use at your own risk.
> - This project is not affiliated with, endorsed by, or sponsored by Apple Inc. “Apple” and “Reminders” are trademarks of Apple Inc.
> - For personal use and study only.

> **🔒 Privacy**
> - All data is processed **locally**: the CLI makes no network requests and uploads nothing (sensitive reminder content — bills, health, locations — never leaves your machine).
> - Requires “Reminders” access via TCC; grant it from the system prompt on first run. Permission belongs to the host process.

## Features

- **Structured JSON export**: lists, groups (folders), sections, subtasks, tags, flags, urgent, smart lists — including fields the public EventKit API **cannot** provide (matrix below)
- **Full write hierarchy**: tasks (add/update/complete/delete/move), lists, groups, sections, smart lists
- **Dual-source architecture**: ReminderKit private framework as the primary source, EventKit public API as fallback; every export carries a `source` field
- **Agent-first**: JSON output by default, unified error contract (stderr JSON + exit codes), `--fields` projection to save tokens, one-command skill install

## Install

```bash
# Homebrew (Apple Silicon / arm64 builds published)
brew install hiauhong/tap/remindkit

# Or from GitHub Releases (arm64; includes remindkit + fetch-remindkit subprocess + skill)
mkdir -p ~/.local/bin \
  && curl -fsSL https://github.com/hiauhong/remindkit-cli/releases/latest/download/remindkit-darwin-arm64.tar.gz \
  | tar -xz -C ~/.local/bin --strip-components=1

# Or use the install script (defaults to ~/.local/bin) — auto-registers the skill, nothing else needed
./Scripts/install.sh

# Manual tarball install (not via install.sh)? Run once so AI agents can discover remindkit:
remindkit install-skill --agents
```

> Intel (x86_64) users: please build from source (`make build`) for now; arm64 binaries are published via Homebrew and GitHub Releases.

> The install ships three parts: the `remindkit` CLI, the `fetch-remindkit` subprocess binary (must sit next to the CLI), and the `.agents/skills/remindkit/` skill source.

### Make AI agents discover remindkit automatically

remindkit ships an agent skill ([Agent Skills spec](https://agentskills.io/specification)) registered to `~/.agents/skills/remindkit/`:

- **install.sh** auto-runs `remindkit install-skill --agents --force` after installing — zero manual steps; opt out with `REMINDKIT_SKIP_SKILL=1`
- **Manual tarball / Homebrew** installs: run `remindkit install-skill --agents` once
- **Claude Code** users additionally run `remindkit install-skill --claude`
- Re-running install refreshes the skill with `--force`, so agents never keep a stale copy

> How it works: agents scan `~/.agents/skills/` (pi, Codex, …) at startup and match intent against the SKILL.md description, loading full instructions on demand. The skill source ships next to the binary at `~/.local/bin/.agents/skills/remindkit/`; `install-skill` copies it into agent directories.

## First run: grant permission

remindkit needs “Reminders” access (TCC). On first run macOS shows a permission prompt — click “Allow”:

```bash
remindkit doctor        # check permission state first (follow its hints if not granted)
remindkit               # or just run any command — the first one triggers the prompt
```

> Permission belongs to the **host process** (your terminal app or agent host), not to the remindkit binary itself. If authorization fails inside an agent environment, run `remindkit doctor --for-agent --json` to see the responsible process and grant it there.

After granting, it's a good idea to **take a full-export baseline backup** (also verifies reading works):

```bash
remindkit dump > ~/reminders-backup.json
```

Before any write operations (complete/delete/move/bulk) you can dump again and diff against the baseline for peace of mind.

## Quick start

```bash
remindkit                  # overview: today / overdue / upcoming / flagged / urgent (default command)
remindkit today            # due today
remindkit overdue          # overdue
remindkit search "milk"    # search
remindkit complete <id>    # complete
remindkit count            # stats
```

All query commands return **incomplete reminders only** by default; `--completed` for completed only, `--all` for everything. Output format auto-switches (plain on TTY, JSON when piped); override with `--format json|plain|count`.

## Common commands

| Purpose | Command |
|---|---|
| Overview (agent default) | `remindkit overview [--within N]` |
| Today / Overdue / Scheduled / Flagged / Urgent | `today` `overdue` `scheduled` `flagged` `urgent` |
| Search / filter / stats | `search "<term>"` `query --list X --tag Y` `count [--by-list]` |
| List structure (groups/sections/notes) | `list --format json` `list --groups` |
| Tags | `tags` |
| Full export | `dump > reminders.json` (heavy; use `--fields` projection) |
| Complete / reopen / delete / move | `complete <id>` `delete <id>` `move <id> --to 列表` |
| List notes (lists/groups/smart lists) | `note --all` `note --list 旗标 --set "当前焦点"` |
| Note init (agent non-interactive) | `setup --accept` / `setup --status` |
| Permission diagnosis | `doctor --for-agent --json` |

> Full options: `remindkit <command> --help`.

## For AI agents

- **Default entry `overview`**: today / overdue / next 7 days / flagged focus / urgent in one call — no full dump needed
- **JSON date fields**: `dueDate` is epoch; `dueDateText` adds local-time `yyyy-MM-dd HH:mm`
- **Error contract**: runtime errors go to stderr as JSON `{"error":{"code":"…","message":"…"}}` with exit 1; usage errors exit 64
- **List notes**: annotate any list/group/smart list with a purpose via `note` (Apple has no description field); agents use them to understand list semantics; `setup --accept` generates candidates non-interactively
- **Skill**: `remindkit install-skill` installs to `~/.claude/skills` + `~/.agents/skills` for auto-discovery

## Fields only ReminderKit provides

| Capability | Field | Notes |
|---|---|---|
| Tags | `reminders[].tags` | not exposed by EventKit |
| Sections | `reminders[].section` / `calendars[].sections` | macOS 26+ |
| Subtasks | `reminders[].parentId` / `.subtaskIds` | tree structure |
| Flagged / Urgent | `flagged` / `urgent` | |
| Icons / Colors | `calendars[].icon` / `.color` | list emoji + hex |
| Groups | `calendars[].isGroup` / `.parentUUID` | folder structure |
| Smart lists | `smartLists[]` | system (today/flagged/completed/assigned) + custom; system views excluded by default |
| Early/location alarms | `reminders[].alarms` | date/interval/dueDateDelta/location |
| Global ordering | `listIDsOrdering` | sidebar order |

## Write operations

```bash
# Tasks: add/update/complete/delete/move (ReminderKit write primary, EventKit fallback)
remindkit add "buy milk" --list 日常 --due "2026-08-03 09:00" --priority high \
  --repeat weekly --days mon,wed --tag 购物 --urgent --flagged \
  --notes "note" --url "https://…" --alarm-before 30
remindkit update <id> --title "new title" --due "2026-08-15 15:30" --priority medium --tag 生活
remindkit complete <id>          # recurring reminders roll to the next occurrence; response includes nextOccurrence
remindkit delete <id>            # soft delete → Recently Deleted (system purges after 30 days)
remindkit move <id> --to 日常

# Hierarchy: group → list → section → task
remindkit add-group "工作"
remindkit add-list "项目A" --group "工作"
remindkit add-section "项目A" "待办"
remindkit add "写周报" --list "项目A" --section "待办"

# Bulk
remindkit bulk --op complete --list 日常 --due-before 2026-08-02   # preview with --dry-run first
```

> **Safety**: lists with duplicate names (e.g. two 「数码」「财务」) must be addressed by ID; `delete-list` requires `--yes` (permanent); test writes only on 「测试冒烟*」 lists (create & clean up, zero leftovers).

## Output format

Unified JSON schema (`dump` full export):

```json
{
  "version": 1,
  "source": "reminderKit",        // reminderKit | eventKit
  "calendars": [{ "id": "…", "title": "工作", "isGroup": false, "icon": "💼",
                  "color": "#007aff", "sections": ["重要"], "parentUUID": null, "order": 0 }],
  "reminders": [{ "id": "…", "calendarId": "…", "title": "买牛奶", "completed": false,
                  "priority": 0, "dueDate": 1785859200, "dueDateText": "2026-08-05 00:00",
                  "tags": ["购物"], "flagged": true, "urgent": false,
                  "section": "待办", "parentId": null, "subtaskIds": [] }],
  "smartLists": [{ "uuid": "…", "name": "想买", "type": "custom", "filterData": "…" }],
  "listIDsOrdering": ["uuid1", "uuid2"]
}
```

## Development

```bash
make build         # build all (ObjC subprocess + Swift CLI)
make test          # smoke test (needs real permission, run locally) + skill contract test
./scripts/package.sh   # package release tarball
```

- Architecture below; **test discipline**: any write test runs only on a freshly-created 「测试冒烟*」 list/group, self-cleaned, zero leftovers at the end

## Architecture

```
ReminderKit subprocess (ObjC, dlopen private framework)  ─┐  ← primary: full fields
                                                          ├─ unified JSON stdout
EventKit main process (Swift, public API)           ──────┘  ← fallback: basic data
```

EventKit and ReminderKit conflict over XPC (cannot share a process), so the CLI uses an independent subprocess: ReminderKit outputs every field; EventKit falls back to core fields. The `source` field tells you which one backed the export.

## License

MIT (with a private-framework disclaimer, see [LICENSE](LICENSE))
