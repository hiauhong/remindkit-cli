# remindkit × Apple Reminders support matrix

> Evaluation of how much of Apple Reminders remindkit supports. Status legend:
> ✅ fully supported ｜ 🟡 partial / limited ｜ ❌ not supported
>
> [中文版](apple-reminders-support.md)
>
> Last updated: 2026-08-03 (when hierarchical writes landed)

## 1. List layer

| Apple feature | Status | Notes |
|---------|------|------|
| Regular list | ✅ | Read (`list`), create (`add-list`), rename/icon/color (`update-list`), delete (`delete-list --yes`) |
| List icon (emoji) | ✅ | Read + `update-list --icon` |
| List color | ✅ | Read + `update-list --color` (12-color palette) |
| Group (smart folder) | ✅ | **Read** fully (`list --groups`, parentUUID ownership); **write**: `add-group` creates, `add-list --group` files into, `delete-list` removes (verified: group = REMAccountGroupContext, no REMGroup class; Apple folders don't nest — single level) |
| Smart list | ✅ | **Read** (smartLists field); **write**: `add-smartlist [--color]`; deletion via `delete-list` |
| Grocery list | ❌ | Apple's "Grocery" list type (auto-categorizes items: produce / dairy / baked goods, etc.) relies on ReminderKit category fields — **categories are not readable and the list type can't be created**; it can only be read as a plain list (titles/items visible, no category grouping) |
| Sections | ✅ | **Read** (`[N sections]`); **write**: `add-section <list> <name>` creates; `add --section` / `update --section` file reminders into a section (REMMembership path) |
| List ordering | 🟡 | Display order preserved on read; **write ordering not supported** |

## 2. Reminder field layer

| Field | Status | Notes |
|------|------|------|
| Title / notes | ✅ | Read/write (`add`/`update --title/--notes`) |
| Due date | ✅ | `--due "YYYY-MM-DD"` (all-day) or `"YYYY-MM-DD HH:MM"` |
| Start date | ✅ | `--start` |
| All-day | 🟡 | Read fully; write inferred from date format (no time = all-day) |
| Time zone | 🟡 | Read fully; **write not supported** (setting it crashes remindd — private-framework pitfall, verified) |
| Recurrence | ✅ | `--repeat daily/weekly/monthly/yearly` + `--every/--days/--until`; complex rules: `--on-day`, `--last-workday`, `--months + --on-weekday` (first week of year/month) |
| Tags | ✅ | Read/write (`--tag` repeatable); `tags` command for stats, `search` can match tags |
| Priority | ✅ | `--priority high/medium/low` (maps to 9/5/0) |
| Flag | ✅ | Read/write (`update --flag/--no-flag`); `flagged` is a first-class command |
| Urgent | ✅ | Read/write (`update --urgent/--no-urgent`); `urgent` is a first-class command |
| URL | ✅ | Read/write (as URL attachment) |
| Alarm — absolute time | ✅ | `--alarm-at "YYYY-MM-DD HH:MM"` (repeatable) |
| Alarm — N min before | ✅ | `--alarm-before N` (relative to due or current dueDate) |
| Alarm — location | ✅ | `--location + --latitude/--longitude [--proximity arrive/leave]` |
| Subtasks | 🟡 | Read fully (parentId/subtaskIds); write `add --parent`; **nesting is natively unsupported by Apple** (errors with `Nested subtasks is unsupported` — one level of parent→child only) |
| Completion state | ✅ | `complete <id>` / `complete <id> --reopen` |
| Order | 🟡 | Read fully; **write not supported** |
| Image attachments | ❌ | Not supported (evaluated, low frequency) |
| "Remind when messaging" | ❌ | Not supported (low frequency) |

## 3. Operation layer

| Operation | Status | Notes |
|------|------|------|
| Create / edit | ✅ | `add` full fields; `update` fields + flag/urgent + alarms |
| Complete / reopen | ✅ | `complete [--reopen]` |
| Delete | ✅ | Soft delete → Recently Deleted (system purges after 30 days) |
| Recently Deleted query | 🟡 | `recently-deleted` only lists what **remindkit deleted** (local cache); items deleted in the App are invisible |
| Restore | 🟡 | `restore` same — only remindkit-deleted items |
| Move | ✅ | true re-parent via `addReminderChangeItem:` — **ID preserved**, whole subtree moves |
| Batch | ✅ | `bulk --op complete/delete/move/update` + condition selection + `--dry-run` + `--limit` |

## 4. View layer (aligned with App first-class entries)

| Apple entry | Command | Notes |
|---------|------|------|
| Today | `today` | `--include-overdue` to include past due |
| Scheduled | `scheduled` | `--within N` / `--from/--to` range |
| Flagged | `flagged` | Incomplete flagged |
| Urgent | `urgent` | Incomplete urgent |
| All | `dump` / `query --all` | `dump` exports full JSON |
| Completed | `query --completed` | Uniformly supported across query commands |
| Overview (tool-specific) | `overview` | One-call summary: today / overdue / upcoming / flagged focus / urgent — default command |

## 5. System / extension layer

| Capability | Status | Notes |
|------|------|------|
| Permission diagnosis | ✅ | `doctor` (access state + remediation hints) |
| Read-only guard | ✅ | `REMINDKIT_READ_ONLY=1` rejects all writes |
| Data export | ✅ | `dump` (unified JSON, all fields) |
| User profile (tool-specific) | ✅ | `setup` (structure only) / `setup --deep` (incl. contents) annotates every list + optional `conventions.md` sidecar |
| Tag view | ✅ | `tags` command (tags + counts) |
| Full-library search | ✅ | `search` title/notes/tags |
| Fuzzy list resolution | ✅ | UUID prefix / exact title / substring + `noSuchList` error |
| Output format | ✅ | Auto json/plain by TTY; `count --format plain` |
| Test discipline | ✅ | Smoke tests only touch self-created 「测试冒烟*」 lists/groups/smart lists (create+delete, zero-residue check) — never writes real lists |
| Cross-device sync | — | Data syncs naturally via iCloud; this tool only reads the local machine |
| Collaboration / shared lists | ❌ | Not supported |
| Templates (iOS 17+) | ❌ | Not supported |
| Grocery categorization | ❌ | See §1: grocery list category grouping is neither readable nor creatable |

## 6. Known limitations (by impact)

1. **Incomplete Recently Deleted restore**: only remindkit-deleted items can be restored (local `deleted.json` cache); items deleted in the App cannot. ReminderKit cannot enumerate marked-for-delete objects.
2. **EventKit fallback degradation**: when the subprocess is unavailable, tags/recurrence/flag/urgent/sections/groups/smart lists are not writable (response marks `degraded: true`).
3. **move preserves IDs**: true re-parent (no copy+delete); keep referencing the same id after moving.
4. **Subtask nesting**: one parent→child level works; deeper nesting unverified/unsupported.
5. **Write-side gaps**: time zone (crashes remindd), order, images, message reminders, templates, collaboration, grocery lists (category grouping).
6. **Subtask nesting**: Apple's framework natively errors with `Nested subtasks is unsupported` — one level only.

## 7. Conclusion

**Read side ≈ 100%**: nearly every Apple Reminders field is readable (incl. subtasks, location, recurrence, time zone, smart lists).

**Write side covers the full hierarchy**: folder (`add-group`) → list (`add-list [--group]`) → section (`add-section` + `add/update --section`) → task (`add`/`update`/`complete`) → subtask (`add --parent`) — all wired up; everyday use (CRUD, complete, move, batch, tags, flag, urgent, alarms, location, recurrence, smart-list creation) is complete; gaps concentrate in low-frequency / system-level features (images, templates, collaboration) plus two engineering limits (Recently Deleted, move IDs).
