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

    @Option(name: .long, help: "Output format: json, plain, count")
    var format: QueryFormat = .auto()

    func run() throws {
        let data = fetchEnrichedData(includeSections: false)
        let entries = data.calendars

        let filtered = groups ? entries.filter(\.isGroup) : entries

        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(filtered)
            print(String(data: data, encoding: .utf8)!)
        case .count:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ListCountResult(
                total: entries.count,
                lists: entries.filter { !$0.isGroup }.count,
                groups: entries.filter(\.isGroup).count,
                sections: entries.reduce(0) { $0 + ($1.sections?.count ?? 0) }
            ))
            print(String(data: data, encoding: .utf8)!)
        case .plain:
            let notes = NotesStore(fileURL: NotesStore.defaultURL()).load()
            for line in treeLines(entries, groupsOnly: groups, notes: notes) {
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
private func treeLines(_ calendars: [CalendarEntry], groupsOnly: Bool, notes: [String: String]) -> [String] {
    let groups = calendars.filter(\.isGroup)
    var lines: [String] = []

    if groupsOnly {
        for g in groups {
            lines.append("\(g.icon ?? "📋") \(g.title) 📁")
        }
        return lines
    }

    // Top-level lists (no parent group), in natural order.
    for e in calendars where !e.isGroup && e.parentUUID == nil {
        lines.append(line(for: e, note: notes[e.id]))
    }
    // Groups, each followed by its children (indented).
    for g in groups {
        lines.append(line(for: g, suffix: " 📁"))
        for child in calendars where child.parentUUID == g.id {
            lines.append("  \(line(for: child, note: notes[child.id]))")
        }
    }
    return lines
}

private func line(for e: CalendarEntry, suffix: String = "", note: String? = nil) -> String {
    let icon = e.icon ?? "📋"
    let sections = (e.sections?.count ?? 0) > 0 ? " [\(e.sections!.count) sections]" : ""
    let noteText = note.map { "  (\($0))" } ?? ""
    return "\(icon) \(e.title)\(suffix)\(sections)\(noteText)"
}

struct ListCountResult: Codable {
    let total: Int
    let lists: Int
    let groups: Int
    let sections: Int
}
