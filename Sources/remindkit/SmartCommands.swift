import ArgumentParser
import EventKitCore
import Foundation

// MARK: - Apple's first-class smart-list entries, as first-class commands.
// Reminders.app sidebar: 今日 / 计划 / 全部 / 已标记 / 紧急.
// today / scheduled already exist; flagged / urgent live here.

struct Flagged: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flagged",
        abstract: "Incomplete reminders with a flag (Apple's 已标记 view — your current focus)"
    )

    @Option(name: .long, help: "Filter by list name or ID")
    var list: String?

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
        var q = Query()
        q.flagged = true
        q.urgent = false
        q.list = list
        q.tag = nil
        q.completed = completed
        q.all = all
        q.dueAfter = nil
        q.dueBefore = nil
        q.format = format
        q.fields = fields
        q.sections = sections
        q.noSections = noSections
        try q.run()
    }
}

struct Urgent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "urgent",
        abstract: "Incomplete reminders marked urgent (Apple's 紧急 view)"
    )

    @Option(name: .long, help: "Filter by list name or ID")
    var list: String?

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
        var q = Query()
        q.urgent = true
        q.flagged = false
        q.list = list
        q.tag = nil
        q.completed = completed
        q.all = all
        q.dueAfter = nil
        q.dueBefore = nil
        q.format = format
        q.fields = fields
        q.sections = sections
        q.noSections = noSections
        try q.run()
    }
}
