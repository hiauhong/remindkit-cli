import ArgumentParser
import EventKitCore
import Foundation

struct Scheduled: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scheduled",
        abstract: "List reminders that have a due date (Apple's 计划 view): overdue + today + future, sorted by date"
    )

    @Option(name: .long, help: "Only reminders due on or after this date (YYYY-MM-DD [HH:MM])")
    var from: String?

    @Option(name: .long, help: "Only reminders due before this date (YYYY-MM-DD [HH:MM])")
    var to: String?

    @Option(name: .long, help: "Only reminders due within N days from today (0 = only today)")
    var within: Int?

    @Flag(name: .long, help: "Show only completed reminders (default: incomplete)")
    var completed: Bool = false

    @Flag(name: .long, help: "Show all reminders regardless of completion")
    var all: Bool = false

    @Flag(name: .long, help: "Show only flagged reminders")
    var flagged: Bool = false

    @Flag(name: .long, help: "Show only urgent reminders")
    var urgent: Bool = false

    @Option(name: .long, help: "Filter by list name or ID")
    var list: String?

    @Option(name: .long, help: "Filter by tag name")
    var tag: String?

    @Option(name: .long, help: "Output format: json, plain")
    var format: QueryFormat = .auto()

    @Option(name: .long, help: "Only output these fields (comma-separated): id,title,dueDate,completed,…")
    var fields: String?

    func validate() throws {
        if completed && all {
            throw ValidationError("--completed and --all are mutually exclusive")
        }
    }

    func run() throws {
        let data = fetchEnrichedData(includeSections: false)

        // Base scope: any reminder with a due date.
        var filtered = data.reminders.filter { $0.dueDate != nil }

        // Date window.
        let today = startOfToday()
        if let from = try parseDateOption(from, "from") {
            filtered = filtered.filter { $0.dueDate! >= from.timeIntervalSince1970 }
        }
        if let to = try parseDateOption(to, "to") {
            filtered = filtered.filter { $0.dueDate! < to.timeIntervalSince1970 }
        }
        if let within {
            let end = Calendar.current.date(byAdding: .day, value: within + 1, to: today)!
            filtered = filtered.filter { $0.dueDate! < end.timeIntervalSince1970 }
        }

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

        // Sort by due date, oldest first (overdue first, then today, then future).
        filtered.sort { ($0.dueDate ?? .greatestFiniteMagnitude) < ($1.dueDate ?? .greatestFiniteMagnitude) }

        try printReminderEntries(filtered, format: format, listNameById: calendarTitles(from: data.calendars),
                                 fields: parseFieldsOption(fields))
    }

    private func parseDateOption(_ value: String?, _ name: String) throws -> Date? {
        guard let value else { return nil }
        guard let parsed = parseDueDate(value) else {
            throw ValidationError("Invalid \(name) date: \(value). Use YYYY-MM-DD or YYYY-MM-DD HH:MM")
        }
        return parsed
    }
}
