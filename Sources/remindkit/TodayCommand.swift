import ArgumentParser
import EventKitCore
import Foundation

struct Today: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "today",
        abstract: "List incomplete reminders due today"
    )

    @Flag(name: .long, help: "Include overdue reminders as well")
    var includeOverdue: Bool = false

    @Flag(name: .long, help: "Show only completed reminders (default: incomplete)")
    var completed: Bool = false

    @Flag(name: .long, help: "Show all reminders regardless of completion")
    var all: Bool = false

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
        let data = fetchEnrichedData(includeSections: sectionsEnabled(force: sections, disable: noSections, hasList: false))
        let startOfToday = startOfToday()
        let startOfTomorrow = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday)!

        var filtered = data.reminders.filter { r in
            guard let due = r.dueDate else { return false }
            let dueDate = Date(timeIntervalSince1970: due)
            if includeOverdue {
                return dueDate < startOfTomorrow
            }
            return dueDate >= startOfToday && dueDate < startOfTomorrow
        }
        filtered = try applyCompletionScope(filtered, completed: completed, all: all)
        filtered.sort { ($0.dueDate ?? .greatestFiniteMagnitude) < ($1.dueDate ?? .greatestFiniteMagnitude) }

        try printReminderEntries(filtered, format: format, listNameById: calendarTitles(from: data.calendars),
                                 fields: parseFieldsOption(fields))
    }
}
