# remindkit — Apple Reminders data pipeline CLI

[![Vibe coded](https://img.shields.io/badge/vibe-coded-%23ff69b4?style=flat-square)](https://en.wikipedia.org/wiki/Vibe_coding)

[中文版](README.md)

remindkit is a macOS command-line tool that exports structured data from Apple Reminders and supports **the full hierarchy, read and write** — list folders → lists → sections → tasks → subtasks, all five levels. **Designed for AI agents**: unified JSON output, machine-parseable error contract, and a bundled agent skill.


> 🎨 This project is **vibe coded** (AI-assisted development) — features, tests, and docs are all iterated in collaboration with an AI agent.

> **⚠️ Disclaimer** — reads Apple's **private framework** `ReminderKit.framework`; unsupported by Apple, may break with any macOS update; not affiliated with Apple Inc.; for personal use and study only.

> **🔒 Privacy**
> - All data is processed **locally**: the CLI makes no network requests and uploads nothing (sensitive reminder content — bills, health, locations — never leaves your machine).
> - Requires “Reminders” access via TCC; grant it from the system prompt on first run. Permission belongs to the host process.

## Full hierarchy: list folder → list → section → task → subtask

All five levels of the Apple Reminders hierarchy, **readable and writable** — exactly what the public EventKit API can't do:

```
List folder (group)                    ← add-group
 └── List (calendar)                   ← add-list --group
      ├── Section (macOS 26+)          ← add-section
      └── Task (reminder)              ← add --list / --section
           └── Subtask (nests arbitrarily deep) ← add --parent <id>
```

- **Read**: `dump` / `list --groups` / `list --format json` output every level; fields map 1:1 — `isGroup` / `parentUUID` (folders), `sections`, `parentId` / `subtaskIds` (subtask tree)
- **Write**: build top-down — `add-group` → `add-list --group` → `add-section` → `add --section` → `add --parent`; `move` re-parents between any levels

## Features

- **Structured JSON export**: lists, groups (folders), sections, subtasks, tags, flags, urgent, smart lists — including fields the public EventKit API **cannot** provide (matrix below)
- **Full write hierarchy**: all five levels — groups, lists, sections, tasks, **subtasks** (add/update/complete/delete/move) + smart lists
- **Dual-source architecture**: ReminderKit private framework as the primary source, EventKit public API as fallback; every export carries a `source` field
- **Agent-first**: JSON output by default, unified error contract (stderr JSON + exit codes), `--fields` projection to save tokens, one-command skill install


## Install

```bash
brew install hiauhong/tap/remindkit
# or
./Scripts/install.sh     # auto-registers the agent skill after install
```

## First run: grant permission + backup

```bash
remindkit doctor                        # ① check permission (first run pops the authorization dialog — click "Allow")
remindkit dump > ~/reminders-backup.json   # ② take a full baseline backup first
```

> Permission belongs to the host process (terminal / agent host); before any write operations (complete/delete/move/bulk), you can dump again and diff against the baseline for peace of mind.

## Quick start

```bash
remindkit                # overview: today / overdue / upcoming / flagged / urgent
remindkit today          # due today
remindkit overdue        # overdue
remindkit search "milk"  # search
remindkit add "buy milk" --list 待办 --due "2026-08-03 09:00"
remindkit complete <id>  # complete
```

## For AI agents

- Query commands return **incomplete only** by default; `--all` / `--completed` toggle
- JSON output by default; errors to stderr as JSON `{"error":{...}}` + exit codes (1 runtime / 64 usage)
- Full write hierarchy: list folders → lists → sections → tasks → subtasks; incl. tags / flag / urgent / smart lists / batch
- Bundled skill: auto-registered after install; agents scan `~/.agents/skills/` and auto-discover
- Full options: `remindkit <command> --help`; agent details in [.agents/skills/remindkit/SKILL.md](.agents/skills/remindkit/SKILL.md)
- Support matrix (✅ full / 🟡 limited / ❌ not supported — e.g. grocery lists, templates, image attachments): [docs/apple-reminders-support.en.md](docs/apple-reminders-support.en.md)

## Safety

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

# Hierarchy: list folder → list → section → task → subtask
remindkit add-group "工作"                              # ① folder (group)
remindkit add-list "项目A" --group "工作"                # ② list
remindkit add-section "项目A" "待办"                     # ③ section
remindkit add "写周报" --list "项目A" --section "待办"    # ④ task
remindkit add "整理大纲" --list "项目A" --parent <写周报的ID>   # ⑤ subtask (nests further)

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
make build    # build all (ObjC subprocess + Swift CLI)
make test     # smoke test + skill contract test
```

## License

MIT (with a private-framework disclaimer, see [LICENSE](LICENSE))
