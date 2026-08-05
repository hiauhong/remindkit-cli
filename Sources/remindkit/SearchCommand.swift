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
            let q = query.lowercased()
            let titleMatch = r.title.lowercased().contains(q)
            let notesMatch = r.notes?.lowercased().contains(q) ?? false
            let tagsMatch = (r.tags ?? []).contains { $0.lowercased().contains(q) }
            return titleMatch || notesMatch || tagsMatch
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
