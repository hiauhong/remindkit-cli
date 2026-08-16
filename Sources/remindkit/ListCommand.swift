import ArgumentParser
import EventKitCore
import Foundation

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all reminder calendars/lists"
    )

    @Flag(name: .long, help: "Show groups only")
    var groups: Bool = false

    @Flag(name: .long, help: "Compact structure for agent context: title/group/note/section names (no icons/counts)")
    var brief: Bool = false

    @Flag(name: .long, help: "Include custom smart lists in the output (json: emits a smartLists array; plain/brief: appends a 智能列表 section)")
    var smartLists: Bool = false

    @Option(name: .long, help: "Output format: json, plain, count")
    var format: QueryFormat = .auto()

    func run() throws {
        let data = fetchEnrichedData(includeSections: false)
        let entries = data.calendars
        let smartEntries = data.smartLists.filter { $0.type == "custom" || $0.type == nil }

        let filtered = groups ? entries.filter(\.isGroup) : entries

        if brief {
            // agent 上下文注入用：一次拿全归属决策所需结构（分组层级 + 分区名 + 备注），
            // 无 icon/color/UUID/数量，体积最小化（~4KB）。--groups 同样生效。
            // 自定义智能列表默认附带（agent 结构地图必须看到虚拟视图，否则会以为列表不存在）。
            let notes = NotesStore(fileURL: NotesStore.defaultURL()).load()
            for line in treeLines(entries, groupsOnly: groups, notes: notes, showSectionNames: true, smartLists: smartEntries) {
                print(line)
            }
            return
        }

        switch format {
        case .json:
            // 一次拿全结构（agent 友好）：parentUUID 映射成分组名 parentTitle，附上列表备注 note
            let notes = NotesStore(fileURL: NotesStore.defaultURL()).load()
            let groupsById = Dictionary(uniqueKeysWithValues: entries.filter(\.isGroup).map { ($0.id, $0.title) })
            let output = filtered.map { e in
                ListEntryOutput(e,
                    parentTitle: e.parentUUID.flatMap { groupsById[$0] },
                    note: notes[e.id])
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if smartLists {
                // 兼容包一层：lists + smartLists 数组（避免改变无标志时的既有数组输出契约）
                let container = ListWithSmartListsOutput(lists: output, smartLists: smartEntries)
                let data = try encoder.encode(container)
                print(String(data: data, encoding: .utf8)!)
            } else {
                let data = try encoder.encode(output)
                print(String(data: data, encoding: .utf8)!)
            }
        case .count:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ListCountResult(
                total: entries.count,
                lists: entries.filter { !$0.isGroup }.count,
                groups: entries.filter(\.isGroup).count,
                sections: entries.reduce(0) { $0 + ($1.sections?.count ?? 0) },
                smartLists: smartEntries.count
            ))
            print(String(data: data, encoding: .utf8)!)
        case .plain:
            let notes = NotesStore(fileURL: NotesStore.defaultURL()).load()
            for line in treeLines(entries, groupsOnly: groups, notes: notes, smartLists: smartLists ? smartEntries : []) {
                print(line)
            }
        }
    }
}

/// Render calendars as a real tree: top-level lists, then each group with
/// its children indented under it. Previously every parented list was
/// indented indiscriminately and groups were printed at the end, which
/// made group children look like they belonged to whatever list came
/// before them.
private func treeLines(_ calendars: [CalendarEntry], groupsOnly: Bool, notes: [String: String], showSectionNames: Bool = false, smartLists: [SmartListEntry] = []) -> [String] {
    let groups = calendars.filter(\.isGroup)
    var lines: [String] = []

    if groupsOnly {
        for g in groups {
            lines.append("\(g.icon ?? "📋") \(g.title) 📁")
        }
        if !smartLists.isEmpty {
            lines.append("")
            lines.append("🔍 智能列表:")
            for sl in smartLists {
                let filterTag = smartListFilterTagLabel(sl.filterData)
                let filterText = filterTag.map { " (按标签: \($0))" } ?? ""
                lines.append("  \(sl.icon ?? "🔍") \(sl.name ?? "")\(filterText)")
            }
        }
        return lines
    }

    // Top-level lists (no parent group), in natural order.
    for e in calendars where !e.isGroup && e.parentUUID == nil {
        lines.append(line(for: e, note: notes[e.id], showSectionNames: showSectionNames))
    }
    // Groups, each followed by its children (indented).
    for g in groups {
        lines.append(line(for: g, suffix: " 📁"))
        for child in calendars where child.parentUUID == g.id {
            lines.append("  \(line(for: child, note: notes[child.id], showSectionNames: showSectionNames))")
        }
    }
    // Custom smart lists at the end (virtual views, not filed under groups).
    if !smartLists.isEmpty {
        lines.append("")
        lines.append("🔍 智能列表:")
        for sl in smartLists {
            let filterTag = smartListFilterTagLabel(sl.filterData)
            let filterText = filterTag.map { " (按标签: \($0))" } ?? ""
            lines.append("  \(sl.icon ?? "🔍") \(sl.name ?? "")\(filterText)")
        }
    }
    return lines
}

/// Parse the hashtag filter of a smart list into a display label like "日用品采购".
private func smartListFilterTagLabel(_ filterData: String?) -> String? {
    guard let filterData, let data = filterData.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any],
          let hashtags = dict["hashtags"] as? [String: Any],
          let names = hashtags["hashtags"] as? [String], !names.isEmpty else {
        return nil
    }
    return names.joined(separator: ",")
}

private func line(for e: CalendarEntry, suffix: String = "", note: String? = nil, showSectionNames: Bool = false) -> String {
    let icon = e.icon ?? "📋"
    let sectionsText: String
    if showSectionNames, let s = e.sections, !s.isEmpty {
        sectionsText = " 分区: \(s.joined(separator: "/"))"
    } else {
        sectionsText = (e.sections?.count ?? 0) > 0 ? " [\(e.sections!.count) sections]" : ""
    }
    let noteText = note.map { "  (\($0))" } ?? ""
    return "\(icon) \(e.title)\(suffix)\(sectionsText)\(noteText)"
}

/// JSON 输出模型：CalendarEntry + 分组名 + 备注（顶层列表 parentTitle 为 null）
private struct ListEntryOutput: Codable {
    let id: String
    let title: String
    let isGroup: Bool
    let icon: String?
    let color: String?
    let sections: [String]?
    let parentUUID: String?
    let parentTitle: String?
    let note: String?
    let order: Int

    init(_ e: CalendarEntry, parentTitle: String?, note: String?) {
        id = e.id
        title = e.title
        isGroup = e.isGroup
        icon = e.icon
        color = e.color
        sections = e.sections
        parentUUID = e.parentUUID
        self.parentTitle = parentTitle
        self.note = note
        order = e.order
    }
}

struct ListCountResult: Codable {
    let total: Int
    let lists: Int
    let groups: Int
    let sections: Int
    let smartLists: Int
}

/// JSON 容器（--smart-lists 时输出）：普通列表 + 自定义智能列表
private struct ListWithSmartListsOutput: Codable {
    let lists: [ListEntryOutput]
    let smartLists: [SmartListEntry]
}
