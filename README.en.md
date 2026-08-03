# remindkit — Apple Reminders data pipeline CLI

[中文版](README.md)

[中文版](README.md)

remindkit is a macOS command-line tool that exports structured data from Apple Reminders. It unifies data extraction from the public EventKit API and the private ReminderKit framework.

## Background

Data like tags, sections, icons, list groups, and smart lists **cannot** be fetched through the public EventKit API — only the private `ReminderKit.framework` exposes them. Because EventKit and ReminderKit have an XPC conflict (they cannot coexist in one process), remindkit uses a separate subprocess architecture:

```
ReminderKit subprocess (ObjC, dlopen private framework)  ─┐  ← primary source (full data)
                                                          ├─ unified JSON output
EventKit main process (Swift, public API)          ──────┘  ← fallback (when subprocess unavailable)
```

**Data source policy: ReminderKit first, EventKit as fallback.** The subprocess emits every field through the private framework (subtasks, tags, sections, icons, colors, smart lists, …) and is the complete data source. When the subprocess is missing or fails, remindkit degrades to the public EventKit API and outputs the basic dataset (no rich fields), with a notice on stderr. Each export's `source` field tells you which source backed it.

## Data that EventKit cannot provide (ReminderKit only)

| Capability | Field | Notes |
|------------|-------|-------|
| Tags | `reminders[].tags` | e.g. "shopping"; not exposed by EventKit |
| Sections | `reminders[].section` / `calendars[].sections` | Section structure inside a list (macOS 26+) |
| Subtasks | `reminders[].parentId` / `.subtaskIds` | Subtask tree structure |
| Flagged | `reminders[].flagged` | Star/flag state |
| Urgent | `reminders[].urgent` | Urgent marker |
| Icon | `calendars[].icon` | List emoji icon (badgeEmblem) |
| Color | `calendars[].color` | List hex color (REMColor) |
| Groups | `calendars[].isGroup` / `.parentUUID` | List groups (folders) |
| Ordering | `calendars[].order` / `reminders[].order` | UI order of lists and reminders |
| Smart lists | `smartLists[]` | Smart list definitions and filter conditions |
| Global ordering | `listIDsOrdering` | Sidebar ordering of all lists |
| Alarms | `reminders[].alarms` | Four trigger types: date / interval / due-date-delta / location |
| Location reminder | `reminders[].alarms[].location` | Arrive/leave alerts with lat/lon |
| URL | `reminders[].url` | Stored as an attachment (REMURLAttachment) |
| All-day | `reminders[].allDay` | All-day flag |
| Time zone | `reminders[].timeZone` | Reminder time zone |

## Installation

```bash
# Homebrew
brew install hiauhong/tap/remindkit

# Or from GitHub Releases
curl -L https://github.com/hiauhong/remindkit/releases/latest/download/remindkit \
  -o /usr/local/bin/remindkit && chmod +x /usr/local/bin/remindkit

# Or the install script (local build or GitHub Release)
./scripts/install.sh

# Teach your agent how to use remindkit
remindkit install-skill
```

> Installation ships three parts: the `remindkit` main CLI, the `fetch-remindkit` subprocess binary (must sit next to the main CLI), and the `.agents/skills/remindkit/` skill source. Packaging: `./scripts/package.sh`.

## Usage

```bash
# Export everything (unified JSON)
remindkit dump > reminders.json

# Targeted queries (agent-friendly; default = incomplete only,
# --completed = completed only, --all = everything)
remindkit today                      # due today (incomplete)
remindkit today --include-overdue    # including overdue incomplete
remindkit overdue                    # overdue (incomplete)
remindkit search "milk"              # search title/notes (incomplete)
remindkit search "milk" --all        # search everything (incl. completed)
remindkit show --tag shopping        # filter by tag
remindkit show --due-before 2026-08-01 --due-after 2026-07-01
remindkit show --flagged --urgent --completed
remindkit count --list work          # per-list stats (incomplete/completed explicit)

# All query commands support --format json|plain|count
remindkit today --format json
remindkit show --list work --format count
remindkit count

# Permission diagnosis (essential for agents)
remindkit doctor                       # permission/host/subprocess status
remindkit doctor --for-agent --json    # agent host context + JSON

# Teach an AI agent about remindkit
remindkit install-skill                # installs to ~/.claude/skills + ~/.agents/skills
remindkit install-skill --force        # overwrite an existing skill

# Subcommand help
remindkit --help
remindkit dump --help
```

## Field and list support matrix

### Reminder fields (read/write, verified against real data)

| Field | Read | Write (`add`) | Notes |
|-------|:---:|:---:|-------|
| Title | ✅ | ✅ | |
| Notes | ✅ | ✅ `--notes` | |
| URL | ✅ | ✅ `--url` | Stored as attachment (REMURLAttachment) |
| Date | ✅ | ✅ `--due YYYY-MM-DD` | No time = all-day |
| Time | ✅ | ✅ `--due YYYY-MM-DD HH:MM` | |
| Urgent | ✅ | ✅ `--urgent` | |
| Recurrence | ✅ | ✅ `--repeat/--every/--days/--until` + complex options (below) | Including repeat-end; `daysOfTheMonth`/`setPositions`/`monthsOfTheYear`/`weekNumber` all verified |
| Alarm (remind me) | ✅ | ✅ `--alarm-at` (absolute) / `--alarm-before N` (N min before due) | Read supports 4 trigger types (date/interval/dueDateDelta/location) |
| List | ✅ | ✅ `--list` | |
| Tags | ✅ | ✅ `--tag` (repeatable) | |
| Flagged | ✅ | ✅ `--flagged` | |
| Priority | ✅ | ✅ `--priority high\|medium\|low` | |
| Location reminder | ✅ | ✅ `--location <place> --latitude X --longitude Y [--proximity arrive\|leave]` | arrive=1 / leave=2 |
| Subtasks | ✅ | ✅ `--parent <id>` | Single level (Apple limitation, no nesting) |
| Messaging trigger | ❌ | ❌ | Not supported yet |
| Image attachment | ❌ | ❌ | Not supported yet (read can detect attachment type) |

> `--alarm-before` is implemented as an absolute-time alarm (due − N minutes). Reminders.app's "remind me before" may read back as a `dueDateDelta` alarm (read is supported). Writing `dueDateDelta` is rejected by remindd (private-framework limitation), so the absolute-time form is used instead — functionally equivalent.

### List types

| Type | Read | Create | Notes |
|------|:---:|:---:|-------|
| Regular list | ✅ | create: ✅ `create-list` / update: ✅ `update-list` (rename/icon/12-color palette) / delete: ✅ `delete-list` (write-protected) | |
| Smart list | ✅ (`dump.smartLists`) | ❌ create; ✅ `delete-list` can delete | Virtual view; includes filterData |
| Group (folder) | ✅ | ❌ | `list --groups` |
| Groceries (shopping list) | ✅ (read as a regular list) | ❌ | Special Reminders.app list type (grocery auto-categorization), creation not supported yet |

## Write operations

The write path mirrors the read path: **ReminderKit private-framework writes first, EventKit writes as fallback**. Fields EventKit cannot write (tags, urgent, flagged, subtasks, …) can all be created via ReminderKit. All write operations work directly — there is no write protection:

```bash
remindkit add "buy milk" --list 测试列表 --due "2026-08-03 09:00" --priority high \
  --repeat weekly --days mon,wed --until 2026-12-31 --notes "note" \
  --tag shopping --tag life --urgent --flagged --parent <parentID> \
  --url "https://example.com" --alarm-before 30 \
  --location "Shenzhen Bay" --latitude 22.52 --longitude 113.94 [--proximity arrive|leave]
remindkit complete <id>            # complete (--reopen to un-complete)
remindkit delete <id>              # delete (soft delete → Recently Deleted)
remindkit move <id> --to 测试列表2
remindkit create-list "New list"      # create a list
remindkit update-list "测试列表2" --new-name "测试列表3" --icon 🚀 --color red  # rename/icon/color (12-color palette)
# Same-named lists (e.g. two 财务) must use IDs:
#   remindkit add ... --list-id <id>  /  remindkit move <id> --to-id <id>
#   remindkit update-list --id <id> --color green  /  remindkit delete-list --id <id>
remindkit delete-list "测试列表2"   # delete a test list (regular/smart, write-protected)
remindkit recently-deleted         # list recently deleted (deleted via remindkit, still restorable)
remindkit restore <id>             # restore to its original list (--list / --list-id to target)

```

> `add` options: `--notes` / `--due` (`YYYY-MM-DD` all-day | `YYYY-MM-DD HH:MM`) / `--start` / `--priority high|medium|low` / `--repeat daily|weekly|monthly|yearly` / `--every N` / `--days mon,tue,…` / `--until` / `--tag` (repeatable) / `--urgent` / `--flagged` / `--parent <id>` (subtask) / `--url` / `--alarm-at "YYYY-MM-DD HH:MM"` (repeatable, absolute-time alarm) / `--alarm-before N` (N minutes before due) / `--location <place> --latitude X --longitude Y [--proximity arrive|leave]` (location reminder).
> Frequencies: `hourly` / `daily` / `weekdays` / `weekends` / `weekly` (with `--days` to pick weekdays) / `monthly` / `yearly`.
> Complex recurrence: `--repeat monthly --on-day 15` (15th of month) / `--repeat monthly --last-workday` (last workday) / `--repeat yearly --months 3,8 --on-weekday sun:1` (1st Sunday of March & August; `sun:1` = 1st Sunday, `mon` = every Monday).
> Interval & end: `--every N` (e.g. `--repeat monthly --every 3` = every 3 months) / `--until YYYY-MM-DD`.
> When `--repeat` is given without `--due`, the next matching date is computed automatically as the first due date (consistent with Reminders.app — a repeating reminder must be anchored to a due date to display correctly).
> Write responses carry a `source` field: `reminderKit` (primary) or `eventKit` (fallback, with `degraded: true` when tags/urgent/subtasks were not written).
> Note: ReminderKit's `move` is copy + delete, so the reminder gets a **new ID** (the response returns the new `id` and the old `movedFromId`).

## Delete and Recently Deleted

`delete` is a **soft delete** (consistent with Reminders.app — it goes to "Recently Deleted", purged by the system after ~30 days, and can be restored manually in the app). The CLI records reminders it deleted to `~/.local/share/remindkit/deleted.json`:

- `recently-deleted`: lists reminders still in the deleted state (status is verified against ReminderKit on every query; items restored or purged in the app are filtered out automatically)
- `restore <id> [--list <target>] [--list-id <id>]`: restores to the original list (default) or a chosen list; the ID stays the same
- Query `--list` filters (`show` / `search` / `count`) match exact name or ID first, so `财务` never bleeds into `财务选题`.

> Limitation: ReminderKit has no "enumerate recently deleted" API, so only reminders deleted via remindkit are tracked. Reminders deleted in the Reminders.app are not listed here (check the app for those).

## Query semantics (unified convention)

All query commands (`today` / `overdue` / `search` / `show`) return **incomplete** reminders by default; the three completion-state flags are mutually exclusive (`--completed` and `--all`):

| Flag | Behavior |
|------|----------|
| (default) | incomplete only |
| `--completed` | completed only |
| `--all` | everything (incomplete + completed) |

`count` has no such flags — it always reports both `incomplete` and `completed` explicitly:

```json
{"total": 12, "incomplete": 8, "completed": 4, "flagged": 1, "urgent": 0, "dueToday": 3, "overdue": 2}
```

## Error contract

Runtime errors (e.g. permission denied) go to **stderr** as structured JSON (stdout carries data only), exit code `1`; usage errors (missing args, mutual exclusivity, invalid dates) exit with code `64`:

```json
{"error": {"code": "accessDenied", "message": "Apple Reminders access denied (host: zsh). ..."}}
```

`doctor` uses a non-prompting API to check permission state and reports the **responsible process (host)** — the TCC grant belongs to the host app, not to the remindkit binary. See `docs/macos-permissions.md`.

## Output format

```json
{
  "version": 1,
  "exportedAt": "2026-07-30T12:00:00Z",
  "source": "reminderKit",   // "reminderKit" (default) | "eventKit" (fallback)

  "calendars": [
    {
      "id": "EKCalendar.calendarIdentifier",
      "title": "work",
      "isGroup": false,
      "icon": "💼",
      "color": "#007aff",
      "sections": ["Important", "To do"],
      "parentUUID": null,
      "order": 0
    }
  ],

  "reminders": [
    {
      "id": "EKReminder.calendarItemIdentifier",
      "calendarId": "associated calendar.id",
      "title": "buy milk",
      "notes": "",
      "completed": false,
      "priority": 0,
      "dueDate": null,
      "tags": ["shopping"],
      "flagged": true,
      "urgent": false,
      "order": 0,
      "section": "To do",
      "parentId": null,
      "subtaskIds": []
    }
  ],

  "smartLists": [
    {
      "uuid": "REMList.objectID UUID",
      "name": "Today",
      "filterData": "JSON string",
      "icon": "📅",
      "color": null
    }
  ],

  "listIDsOrdering": ["uuid1", "uuid2"]
}
```

## Development

```bash
# Build the ObjC subprocess binary
make build-cbinary

# Build the Swift CLI
make build-cli

# Build everything
make build
```

## Architecture

```
Sources/
├── remindkit/               # Swift CLI entry (main process)
│   ├── main.swift           # ArgumentParser entry
│   ├── DumpCommand.swift    # dump: subprocess first, EventKit fallback
│   ├── Merging.swift        # data-source selection + unified schema mapping
│   └── Models.swift         # unified JSON schema types
└── CReminderKit/            # ObjC sources (private framework, standalone build)
    └── fetch-remindkit.m
```

## License

MIT
