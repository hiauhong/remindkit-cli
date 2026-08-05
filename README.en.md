# remindkit — Apple Reminders data pipeline CLI

[![Vibe coded](https://img.shields.io/badge/vibe-coded-%23ff69b4?style=flat-square)](https://en.wikipedia.org/wiki/Vibe_coding)

[中文版](README.md)

remindkit is a macOS command-line tool that exports structured data from Apple Reminders and supports the full write hierarchy (folders → lists → sections → tasks → subtasks). **Designed for AI agents**: unified JSON output, machine-parseable error contract, and a bundled agent skill.

> 🎨 This project is **vibe coded** (AI-assisted development) — features, tests, and docs are all iterated in collaboration with an AI agent.

> **⚠️ Disclaimer** — reads Apple's **private framework** `ReminderKit.framework`; unsupported by Apple, may break with any macOS update; not affiliated with Apple Inc.; for personal use and study only.

> **🔒 Privacy** — all data processed locally, no network requests; requires "Reminders" access (TCC), grant it from the system prompt on first run.

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

- Lists with duplicate names (e.g. two 「工作」) must be addressed by ID; `delete-list` is permanent and requires `--yes`
- Test writes only on self-created 「测试冒烟*」 lists; created and cleaned up, zero leftovers

## Development

```bash
make build    # build all (ObjC subprocess + Swift CLI)
make test     # smoke test + skill contract test
```

## License

MIT (with a private-framework disclaimer, see [LICENSE](LICENSE))
