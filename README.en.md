# remindkit — manage Apple Reminders from the terminal

[![Vibe coded](https://img.shields.io/badge/vibe-coded-%23ff69b4?style=flat-square)](https://en.wikipedia.org/wiki/Vibe_coding)

[中文版](README.md)

For anyone who uses Apple Reminders on a Mac: one command shows what's due, and you can add, reschedule, complete, or delete without clicking through the app.
Your data stays in Apple Reminders — remindkit only reads and writes it from the terminal; it doesn't replace the app.

> ⚠️ Reads and writes data through Apple's **private framework** `ReminderKit.framework`. Unsupported by Apple, may break with macOS updates; not affiliated with Apple Inc.; for personal use and study only.

> 🔒 All data stays on your machine: remindkit makes no network requests and uploads nothing (bills, health, location reminders never leave your Mac).

## How to use (3 steps)

```bash
# ① Install
brew install hiauhong/tap/remindkit

# ② Grant access: a system dialog appears the first time — click "Allow" (once per terminal)
remindkit authorize --verify

# ③ Start
remindkit                                          # today / overdue / upcoming / flagged / urgent in one screen
remindkit add "buy milk" --list Errands --due "2026-08-05 09:00"   # use your own list name
```

No Homebrew? Run `./Scripts/install.sh` from the repo (installs to `~/.local/bin`, no sudo). Upgrade with `brew upgrade remindkit`.

## What it does

- **See**: `remindkit` gives you today, overdue, upcoming, flagged, and urgent at a glance; `today` / `overdue` / `scheduled` / `flagged` / `urgent` for a closer look.
- **Find and count**: `search` across titles, notes, and tags; `count --by-list` for per-list stats in one call.
- **Change**: add, reschedule, set priority, tag, add alarms, repeat, complete, move, delete, and bulk operations.
- **Structure**: list folder → list → section → task → subtask — all five levels can be created, edited, and moved.
- **Export**: `remindkit dump` prints full JSON, for backups or feeding other tools.

## Common commands

| I want to… | Command |
|---|---|
| See what's due | `remindkit` |
| Due today / overdue | `remindkit today` / `remindkit overdue` |
| Search titles, notes, tags | `remindkit search "milk"` |
| Look inside one list | `remindkit query --list Work` |
| Count, by list | `remindkit count --by-list` |
| Add / complete | `remindkit add "Write report" --list Work --due "2026-08-05 10:00"` / `remindkit complete <id>` |
| Full export / backup | `remindkit dump > ~/reminders-backup.json` |
| Permission trouble | `remindkit doctor` |
| All commands | `remindkit --help` |

> `<id>` comes from any query result. Deletes are soft: they go to Recently Deleted and the system purges them after 30 days.

## Known limitations

- **Requirements**: macOS 14 or later; sections inside a list need macOS 26 or later.
- **Permission**: needs "Reminders" access. The permission belongs to the **app that runs it** (your terminal, or the AI tool's host), not to remindkit itself — switching apps means granting again. Full Disk Access is **not** needed.
- **First grant is manual**: plain queries never pop the dialog; without permission they quietly return empty data, which looks like "no reminders". Running `remindkit authorize --verify` is what triggers it.
- **Sandboxed / restricted AI tools** may report `Mach error 4099`: switch the tool to "Full Access" execution mode, then authorize. This is not the same as macOS Full Disk Access. If the tool has no such mode, authorize from a terminal that can show the dialog.
- **iCloud**: remindkit does not use the network or trigger sync; it reads the Mac's local data (changes not yet synced down won't appear). Shared / collaborative lists are not supported.
- **Not supported**: image attachments, templates, "remind me when I message someone", grocery-list category grouping, writing time zones; subtasks are one level only (Apple's own limit).
- **Recently Deleted / restore** only covers items remindkit deleted; items deleted in the Reminders app are invisible to it.
- Back up before writing: `remindkit dump > ~/reminders-backup.json`.

## For developers

- **Two data sources**: ReminderKit private framework is primary (richest fields), EventKit public API is the fallback; `dump`'s `source` says which one served the data, and degraded responses carry `degraded: true`.
- **Output**: plain text on a terminal, JSON automatically when piped / called by an agent; use `--fields id,title,dueDate` to save tokens.
- **Error contract**: runtime errors → stderr JSON + exit code 1; usage errors → plain text + exit code 64 (don't assume every error is `jq`-parseable).
- **Support matrix** (✅ / 🟡 / ❌ per Apple feature): [docs/apple-reminders-support.en.md](docs/apple-reminders-support.en.md)
- **Agent contract**: [.agents/skills/remindkit/SKILL.md](.agents/skills/remindkit/SKILL.md); every run syncs to `~/.agents/skills/` (`REMINDKIT_NO_AUTO_SKILL=1` disables), Claude Code users: `remindkit install-skill --claude`.
- **Read-only mode**: `REMINDKIT_READ_ONLY=1` rejects all writes. Address duplicate list names by ID; `delete-list` is permanent and needs `--yes`.
- **Build / test**: `make build`; `make test-regressions` day to day, `make test` before a release (the smoke suite needs local Reminders permission and only touches lists it creates, with self-cleanup).

## License

MIT (with a private-framework disclaimer, see [LICENSE](LICENSE)).
