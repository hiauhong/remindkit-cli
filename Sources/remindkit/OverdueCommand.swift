import ArgumentParser
import EventKitCore
import Foundation

struct Overdue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overdue",
        abstract: "List incomplete reminders past due"
    )

    @Flag(name: .long, help: "Show only completed reminders (default: incomplete)")
    var completed: Bool = false

    @Flag(name: .long, help: "Show all reminders regardless of completion")
    var all: Bool = false

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
        let startOfToday = startOfToday()

        var filtered = data.reminders.filter { r in
            guard let due = r.dueDate else { return false }
            return Date(timeIntervalSince1970: due) < startOfToday
        }
        filtered = try applyCompletionScope(filtered, completed: completed, all: all)
        filtered.sort { ($0.dueDate ?? .greatestFiniteMagnitude) < ($1.dueDate ?? .greatestFiniteMagnitude) }

        try printReminderEntries(filtered, format: format, listNameById: calendarTitles(from: data.calendars),
                                 fields: parseFieldsOption(fields))
    }
}
