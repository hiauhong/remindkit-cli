import ArgumentParser
import EventKitCore
import Foundation

struct Count: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "count",
        abstract: "Count reminders (optionally scoped to a list) and print a breakdown"
    )

    @Option(name: .long, help: "Scope to a list name or ID")
    var list: String?

    @Flag(name: .long, help: "Print a per-list breakdown for every list")
    var byList: Bool = false

    @Option(name: .long, help: "Filter by tag name")
    var tag: String?

    @Flag(name: .long, help: "Count only flagged reminders")
    var flagged: Bool = false

    @Flag(name: .long, help: "Count only urgent reminders")
    var urgent: Bool = false

    @Option(name: .long, help: "Output format: json (default) or plain")
    var format: CountFormat = .json

    func run() throws {
        let data = fetchEnrichedData(includeSections: false)

        // --by-list: one call instead of looping `count --list` per list.
        if byList {
            try printByList(data, format: format)
            return
        }

        var filtered = data.reminders

        var matchedLists: [ListRef]?
        if let listFilter = list {
            let matches = resolveListsOrFail(data.calendars, listFilter)
            let titlesById = Dictionary(uniqueKeysWithValues: data.calendars.map { ($0.id, $0.title) })
            matchedLists = matches.map {
                ListRef(id: $0.id, title: $0.title, icon: $0.icon,
                        parentTitle: $0.parentUUID.flatMap { titlesById[$0] })
            }
            let calIds = Set(matches.map(\.id))
            filtered = filtered.filter { calIds.contains($0.calendarId) }
        }
        if let tagFilter = tag {
            let t = tagFilter.lowercased()
            filtered = filtered.filter { ($0.tags ?? []).contains { $0.lowercased() == t } }
        }
        if flagged {
            filtered = filtered.filter { $0.flagged }
        }
        if urgent {
            filtered = filtered.filter { $0.urgent }
        }

        var result = countBreakdown(filtered)
        // Ambiguity hint: duplicate titles (e.g. two "数码" lists) were all
        // merged — tell the caller which ones, instead of a silent combined
        // number.
        if let matchedLists, matchedLists.count > 1 {
            let names = matchedLists.map { ref in
                ref.parentTitle.map { "\(ref.title) (\($0))" } ?? ref.title
            }.joined(separator: ", ")
            fputs("remindkit: note: '\(list!)' matched \(matchedLists.count) lists: \(names)\n", stderr)
        }
        result.matchedLists = matchedLists

        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let jsonData = try encoder.encode(result)
            print(String(data: jsonData, encoding: .utf8)!)
        case .plain:
            print("total: \(result.total)  incomplete: \(result.incomplete)  completed: \(result.completed)")
            print("flagged: \(result.flagged)  urgent: \(result.urgent)  dueToday: \(result.dueToday)  overdue: \(result.overdue)")
            if let matched = result.matchedLists {
                print("matchedLists: \(matched.map { $0.title }.joined(separator: ", "))")
            }
        }
    }

    private func printByList(_ data: EnrichedData, format: CountFormat) throws {
        let titlesById = Dictionary(uniqueKeysWithValues: data.calendars.map { ($0.id, $0.title) })
        let notes = NotesStore(fileURL: NotesStore.defaultURL()).load()
        var rows: [PerListCount] = []
        for cal in data.calendars {
            let entries = data.reminders.filter { $0.calendarId == cal.id }
            let c = countBreakdown(entries)
            rows.append(PerListCount(
                id: cal.id,
                title: cal.title,
                icon: cal.icon,
                isGroup: cal.isGroup,
                parentTitle: cal.parentUUID.flatMap { titlesById[$0] },
                note: notes[cal.id],
                total: c.total, incomplete: c.incomplete, completed: c.completed,
                flagged: c.flagged, urgent: c.urgent, dueToday: c.dueToday, overdue: c.overdue
            ))
        }
        switch format {
        case .json:
            let result = ByListResult(
                total: data.reminders.count,
                incomplete: data.reminders.filter { !$0.completed }.count,
                lists: rows
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let jsonData = try encoder.encode(result)
            print(String(data: jsonData, encoding: .utf8)!)
        case .plain:
            print("total: \(data.reminders.count)  incomplete: \(data.reminders.filter { !$0.completed }.count)")
            for row in rows {
                let indent = row.isGroup ? "" : (row.parentTitle != nil ? "  " : "")
                let group = row.isGroup ? " 📁" : ""
                print("\(indent)\(row.icon ?? "")\(row.title)\(group): \(row.total) (\(row.incomplete) 未完成)")
            }
        }
    }
}

/// Reference to a matched list, surfaced when `--list` resolves to one or
/// more calendars.
struct ListRef: Codable {
    let id: String
    let title: String
    let icon: String?
    let parentTitle: String?
}

enum CountFormat: String, ExpressibleByArgument, Codable {
    case json
    case plain
}

struct PerListCount: Codable {
    let id: String
    let title: String
    let icon: String?
    let isGroup: Bool
    let parentTitle: String?
    let note: String?
    let total: Int
    let incomplete: Int
    let completed: Int
    let flagged: Int
    let urgent: Int
    let dueToday: Int
    let overdue: Int
}

struct ByListResult: Codable {
    let total: Int
    let incomplete: Int
    let lists: [PerListCount]
}
