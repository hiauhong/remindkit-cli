import ArgumentParser
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Annotate every list: structure-only evaluation (default) or lists+contents (--deep), confirm, save, print ordered structure with notes"
    )

    @Flag(name: .long, help: "Non-interactive: print setup state and exit (agent-friendly)")
    var status: Bool = false

    @Flag(name: .long, help: "Also read each list's reminders for a content-based evaluation (slower, more accurate)")
    var deep: Bool = false

    @Flag(name: .long, help: "Non-interactive: accept candidate notes and save without confirmation (agent-friendly; only fills lists without a note)")
    var accept: Bool = false

    func run() throws {
        let notesStore = NotesStore(fileURL: NotesStore.defaultURL())
        let convStore = ConventionsStore(fileURL: ConventionsStore.defaultURL())

        if status {
            try printStatus(notesStore, convStore)
            return
        }

        guard accept || isInteractive() else {
            fail("nonInteractive",
                 "`setup` is interactive; run it in a terminal, or use `setup --accept` to save candidate notes non-interactively, or check state with `setup --status`.")
        }

        // Default reads structure only (never touches reminder contents);
        // --deep reads lists + their reminders for a richer evaluation.
        let data = deep ? fetchEnrichedData(includeSections: true) : fetchListStructure()
        if accept {
            try runSetupAccept(notesStore, data, deep: deep)
        } else {
            try runSetup(notesStore, data, deep: deep)
        }
    }

    // MARK: - The setup flow: read → evaluate → confirm → save → print structure

    private func runSetup(_ notesStore: NotesStore, _ data: EnrichedData, deep: Bool) throws {
        let all = data.calendars
        let lists = all.filter { !$0.isGroup }
        let groups = all.filter { $0.isGroup }
        let byParent = Dictionary(grouping: lists) { $0.parentUUID }

        // Display order: each folder followed by its lists, then top-level.
        var ordered: [CalendarEntry] = []
        for g in groups { ordered.append(contentsOf: byParent[g.id] ?? []) }
        ordered.append(contentsOf: byParent[nil] ?? [])
        let covered = Set(ordered.map(\.id))
        ordered.append(contentsOf: lists.filter { !covered.contains($0.id) })

        var notes = notesStore.load()
        var edited: [String: String] = [:]   // listID -> user-confirmed text

        let emptyHint = deep ? "" : "（空——可运行 `setup --deep` 读内容评估）"

        while true {
            print("── 我对你的列表的理解\(deep ? "（含列表内容）" : "（仅列表结构）") ──")
            var n = 0
            for g in groups {
                print("📁 \(g.title)")
                for l in (byParent[g.id] ?? []) {
                    n += 1
                    print(line(n, l, notes, edited, data, deep: deep, emptyHint: emptyHint))
                }
            }
            let top = byParent[nil] ?? []
            if !top.isEmpty {
                print("• 顶层")
                for l in top {
                    n += 1
                    print(line(n, l, notes, edited, data, deep: deep, emptyHint: emptyHint))
                }
            }
            print()
            print("[回车] 全部确认保存 ｜ N 文案 = 改第 N 个（仅 N = 清除） ｜ q = 退出不保存")
            guard let input = readLine() else { return }
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            if trimmed == "q" || trimmed == "quit" { return }

            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let numStr = parts.first, let idx = Int(numStr), idx >= 1, idx <= ordered.count else {
                print("  ✗ 没看懂：输入编号（如 `3 想买的数码产品`）或直接回车确认。")
                continue
            }
            let list = ordered[idx - 1]
            let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if rest.isEmpty {
                edited.removeValue(forKey: list.id)
                notes.removeValue(forKey: list.id)
                print("  ✓ 已清除「\(list.title)」的备注")
            } else {
                edited[list.id] = rest
                print("  ✓ 已设置「\(list.title)」：\(rest)")
            }
        }

        // Save: user-confirmed text wins; untouched lists get the candidate
        // (skipped when empty — e.g. a structure-only pass on a bare list).
        try saveAndPrint(notesStore, ordered, data, deep: deep, edited: edited)
    }

    /// 非交互接受：直接保存候选备注（仅填充还没有备注的列表，不覆盖已有），
    /// 打印与交互版相同的结构结果。agent 环境无需 TTY。
    private func runSetupAccept(_ notesStore: NotesStore, _ data: EnrichedData, deep: Bool) throws {
        try saveAndPrint(notesStore, orderedCalendars(data), data, deep: deep)
    }

    /// 列表显示顺序：每个分组下的列表，然后是顶层，最后兜底。
    private func orderedCalendars(_ data: EnrichedData) -> [CalendarEntry] {
        let lists = data.calendars.filter { !$0.isGroup }
        let groups = data.calendars.filter(\.isGroup)
        let byParent = Dictionary(grouping: lists) { $0.parentUUID }
        var ordered: [CalendarEntry] = []
        for g in groups { ordered.append(contentsOf: byParent[g.id] ?? []) }
        ordered.append(contentsOf: byParent[nil] ?? [])
        let covered = Set(ordered.map(\.id))
        ordered.append(contentsOf: lists.filter { !covered.contains($0.id) })
        return ordered
    }

    /// 保存（edited 优先 → 已有保留 → 候选填空）并打印带备注的结构。
    private func saveAndPrint(_ notesStore: NotesStore, _ ordered: [CalendarEntry], _ data: EnrichedData,
                              deep: Bool, edited: [String: String] = [:]) throws {
        var notes = notesStore.load()
        for l in ordered {
            if let text = edited[l.id] {
                notes[l.id] = text
            } else if notes[l.id] == nil {
                let c = candidate(l, data, deep: deep)
                if !c.isEmpty { notes[l.id] = c }
            }
        }
        try notesStore.save(notes)

        let groups = data.calendars.filter(\.isGroup)
        let byParent = Dictionary(grouping: data.calendars.filter { !$0.isGroup }) { $0.parentUUID }
        let emptyHint = deep ? "" : "（空——可运行 `setup --deep` 读内容评估）"

        // Final: the ordered structure (folders included) with notes attached.
        print("\n✓ 已保存 \(notes.count) 条列表备注到 \(notesStore.fileURL.path)")
        print("\n── 列表结构（带备注） ──")
        for g in groups {
            print("📁 \(g.title)")
            for l in (byParent[g.id] ?? []) {
                let noteText = notes[l.id] ?? (emptyHint.isEmpty ? "" : emptyHint)
                print("   - \(l.title)  「\(noteText)」")
            }
        }
        for l in (byParent[nil] ?? []) {
            print("• \(l.title)  「\(notes[l.id] ?? "")」")
        }
        print("\n（之后可用 `note` 命令或 `setup` / `setup --deep` / `setup --accept` 随时修改）")
    }

    // MARK: - Helpers

    private func line(_ n: Int, _ l: CalendarEntry, _ notes: [String: String],
                      _ edited: [String: String], _ data: EnrichedData,
                      deep: Bool, emptyHint: String) -> String {
        let confirmed = edited[l.id] ?? notes[l.id]
        let text = confirmed ?? candidate(l, data, deep: deep)
        let marker = confirmed != nil ? "✓" : (notes[l.id] != nil ? "•" : " ")
        let shown = text.isEmpty ? emptyHint : text
        return "\(n). \(l.title) [\(marker)]  \(shown)"
    }

    /// Structure-only evaluation (default): sections, folder, icon.
    /// Content-based evaluation (--deep): counts, sections, tags, samples.
    private func candidate(_ l: CalendarEntry, _ data: EnrichedData, deep: Bool) -> String {
        deep ? contentCandidate(l, data) : structureCandidate(l, data)
    }

    private func structureCandidate(_ l: CalendarEntry, _ data: EnrichedData) -> String {
        var parts: [String] = []
        if let secs = l.sections, !secs.isEmpty {
            parts.append("分区[\(secs.joined(separator: "/"))]")
        }
        if let pu = l.parentUUID, let group = data.calendars.first(where: { $0.id == pu }) {
            parts.append("位于「\(group.title)」")
        }
        if let icon = l.icon, !icon.isEmpty {
            parts.append("图标\(icon)")
        }
        return parts.joined(separator: " ｜ ")
    }

    private func contentCandidate(_ l: CalendarEntry, _ data: EnrichedData) -> String {
        let r = data.reminders.filter { $0.calendarId == l.id }
        var parts = [countsLine(r)]
        if let secs = l.sections, !secs.isEmpty {
            parts.append("分区[\(secs.joined(separator: "/"))]")
        }
        let tags = topTags(r, limit: 3)
        if !tags.isEmpty { parts.append("标签[\(tags.joined(separator: ","))]") }
        let samples = r.filter { !$0.completed }.prefix(2).map(\.title)
        if !samples.isEmpty { parts.append("例[\(samples.joined(separator: "、"))]") }
        return parts.joined(separator: " ｜ ")
    }

    private func countsLine(_ reminders: [ReminderEntry]) -> String {
        let total = reminders.count
        let incomplete = reminders.filter { !$0.completed }.count
        return "\(incomplete)/\(total) 未完成"
    }

    private func topTags(_ reminders: [ReminderEntry], limit: Int) -> [String] {
        var freq: [String: Int] = [:]
        for r in reminders {
            for t in r.tags ?? [] { freq[t, default: 0] += 1 }
        }
        return freq.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    private func printStatus(_ notesStore: NotesStore, _ convStore: ConventionsStore) throws {
        let notes = notesStore.load()
        let conv = convStore.load()
        let payload: [String: Any] = [
            "notesConfigured": !notes.isEmpty,
            "notesCount": notes.count,
            "notesFile": notesStore.fileURL.path,
            "conventionsConfigured": conv != nil,
            "conventionsFile": convStore.fileURL.path,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(data: json, encoding: .utf8) ?? "{}")
        print()
        if notes.isEmpty {
            print("remindkit: 还没有列表备注。跑 `remindkit setup`（仅结构）或 `setup --deep`（含内容）为每个列表记录用途。")
        } else {
            print("remindkit: 已有 \(notes.count) 条列表备注（\(notesStore.fileURL.path)）")
        }
        if conv == nil {
            print("remindkit: 可选约定文件 conventions.md 未配置（需要跨列表方法论时手动创建）。")
        }
    }

    private func isInteractive() -> Bool {
        isatty(FileHandle.standardInput.fileDescriptor) != 0
    }
}
