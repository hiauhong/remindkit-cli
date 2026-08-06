import ArgumentParser
import EventKitCore
import Foundation

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search reminders by title, notes, or tags"
    )

    @Argument(help: "Search query")
    var query: String

    @Flag(name: .long, help: "Show only completed reminders (default: incomplete)")
    var completed: Bool = false

    @Flag(name: .long, help: "Show all reminders regardless of completion")
    var all: Bool = false

    @Flag(name: .long, help: "Require every search term to match (default: any term)")
    var matchAll: Bool = false

    @Option(name: .long, help: "Filter by list name or ID")
    var list: String?

    @Option(name: .long, help: "Output format: json, plain")
    var format: QueryFormat = .auto()

    @Option(name: .long, help: "Only output these fields (comma-separated): id,title,dueDate,completed,notes,listTitle,…")
    var fields: String?

    @Flag(name: .long, help: "Include section field (default: auto — on when --list is given)")
    var sections: Bool = false

    @Flag(name: .long, help: "Skip section lookup (faster; default: auto)")
    var noSections: Bool = false

    func validate() throws {
        if completed && all {
            throw ValidationError("--completed and --all are mutually exclusive")
        }
    }

    func run() throws {
        let data = fetchEnrichedData(includeSections: sectionsEnabled(force: sections, disable: noSections, hasList: list != nil))

        var filtered = data.reminders.filter { r in
            searchMatch(title: r.title, notes: r.notes, tags: r.tags,
                        terms: searchTerms(from: query), matchAll: matchAll)
        }
        filtered = try applyCompletionScope(filtered, completed: completed, all: all)
        if let listFilter = list {
            let calIds = Set(resolveListsOrFail(data.calendars, listFilter).map(\.id))
            filtered = filtered.filter { calIds.contains($0.calendarId) }
        }

        try printReminderEntries(filtered, format: format, listNameById: calendarTitles(from: data.calendars),
                                 fields: parseFieldsOption(fields))
    }
}

/// Split a search query into lowercased terms (whitespace-separated).
/// Multiple keywords are supported: `"牛奶 面包"` → `["牛奶", "面包"]`.
func searchTerms(from query: String) -> [String] {
    query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
}

/// Match a reminder's title/notes/tags against search terms.
/// - `matchAll = false`: any term hit (OR, default)
/// - `matchAll = true`: every term must hit (AND)
/// Empty terms match nothing (avoids a query of only spaces matching everything under AND).
func searchMatch(title: String, notes: String?, tags: [String]?, terms: [String], matchAll: Bool) -> Bool {
    guard !terms.isEmpty else { return false }
    let t = title.lowercased()
    let n = notes?.lowercased() ?? ""
    let ts = (tags ?? []).map { $0.lowercased() }
    func hit(_ term: String) -> Bool {
        t.contains(term) || n.contains(term) || ts.contains { $0.contains(term) }
    }
    return matchAll ? terms.allSatisfy(hit) : terms.contains(where: hit)
}
