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

    @Option(name: .long, help: "Only reminders completed on or after this date (YYYY-MM-DD [HH:MM]) — for done/retro reviews")
    var completedAfter: String?

    @Option(name: .long, help: "Only reminders completed before this date (YYYY-MM-DD [HH:MM])")
    var completedBefore: String?

    @Option(name: .long, help: "Output format: json, plain")
    var format: QueryFormat = .auto()

    @Option(name: .long, help: "Only output these fields (comma-separated): id,title,dueDate,completed,…")
    var fields: String?

    @Flag(name: .long, help: "Include section field (default: auto — on when --list is given)")
    var sections: Bool = false

    @Flag(name: .long, help: "Skip section lookup (faster; default: auto)")
    var noSections: Bool = false

    @Flag(name: .long, help: "Print as a hierarchy tree: section → task → subtasks (requires --list)")
    var tree: Bool = false

    func validate() throws {
        if completed && all {
            throw ValidationError("--completed and --all are mutually exclusive")
        }
    }

    func run() throws {
        let data = fetchEnrichedData(includeSections: sectionsEnabled(force: sections || tree, disable: noSections, hasList: list != nil))

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

        if let after = try parseDueDateOption(completedAfter) {
            filtered = filtered.filter { $0.completionDate != nil && $0.completionDate! >= after.timeIntervalSince1970 }
        }
        if let before = try parseDueDateOption(completedBefore) {
            filtered = filtered.filter { $0.completionDate != nil && $0.completionDate! < before.timeIntervalSince1970 }
        }

        if tree {
            guard list != nil else {
                throw ValidationError("--tree requires --list (needs a list's section structure)")
            }
            let listSections = data.calendars.first { $0.id == filtered.first?.calendarId }?.sections ?? []
            try printTree(filtered, listSections: listSections)
            return
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

    /// 结构视图：分区 → 任务 → 子任务。分区按列表定义的顺序，未分区归末尾。
    private func printTree(_ reminders: [ReminderEntry], listSections: [String]) throws {
        let bySection = Dictionary(grouping: reminders) { $0.section }
        var printed = false

        let order = listSections + (bySection.keys.compactMap { $0 }.filter { !listSections.contains($0) })
        for sec in order {
            guard let items = bySection[sec], !items.isEmpty else { continue }
            printed = true
            print(sec)
            printSectionTree(items)
        }
        if let un = bySection[nil], !un.isEmpty {
            printed = true
            print("（未分区）")
            printSectionTree(un)
        }
        if !printed {
            print("（空）")
        }
    }

    /// 分区内：父任务在前，子任务缩进；孤儿子任务（父不在结果集）兜底补打。
    private func printSectionTree(_ items: [ReminderEntry]) {
        let childrenByParent = Dictionary(grouping: items.filter { $0.parentId != nil }) { $0.parentId! }
        let ids = Set(items.map(\.id))

        for r in items where r.parentId == nil {
            let kids = childrenByParent[r.id] ?? []
            print("  \(r.title)")
            for k in kids.sorted(by: { $0.title < $1.title }) {
                print("    \(k.title)")
            }
        }
        // 孤儿子任务：父任务不在本次结果集（如跨列表）时仍展示。
        for r in items where r.parentId != nil && !ids.contains(r.parentId!) {
            print("  \(r.title)")
        }
    }
}
