import ArgumentParser
import EventKitCore
import Foundation

func validateQuerySectionOptions(section: String?, noSections: Bool,
                                 tree: Bool, smartList: String?) throws {
    if noSections && section != nil {
        throw ValidationError("--section and --no-sections are mutually exclusive")
    }
    if noSections && tree {
        throw ValidationError("--tree and --no-sections are mutually exclusive")
    }
    if tree && smartList != nil {
        throw ValidationError("--tree does not support --smart-list: smart-list section membership is not available in the read schema")
    }
}

struct Query: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Filter reminders by structured conditions (list/tag/date/flag/urgency)"
    )

    @Option(name: .long, help: "Filter by list name or ID")
    var list: String?

    @Option(name: .long, help: "Filter by list ID (preferred; disambiguates same-named lists)")
    var listId: String?

    @Option(name: .long, help: "Evaluate a smart list by name or UUID (returns reminders matching its supported filter)")
    var smartList: String?

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

    @Option(name: .long, help: "Only output these fields (comma-separated): id,title,dueDate,completed,notes,listTitle,…")
    var fields: String?

    @Flag(name: .long, help: "Include section field (default: auto — on when --list is given)")
    var sections: Bool = false

    @Flag(name: .long, help: "Skip section lookup (faster; default: auto)")
    var noSections: Bool = false

    @Option(name: .long, help: "Filter by section name (requires --list / --list-id / --smart-list)")
    var section: String?

    @Flag(name: .long, help: "Print as a hierarchy tree: section → task → subtasks (requires --list)")
    var tree: Bool = false

    func validate() throws {
        if completed && all {
            throw ValidationError("--completed and --all are mutually exclusive")
        }
        if section != nil && list == nil && listId == nil && smartList == nil {
            throw ValidationError("--section requires --list, --list-id, or --smart-list (sections are list-scoped)")
        }
        try validateQuerySectionOptions(section: section, noSections: noSections,
                                        tree: tree, smartList: smartList)
    }

    func run() throws {
        let data = fetchEnrichedData(includeSections: sectionsEnabled(force: sections || tree || section != nil, disable: noSections, hasList: list != nil || listId != nil || smartList != nil))

        var filtered = data.reminders
        // Which calendars the --list/--list-id filter resolved to (used by
        // --tree, which needs a single unambiguous list for its section order).
        var resolvedLists: [CalendarEntry]? = nil

        // #17: smart-list evaluation — resolve the smart list, parse its
        // filterData (hashtags for now), and keep reminders matching the tag.
        // Takes precedence over --list/--list-id when given.
        if let smartListFilter = smartList {
            let matches = resolveSmartListFilter(data.smartLists, smartListFilter)
            if matches.isEmpty {
                fail("noSuchSmartList", "找不到智能列表：\(smartListFilter)")
            }
            if matches.count > 1 {
                let names = matches.compactMap(\.name).joined(separator: ", ")
                fail("ambiguousSmartList", "智能列表「\(smartListFilter)」匹配到 \(matches.count) 个（\(names)），请用完整 UUID")
            }
            let sl = matches[0]
            let tagNames = smartListFilterTags(sl.filterData)
            if tagNames.isEmpty {
                fail("unsupportedFilter", "智能列表「\(sl.name ?? "")」的过滤条件暂不支持求值（当前仅支持 hashtags）；filterData: \(sl.filterData ?? "nil")")
            }
            filtered = filtered.filter { rem in
                let remTags = (rem.tags ?? []).map { $0.lowercased() }
                return tagNames.contains { t in remTags.contains(t.lowercased()) }
            }
        } else if let listId {
            let matches = data.calendars.filter { $0.id == listId || $0.id.lowercased().hasPrefix(listId.lowercased()) }
            if matches.isEmpty {
                fail("noSuchList", "找不到列表：\(listId)")
            }
            if matches.count > 1 {
                let titles = matches.map(\.title).joined(separator: ", ")
                fail("ambiguousList", "ID「\(listId)」匹配到 \(matches.count) 个列表（\(titles)），请用完整 UUID")
            }
            resolvedLists = matches
            let calIds = Set(matches.map(\.id))
            filtered = filtered.filter { calIds.contains($0.calendarId) }
        } else if let listFilter = list {
            let matches = resolveListsOrFail(data.calendars, listFilter)
            resolvedLists = matches
            let calIds = Set(matches.map(\.id))
            filtered = filtered.filter { calIds.contains($0.calendarId) }
        }

        if let tagFilter = tag {
            let t = tagFilter.lowercased()
            filtered = filtered.filter { ($0.tags ?? []).contains { $0.lowercased() == t } }
        }

        if let sectionFilter = section {
            // 分区过滤：精确匹配 reminder.section（sections 已在上面强制加载）。
            filtered = filtered.filter { $0.section == sectionFilter }
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
            // 树形视图依赖「唯一列表」的分区顺序：--list/--list-id 必须
            // 解析到恰好一个列表，重名时明确报错而不是取第一个。
            guard let resolved = resolvedLists else {
                throw ValidationError("--tree requires --list or --list-id (needs a single list's section structure)")
            }
            guard resolved.count == 1 else {
                let titles = resolved.map(\.title).joined(separator: ", ")
                fail("ambiguousList", "--tree 需要唯一列表，但「\(list ?? listId ?? "")」匹配到 \(resolved.count) 个（\(titles)），请用 --list-id <完整UUID> 精确定位")
            }
            try printTree(filtered, listSections: resolved[0].sections ?? [])
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

    /// Parse hashtag names out of a smart list's filterData JSON string.
    /// Supports the shape Reminders.app writes for a tag filter:
    /// {"hashtags":{"hashtags":["标签"]}}. Returns [] for other filter kinds
    /// (dates/priority/etc. — not yet evaluable, caller reports the gap).
    private func smartListFilterTags(_ filterData: String?) -> [String] {
        guard let filterData, let data = filterData.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let hashtags = dict["hashtags"] as? [String: Any],
              let names = hashtags["hashtags"] as? [String] else {
            return []
        }
        return names
    }
}
