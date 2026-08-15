import EventKitCore
import Foundation

// MARK: - Fetch: ReminderKit primary, EventKit fallback

/// Fetch all data in one shot. ReminderKit (private framework subprocess) is
/// the primary source — it now carries every field, including subtasks.
/// EventKit is the fallback when the subprocess is missing or produces
/// nothing: you still get the full basic dataset, just without the rich
/// ReminderKit-only fields (tags, icons, sections, flags, tree, …).
func fetchEnrichedData(includeSections: Bool = true) -> EnrichedData {
    // ReminderKit is primary. We trust a subprocess that produced a `reminders`
    // key even when the array is empty (a genuinely empty database must not be
    // misreported as an EventKit fallback, nor force a second fetch).
    if let rk = runReminderKitSubprocess(includeSections: includeSections),
       let rawReminders = rk.reminders {
        return EnrichedData(
            reminders: mergedReminders(from: rawReminders),
            calendars: mergedCalendars(from: rk.lists ?? []),
            smartLists: mergedSmartLists(rk),
            listIDsOrdering: rk.listIDsOrdering ?? [],
            source: .reminderKit
        )
    }

    // Fallback: EventKit public API (core fields only).
    let ek = fetchEventKitData()
    return EnrichedData(
        reminders: ek.reminders.map { $0.toReminderEntry() },
        calendars: ek.calendars.map { $0.toCalendarEntry() },
        smartLists: [],
        listIDsOrdering: [],
        source: .eventKit
    )
}

struct EnrichedData {
    let reminders: [ReminderEntry]
    let calendars: [CalendarEntry]
    let smartLists: [SmartListEntry]
    let listIDsOrdering: [String]
    let source: DataSource
}

/// Fetch list structure only (groups/lists/sections/order) without
/// enumerating reminders. `setup`'s default mode evaluates each list from
/// its structure alone; `setup --deep` uses the full `fetchEnrichedData`
/// (structure + contents).
func fetchListStructure() -> EnrichedData {
    if let rk = runReminderKitSubprocess(includeSections: true, listsOnly: true),
       let rawLists = rk.lists {
        return EnrichedData(
            reminders: [],
            calendars: mergedCalendars(from: rawLists),
            smartLists: mergedSmartLists(rk),
            listIDsOrdering: rk.listIDsOrdering ?? [],
            source: .reminderKit
        )
    }
    let ek = fetchEventKitData()
    return EnrichedData(
        reminders: [],
        calendars: ek.calendars.map { $0.toCalendarEntry() },
        smartLists: [],
        listIDsOrdering: [],
        source: .eventKit
    )
}

// MARK: - ReminderKit → unified schema

func mergedReminders(from raw: [ReminderRaw]) -> [ReminderEntry] {
    // subtaskIds: parentId is per-child; build the children index once.
    var children: [String: [String]] = [:]
    for r in raw {
        if let parent = r.parentId, let id = r.externalIdentifier {
            children[parent, default: []].append(id)
        }
    }

    return raw.map { r in
        ReminderEntry(
            id: r.externalIdentifier ?? "",
            calendarId: r.listID ?? "",
            title: r.title ?? "",
            notes: r.notes,
            completed: r.completed ?? false,
            priority: r.priority ?? 0,
            creationDate: r.creationDate,
            completionDate: r.completionDate,
            dueDate: r.dueDate,
            dueDateText: reminderDateText(r.dueDate, timeZone: r.timeZone),
            startDate: r.startDate,
            allDay: r.allDay ?? false,
            timeZone: r.timeZone,
            recurrenceRules: r.recurrenceRules,
            tags: r.tags,
            flagged: r.flagged ?? false,
            urgent: r.urgent ?? false,
            url: r.url,
            alarms: r.alarms,
            order: r.order ?? 0,
            section: r.section,
            parentId: r.parentId,
            subtaskIds: r.externalIdentifier.map { children[$0] ?? [] } ?? []
        )
    }
}

func mergedCalendars(from lists: [ListRaw]) -> [CalendarEntry] {
    lists.enumerated().map { (idx, l) in
        let parentUUID = l.parentUUID
        return CalendarEntry(
            id: l.uuid ?? "",
            title: l.name ?? "",
            isGroup: l.isGroup ?? false,
            icon: l.icon,
            color: l.color,
            sections: l.sections,
            parentUUID: (parentUUID != nil && parentUUID != "null") ? parentUUID : nil,
            order: idx
        )
    }
}

func mergedSmartLists(_ remindKit: ReminderKitRaw?) -> [SmartListEntry] {
    (remindKit?.smartLists ?? []).compactMap {
        guard let uuid = $0.uuid else { return nil }
        return SmartListEntry(
            uuid: uuid,
            name: $0.name,
            type: $0.type,
            filterData: $0.filterData,
            icon: $0.icon,
            color: $0.color,
            sortingStyle: $0.sortingStyle
        )
    }
}

// MARK: - EventKit fallback → unified schema

/// 提醒日期 epoch → 可读文本（yyyy-MM-dd HH:mm）。
/// 默认用本地时区；提醒自带非本地时区（`timeZone`）时优先用它，避免
/// dueDateText / today / overdue 展示偏差。
func reminderDateText(_ epoch: Double?, timeZone: String? = nil) -> String? {
    guard let epoch else { return nil }
    let date = Date(timeIntervalSince1970: epoch)
    if let tzName = timeZone, let tz = TimeZone(identifier: tzName) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")   // 强制 24 小时制
        return f.string(from: date)
    }
    return reminderDateFormatter.string(from: date)
}

/// 查询命令的 section 策略（分区字段查询较慢，逐条过 remindd）：
///   --no-sections → 强制不带（性能）
///   --sections    → 强制带
///   默认           → 显式指定了 --list 时带（列表结构查询的核心诉求），否则不带
func sectionsEnabled(force: Bool, disable: Bool, hasList: Bool) -> Bool {
    if disable { return false }
    if force { return true }
    return hasList
}

private let reminderDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = .current
    f.locale = Locale(identifier: "en_US_POSIX")   // 强制 24 小时制，避免「上午12:00」
    return f
}()


extension EventKitReminder {
    func toReminderEntry() -> ReminderEntry {
        ReminderEntry(
            id: id,
            calendarId: calendarId,
            title: title,
            notes: notes,
            completed: completed,
            priority: priority,
            creationDate: creationDate,
            completionDate: completionDate,
            dueDate: dueDate,
            dueDateText: reminderDateText(dueDate),
            startDate: startDate,
            allDay: false,
            timeZone: nil,
            recurrenceRules: recurrenceRules,
            tags: nil,
            flagged: false,
            urgent: false,
            url: nil,
            alarms: nil,
            order: 0,
            section: nil,
            parentId: nil,
            subtaskIds: []
        )
    }
}

extension EventKitCalendar {
    func toCalendarEntry() -> CalendarEntry {
        CalendarEntry(
            id: id,
            title: title,
            isGroup: false,
            icon: nil,
            color: nil,
            sections: nil,
            parentUUID: nil,
            order: 0
        )
    }
}

// MARK: - Helpers

/// Map calendar ID → title for display purposes.
func calendarTitles(from calendars: [CalendarEntry]) -> [String: String] {
    var map: [String: String] = [:]
    for cal in calendars {
        map[cal.id] = cal.title
    }
    return map
}

/// Resolve calendar IDs for a `--list` query filter: exact ID or
/// case-insensitive exact title match first (so `财务` matches only the
/// `财务` lists, never `财务选题`); fall back to a substring match only when
/// no exact match exists.
func resolveCalendarIDs(_ calendars: [CalendarEntry], _ filter: String) -> [String] {
    let exact = calendars.filter { $0.id == filter || $0.title.caseInsensitiveCompare(filter) == .orderedSame }
    if !exact.isEmpty { return exact.map { $0.id } }
    return calendars.filter { $0.title.localizedCaseInsensitiveContains(filter) }.map { $0.id }
}

// MARK: - List filter resolution (strict)

/// Error thrown when a `--list` filter matches no calendar/list. A stale ID
/// or a typo must not silently produce an empty result set — the caller
/// should surface this instead.
struct ListFilterError: LocalizedError, ErrorCoded {
    let filter: String
    let candidates: [CalendarEntry]

    var code: String { "noSuchList" }
    var exitCode: Int32 { 1 }

    var errorDescription: String? {
        guard !candidates.isEmpty else {
            return "No list matches '\(filter)'"
        }
        let names = candidates.map { "\($0.title) (\($0.id.prefix(8))…)" }.joined(separator: ", ")
        return "No list matches '\(filter)'. Did you mean: \(names)?"
    }
}

/// Resolve a `--list` filter to concrete calendars, strict:
///   1. exact UUID
///   2. UUID prefix (≥ 8 chars — copy-paste of the short form works)
///   3. case-insensitive exact title (duplicate titles are all returned)
///   4. substring title, last resort
/// Throws `ListFilterError` when nothing matches. Prefer this over the
/// lenient `resolveCalendarIDs` when the user explicitly scoped a query.
func resolveListFilter(_ calendars: [CalendarEntry], _ filter: String) throws -> [CalendarEntry] {
    let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ListFilterError(filter: trimmed, candidates: [])
    }
    let lower = trimmed.lowercased()

    // 1. Exact UUID.
    let exactID = calendars.filter { $0.id == trimmed }
    if !exactID.isEmpty { return exactID }

    // 2. UUID prefix — the common short form when copy-pasting.
    if lower.count >= 8 {
        let prefix = calendars.filter { $0.id.lowercased().hasPrefix(lower) }
        if !prefix.isEmpty { return prefix }
    }

    // 3. Exact title, case-insensitive.
    let exactTitle = calendars.filter { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
    if !exactTitle.isEmpty { return exactTitle }

    // 4. Substring title, last resort.
    let substring = calendars.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    if !substring.isEmpty { return substring }

    // Nothing matched — offer near-miss candidates (either direction contains).
    let candidates = calendars.filter {
        !$0.isGroup && ($0.title.localizedCaseInsensitiveContains(trimmed)
            || trimmed.localizedCaseInsensitiveContains($0.title))
    }
    throw ListFilterError(filter: trimmed, candidates: candidates)
}

/// Resolve a `--list` filter or exit with the machine-readable error contract
/// (stderr JSON, exit 1) when nothing matches. Keeps call sites free of
/// do/catch boilerplate while preserving the `noSuchList` error code.
func resolveListsOrFail(_ calendars: [CalendarEntry], _ filter: String) -> [CalendarEntry] {
    do {
        let resolved = try resolveListFilter(calendars, filter)
        // 重名/前缀命中多个：明确警告，避免 agent 把合并输出误当单列表
        if resolved.count > 1 {
            let titles = resolved.map(\.title).joined(separator: ", ")
            fputs("warning: --list \"\(filter)\" 匹配到 \(resolved.count) 个列表（\(titles)），输出为合并结果；如需精确定位用 --list <完整UUID> 或 --list-id\n", stderr)
        }
        return resolved
    } catch {
        fail(error)
    }
}

/// Resolve a `--list` filter against smart lists (system + custom), same
/// precedence as `resolveListFilter`: exact UUID → UUID prefix → exact title
/// (case-insensitive) → substring. Returns empty when nothing matches so the
/// caller can fall back / report `noSuchList` itself.
func resolveSmartListFilter(_ smartLists: [SmartListEntry], _ filter: String) -> [SmartListEntry] {
    let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let lower = trimmed.lowercased()

    let exactID = smartLists.filter { $0.uuid == trimmed }
    if !exactID.isEmpty { return exactID }

    if lower.count >= 8 {
        let prefix = smartLists.filter { $0.uuid.lowercased().hasPrefix(lower) }
        if !prefix.isEmpty { return prefix }
    }

    let exactTitle = smartLists.filter { ($0.name ?? "").caseInsensitiveCompare(trimmed) == .orderedSame }
    if !exactTitle.isEmpty { return exactTitle }

    return smartLists.filter { ($0.name ?? "").localizedCaseInsensitiveContains(trimmed) }
}
