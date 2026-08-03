import ArgumentParser
import EventKitCore
import Foundation

struct Query: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Filter reminders by structured conditions (list/tag/date/flag/urgency)"
    )

    @Option(name: .long, help: "Filter by list name or ID")
    var list: String?

    @Option(name: .long, help: "Filter by tag name")
    var tag: String?

    @Flag(name: .long, help: "Show only completed reminders (default: incomplete)")
    var completed: Bool = false

    @Flag(name: .long, help: "Show all reminders regardless of completion")
    var all: Bool = false

    @Flag(name: .long, help: "Show only flagged reminders")
    var flagged: Bool = false

    @Flag(name: .long, help: "Show only urgent reminders")
    var urgent: Bool = false

    @Option(name: .long, help: "Only reminders due on or after this date (YYYY-MM-DD [HH:MM])")
    var dueAfter: String?

    @Option(name: .long, help: "Only reminders due before this date (YYYY-MM-DD [HH:MM])")
    var dueBefore: String?

    @Option(name: .long, help: "Output format: json, plain")
    var format: QueryFormat = .auto()

    @Option(name: .long, help: "Only output these fields (comma-separated): id,title,dueDate,completed,…")
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

        var filtered = data.reminders

        if let listFilter = list {
            let calIds = Set(resolveListsOrFail(data.calendars, listFilter).map(\.id))
            filtered = filtered.filter { calIds.contains($0.calendarId) }
        }

        if let tagFilter = tag {
            let t = tagFilter.lowercased()
            filtered = filtered.filter { ($0.tags ?? []).contains { $0.lowercased() == t } }
        }

        filtered = try applyCompletionScope(filtered, completed: completed, all: all)
        if flagged {
            filtered = filtered.filter { $0.flagged }
        }
        if urgent {
            filtered = filtered.filter { $0.urgent }
        }

        if let after = try parseDueDateOption(dueAfter) {
            filtered = filtered.filter { $0.dueDate != nil && $0.dueDate! >= after.timeIntervalSince1970 }
        }
        if let before = try parseDueDateOption(dueBefore) {
            filtered = filtered.filter { $0.dueDate != nil && $0.dueDate! < before.timeIntervalSince1970 }
        }

        try printReminderEntries(filtered, format: format, listNameById: calendarTitles(from: data.calendars),
                                 fields: parseFieldsOption(fields))
    }

    private func parseDueDateOption(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        guard let parsed = parseDueDate(value) else {
            throw ValidationError("Invalid date: \(value). Use YYYY-MM-DD or YYYY-MM-DD HH:MM")
        }
        return parsed
    }
}
