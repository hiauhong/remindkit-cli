import ArgumentParser
import EventKit
import EventKitCore
import Foundation

// MARK: - Shared write plumbing

/// Map a ReminderKit subprocess error message to the read-side business code
/// where the same condition exists, so agents can handle "list not found"
/// uniformly across read and write commands.
func reminderKitErrorCode(for message: String) -> String {
    if message.hasPrefix("找不到列表") || message.hasPrefix("找不到目标列表") { return "noSuchList" }
    if message.hasPrefix("找不到提醒") { return "noSuchReminder" }
    if message.hasPrefix("找不到分组") { return "noSuchGroup" }
    if message.hasPrefix("找不到账户") { return "noSuchAccount" }
    if message.hasPrefix("找不到删除记录") { return "noSuchDeletedRecord" }
    if message.hasPrefix("列表中没有分区") { return "noSuchSection" }
    return "reminderKitError"
}

/// Emit the structured error contract (`{"error":{"code":…,"message":…}}` on
/// stderr, exit 1) for a failed ReminderKit subprocess write response.
func failReminderKitError(_ rk: [String: Any]) -> Never {
    let message = rk["error"] as? String ?? "ReminderKit write failed"
    fail(reminderKitErrorCode(for: message), message)
}

/// Try the ReminderKit subprocess first; fall back to EventKit ONLY when the
/// subprocess is *unavailable* (binary missing / failed to start). A business
/// error from the subprocess (ambiguous name, not found, write protection)
/// surfaces as the structured error contract — falling back would silently
/// operate on the wrong list or fail the same way. An unknown write outcome
/// (timeout / no output) NEVER falls back: the subprocess may have committed
/// the write, and retrying through EventKit could duplicate or double-apply it.
func writeWithReminderKit(_ request: [String: Any],
                          fallback: () throws -> [String: Any]) throws -> (source: String, result: [String: Any]) {
    switch runReminderKitWrite(request) {
    case .success(let rk):
        if let ok = rk["ok"] as? Bool, ok {
            return ("reminderKit", rk)
        }
        failReminderKitError(rk)
    case .unavailable:
        return ("eventKit", try fallback())
    case .unknownOutcome(let detail):
        fail("writeResultUnknown",
             "写操作结果未知：\(detail)。为避免重复写入，已中止而不走 EventKit 兜底；请用 query/dump 核对后再操作。")
    }
}

/// Resolve a list by exact name or ID (EventKit fallback side). Strict:
/// full ID → UUID prefix → case-insensitive exact title; multiple matches
/// (duplicate titles) fail with `ambiguousList` — never pick one arbitrarily.
func ekResolveList(_ nameOrID: String, writer: RemindersWriter) throws -> EKCalendar {
    let matches = writer.resolveCalendars(namedOrID: nameOrID)
    if matches.count > 1 {
        let titles = matches.map(\.title).joined(separator: ", ")
        fail("ambiguousList", "「\(nameOrID)」匹配到 \(matches.count) 个列表（\(titles)），请用完整列表 ID 精确定位")
    }
    guard let cal = matches.first else {
        fail("noSuchList", "找不到列表：\(nameOrID)")
    }
    return cal
}

/// Resolve a reminder by ID (EventKit fallback side).
private func ekResolveReminder(_ id: String, writer: RemindersWriter) throws -> EKReminder {
    guard let reminder = writer.reminder(id: id) else {
        fail("noSuchReminder", "找不到提醒：\(id)")
    }
    return reminder
}

func jsonOut(_ obj: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

/// Build the alarms array shared by add/update: absolute-date alarms
/// (--alarm-at), due-minus-N-minutes (--alarm-before), and location
/// triggers (--location + lat/lon [+ --proximity]).
private func buildAlarms(alarmAt: [String], alarmBefore: Int?, location: String?,
                         latitude: Double?, longitude: Double?, proximity: String?,
                         dueEpoch: Double?) throws -> [[String: Any]] {
    var alarms: [[String: Any]] = []
    for at in alarmAt {
        if let epoch = try parseDateEpoch(at) {
            alarms.append(["type": "date", "date": epoch])
        }
    }
    if let alarmBefore {
        // 提前 N 分钟 = due - N 分钟的绝对时间提醒（绕开 dueDateDelta 写限制）
        if let dueEpoch {
            alarms.append(["type": "date", "date": dueEpoch - Double(alarmBefore) * 60])
        } else {
            throw ValidationError("--alarm-before 需要同时指定 --due")
        }
    }
    if let location, let latitude, let longitude {
        var al: [String: Any] = [
            "type": "location", "title": location,
            "latitude": latitude, "longitude": longitude,
        ]
        if let p = proximity?.lowercased() {
            al["proximity"] = p == "leave" ? 2 : 1
        }
        alarms.append(al)
    }
    return alarms
}

private func reminderJSON(_ r: EKReminder) -> [String: Any] {
    var dict: [String: Any] = [
        "id": r.calendarItemIdentifier,
        "title": r.title ?? "",
        "calendar": r.calendar.title,
        "listTitle": r.calendar.title,
        "calendarId": r.calendar.calendarIdentifier,
        "completed": r.isCompleted,
        "priority": r.priority,
    ]
    if let notes = r.notes, !notes.isEmpty { dict["notes"] = notes }
    if let due = r.dueDateComponents?.date { dict["dueDate"] = due.timeIntervalSince1970 }
    if let start = r.startDateComponents?.date { dict["startDate"] = start.timeIntervalSince1970 }
    if let comp = r.completionDate { dict["completionDate"] = comp.timeIntervalSince1970 }
    if let rules = r.recurrenceRules, !rules.isEmpty {
        dict["recurrenceRules"] = String(data: try! JSONSerialization.data(withJSONObject: rules.map { EKRecurrenceRuleJSON($0) }, options: []), encoding: .utf8)!
    }
    return dict
}

private func EKRecurrenceRuleJSON(_ rule: EKRecurrenceRule) -> [String: Any] {
    var dict: [String: Any] = [
        "frequency": rule.frequency.rawValue,
        "interval": rule.interval,
    ]
    if let days = rule.daysOfTheWeek {
        dict["daysOfTheWeek"] = days.map { ["dayOfTheWeek": $0.dayOfTheWeek.rawValue, "weekNumber": $0.weekNumber] }
    }
    if let dom = rule.daysOfTheMonth { dict["daysOfTheMonth"] = dom.map { $0.intValue } }
    if let moy = rule.monthsOfTheYear { dict["monthsOfTheYear"] = moy.map { $0.intValue } }
    if let woy = rule.weeksOfTheYear { dict["weeksOfTheYear"] = woy.map { $0.intValue } }
    if let doy = rule.daysOfTheYear { dict["daysOfTheYear"] = doy.map { $0.intValue } }
    if let pos = rule.setPositions { dict["setPositions"] = pos.map { $0.intValue } }
    if rule.firstDayOfTheWeek != 0 { dict["firstDayOfTheWeek"] = rule.firstDayOfTheWeek }
    if let end = rule.recurrenceEnd {
        var endDict: [String: Any] = [:]
        if let endDate = end.endDate { endDict["endDate"] = endDate.timeIntervalSince1970 }
        if end.occurrenceCount > 0 { endDict["occurrenceCount"] = end.occurrenceCount }
        dict["recurrenceEnd"] = endDict
    }
    return dict
}

private func parseDateEpoch(_ value: String?) throws -> Double? {
    guard let value else { return nil }
    guard let date = parseDueDate(value) else {
        throw ValidationError("无效日期：\(value)。使用 YYYY-MM-DD 或 YYYY-MM-DD HH:MM")
    }
    return date.timeIntervalSince1970
}

private func parseDateOption(_ value: String?, allowTime: Bool = true) throws -> DateComponents? {
    guard let value else { return nil }
    guard let date = parseDueDate(value) else {
        throw ValidationError("无效日期：\(value)。使用 YYYY-MM-DD 或 YYYY-MM-DD HH:MM")
    }
    if allowTime {
        return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
    return Calendar.current.dateComponents([.year, .month, .day], from: date)
}

private let dayMap: [String: Int] = [
    "sun": 1, "mon": 2, "tue": 3, "wed": 4,
    "thu": 5, "fri": 6, "sat": 7,
]

/// 优先级映射（对照真实 Reminders 数据确认，2026-08）：
///   none=0, low=1, medium=5, high=9
/// 注意：Apple 的 EKReminder.priority 文档措辞是「1 = highest, 9 = lowest」，
/// 但 Reminders.app 实际存储（REMCDReminder.priority）与 iCloud 同步值用的是
/// 反过来的 9=high / 5=medium / 1=low / 0=none（pyremindkit 等实测封装均按此
/// 修正过）。本 CLI 读写都走同一原始值，故按真实约定映射。
private func parsePriority(_ value: String?) throws -> Int {
    guard let value else { return 0 }
    switch value.lowercased() {
    case "high", "h": return 9
    case "medium", "med", "m": return 5
    case "low", "l": return 1
    case "none", "0": return 0
    default:
        if let n = Int(value), (0...9).contains(n) { return n }
        throw ValidationError("无效优先级：\(value)。使用 high / medium / low 或 0-9")
    }
}

private let freqMap: [String: Int] = [
    "hourly": 4, "hour": 4,
    "daily": 0, "day": 0, "weekly": 1, "week": 1,
    "weekdays": 1, "weekends": 1,
    "monthly": 2, "month": 2, "yearly": 3, "year": 3,
]

private let presetDays: [String: [Int]] = [
    "weekdays": [2, 3, 4, 5, 6],   // 周一~周五
    "weekends": [7, 1],             // 周六、周日
]

private func parseRecurrenceDict(repeat: String?, every: Int, days: String?, until: String?,
                                  onDay: Int?, lastWorkday: Bool, months: String?,
                                  onWeekday: String?) throws -> [String: Any]? {
    guard let repeatValue = `repeat`?.lowercased() else { return nil }
    guard let freq = freqMap[repeatValue] else {
        throw ValidationError("无效重复：\(repeatValue)。使用 daily / weekly / monthly / yearly")
    }
    var dict: [String: Any] = ["frequency": freq, "interval": max(1, every)]
    if let preset = presetDays[repeatValue] {
        dict["days"] = preset
    }
    if let days {
        let names = days.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var dow: [Int] = []
        for name in names {
            guard let d = dayMap[name] else {
                throw ValidationError("无效星期：\(name)。使用 mon,tue,wed,thu,fri,sat,sun")
            }
            dow.append(d)
        }
        if !dow.isEmpty { dict["days"] = dow }
    }
    if let onDay {
        guard (1...31).contains(onDay) else {
            throw ValidationError("--on-day 范围 1-31")
        }
        dict["daysOfTheMonth"] = [onDay]
    }
    if lastWorkday {
        // 每月最后一个工作日 = 周一~周五 + setPositions[-1]
        dict["days"] = [2, 3, 4, 5, 6]
        dict["setPositions"] = [-1]
    }
    if let months {
        let nums = months.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !nums.isEmpty, nums.allSatisfy({ (1...12).contains($0) }) else {
            throw ValidationError("--months 格式：3,8（1-12 月）")
        }
        dict["monthsOfTheYear"] = nums
    }
    if let onWeekday {
        // 格式："sun:1" = 第 1 个周日；"mon" = 每周一（weekNumber 0）
        let parts = onWeekday.split(separator: ":")
        guard let name = parts.first.map({ String($0).lowercased() }), let day = dayMap[name] else {
            throw ValidationError("--on-weekday 格式：sun:1（第1个周日）或 mon（每周一）")
        }
        let week = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        dict["days"] = [["day": day, "week": week]]
    }
    if let until {
        guard let date = parseDueDate(until) else {
            throw ValidationError("无效结束日期：\(until)。使用 YYYY-MM-DD")
        }
        dict["until"] = date.timeIntervalSince1970
    }
    return dict
}

// MARK: - add

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a reminder in a list (ReminderKit write, EventKit fallback)"
    )

    @Argument(help: "Reminder title")
    var title: String

    @Option(name: .long, help: "Target list name or ID")
    var list: String?

    @Option(name: .long, help: "Target list ID (preferred; disambiguates same-named lists)")
    var listId: String?

    @Option(name: .long, help: "Notes")
    var notes: String?

    @Option(name: .long, help: "Due date: YYYY-MM-DD (all-day) or YYYY-MM-DD HH:MM")
    var due: String?

    @Option(name: .long, help: "Start date: YYYY-MM-DD or YYYY-MM-DD HH:MM")
    var start: String?

    @Option(name: .long, help: "Priority: high / medium / low / none")
    var priority: String?

    @Option(name: .customLong("repeat"), help: "Repeat: daily / weekly / monthly / yearly")
    var repeatRule: String?

    @Option(name: .long, help: "Repeat interval (every N units)")
    var every: Int = 1

    @Option(name: .long, help: "Days of week for weekly repeat: mon,tue,wed,thu,fri,sat,sun")
    var days: String?

    @Option(name: .long, help: "Repeat end date: YYYY-MM-DD")
    var until: String?

    @Option(name: .long, help: "Repeat on day of month 1-31 (with --repeat monthly)")
    var onDay: Int?

    @Flag(name: .long, help: "Monthly on the last workday (with --repeat monthly)")
    var lastWorkday: Bool = false

    @Option(name: .long, help: "Repeat in months 1-12, comma-separated (with --repeat yearly)")
    var months: String?

    @Option(name: .long, help: "Repeat on a weekday: 'sun:1' = 1st Sunday, 'mon' = every Monday")
    var onWeekday: String?

    /// Compute the next occurrence date for a recurrence rule, mirroring how
    /// Reminders.app anchors repetition to a due date. Used when --repeat is
    /// given without --due (a repeating reminder needs a due date to display).
    func nextDueDate(repeat: String?, every: Int, days: String?, onDay: Int?,
                     lastWorkday: Bool, months: String?, onWeekday: String?) -> Date? {
        guard let repeatValue = `repeat`?.lowercased() else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let cal = Calendar.current
        switch repeatValue {
        case "hourly", "hour":
            return cal.date(byAdding: .hour, value: max(1, every), to: Date())
        case "daily", "day":
            return cal.date(byAdding: .day, value: max(1, every), to: today)
        case "weekly", "week", "weekdays", "weekends":
            var wanted: [Int] = []
            if let days {
                let names = days.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                wanted = names.compactMap { dayMap[$0] }
            }
            if let preset = presetDays[repeatValue] { wanted = preset }
            if !wanted.isEmpty {
                for offset in 1...14 {
                    if let d = cal.date(byAdding: .day, value: offset, to: today) {
                        let wd = cal.component(.weekday, from: d)
                        if wanted.contains(wd) { return d }
                    }
                }
            }
            return cal.date(byAdding: .day, value: 7 * max(1, every), to: today)
        case "monthly", "month":
            if lastWorkday {
                // next month's last workday (Mon–Fri)
                var comp = cal.dateComponents([.year, .month], from: today)
                comp.month = (comp.month ?? 1) + 1
                guard let firstOfNext = cal.date(from: comp),
                      let range = cal.range(of: .day, in: .month, for: firstOfNext) else { return nil }
                let lastDay = range.count
                for day in stride(from: lastDay, through: 1, by: -1) {
                    if let d = cal.date(byAdding: .day, value: day - 1, to: firstOfNext) {
                        let wd = cal.component(.weekday, from: d)
                        if (2...6).contains(wd) { return d }
                    }
                }
                return nil
            }
            let targetDay = onDay ?? cal.component(.day, from: today)
            var comp = cal.dateComponents([.year, .month], from: today)
            comp.day = targetDay
            if let thisMonth = cal.date(from: comp), thisMonth >= today {
                return thisMonth
            }
            comp.month = (comp.month ?? 1) + 1
            return cal.date(from: comp)
        case "yearly", "year":
            if let months, let onWeekday {
                let monthNums = months.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let parts = onWeekday.split(separator: ":")
                guard let name = parts.first.map({ String($0).lowercased() }),
                      let dayNum = dayMap[name] else { return nil }
                let weekNum = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
                for year in (cal.component(.year, from: today))...(cal.component(.year, from: today) + 2) {
                    for month in monthNums {
                        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
                              let range = cal.range(of: .day, in: .month, for: first) else { continue }
                        var count = 0
                        for day in 1...range.count {
                            if let d = cal.date(from: DateComponents(year: year, month: month, day: day)) {
                                if cal.component(.weekday, from: d) == dayNum {
                                    count += 1
                                    if count == weekNum {
                                        if d >= today { return d }
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
                return nil
            }
            // yearly without options: same month/day next year (or this year if later)
            var comp = cal.dateComponents([.month, .day], from: today)
            comp.year = cal.component(.year, from: today)
            if let thisYear = cal.date(from: comp), thisYear >= today {
                return thisYear
            }
            comp.year = (comp.year ?? 0) + 1
            return cal.date(from: comp)
        default:
            return nil
        }
    }

    @Option(name: .long, help: "Tag (repeatable)")
    var tag: [String] = []

    @Flag(name: .long, help: "Mark as urgent")
    var urgent: Bool = false

    @Flag(name: [.customLong("flagged"), .customLong("flag")], help: "Mark as flagged")
    var flagged: Bool = false

    @Option(name: .long, help: "Parent reminder ID (creates a subtask)")
    var parent: String?

    @Option(name: .long, help: "Section to file the reminder into (must exist in the list; use add-section first)")
    var section: String?

    @Option(name: .long, help: "Smart list name or ID — file the reminder into a section OF THE SMART LIST (virtual view) instead of the physical list's section")
    var smartList: String?

    @Option(name: .long, help: "URL (https://…)")
    var url: String?

    @Option(name: .long, help: "Absolute-time alarm: YYYY-MM-DD HH:MM (repeatable)")
    var alarmAt: [String] = []

    @Option(name: .long, help: "Alarm N minutes before the due date (falls back to an absolute-time alarm)")
    var alarmBefore: Int?

    @Option(name: .long, help: "Location reminder: place name")
    var location: String?

    @Option(name: .long, help: "Latitude for the location reminder")
    var latitude: Double?

    @Option(name: .long, help: "Longitude for the location reminder")
    var longitude: Double?

    @Option(name: .long, help: "Proximity: arrive (default) or leave")
    var proximity: String?

    func run() throws {
        guardWriteEnabled()
        var effectiveDue = due
        if repeatRule != nil && effectiveDue == nil {
            if let next = nextDueDate(repeat: repeatRule, every: every, days: days,
                                      onDay: onDay, lastWorkday: lastWorkday,
                                      months: months, onWeekday: onWeekday) {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                let isHourly = (repeatRule?.lowercased() == "hourly" || repeatRule?.lowercased() == "hour")
                f.dateFormat = isHourly ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
                effectiveDue = f.string(from: next)
            }
        }
        let dueEpoch = try parseDateEpoch(effectiveDue)
        let startEpoch = try parseDateEpoch(start)
        let priorityInt = try parsePriority(priority)
        let recurrence = try parseRecurrenceDict(repeat: repeatRule, every: every, days: days, until: until,
                                                 onDay: onDay, lastWorkday: lastWorkday, months: months,
                                                 onWeekday: onWeekday)

        guard list != nil || listId != nil else {
            throw ValidationError("需要指定目标列表：--list 或 --list-id")
        }
        var request: [String: Any] = [
            "op": "add",
            "title": title,
            "author": "remindkit",
        ]
        if let list { request["listName"] = list }
        if let listId { request["listID"] = listId }
        if let notes, !notes.isEmpty { request["notes"] = notes }
        if let dueEpoch { request["due"] = dueEpoch }
        if let startEpoch { request["start"] = startEpoch }
        if priorityInt != 0 { request["priority"] = priorityInt }
        if urgent { request["urgent"] = true }
        if flagged { request["flagged"] = true }
        if !tag.isEmpty { request["tags"] = tag }
        if let parent, !parent.isEmpty { request["parentId"] = parent }
        if let section, !section.isEmpty { request["section"] = section }
        if let smartList, !smartList.isEmpty {
            // smartList 参数可能是名称或 UUID：交由 Write.m 的 resolveSmartList 判定。
            // 简单启发：含连字符的 UUID 形状按 ID 传，否则按名称传（与 list/listId 约定一致）。
            if smartList.contains("-") && smartList.count >= 8 {
                request["smartListID"] = smartList
            } else {
                request["smartListName"] = smartList
            }
        }
        if let recurrence { request["recurrence"] = recurrence }
        if let url, !url.isEmpty { request["url"] = url }

        let alarms = try buildAlarms(alarmAt: alarmAt, alarmBefore: alarmBefore, location: location,
                                     latitude: latitude, longitude: longitude, proximity: proximity,
                                     dueEpoch: dueEpoch)
        if !alarms.isEmpty { request["alarms"] = alarms }

        let (source, result) = try writeWithReminderKit(request) {
            // EventKit fallback: core fields only (tags/urgent/subtask are
            // not writable via EventKit → degrade with a warning).
            let store = RemindersAuth.requestAccessSync()
            let writer = RemindersWriter(store: store)
            // listId 优先；name/id 都走严格解析（重名/前缀冲突报 ambiguousList）
            let calendar = try ekResolveList(listId ?? list ?? "", writer: writer)

            let hasTime = effectiveDue?.contains(":") == true
            let ekReminder = try writer.add(
                title: title,
                to: calendar,
                notes: notes,
                due: try parseDateOption(effectiveDue, allowTime: hasTime),
                start: try parseDateOption(start),
                priority: priorityInt,
                recurrence: try parseRecurrenceRule(repeat: repeatRule, every: every, days: days, until: until)
            )
            var degraded = false
            if urgent || flagged || !tag.isEmpty || parent != nil || section != nil
                || url != nil || !alarmAt.isEmpty || alarmBefore != nil || location != nil {
                degraded = true
            }
            var dict = reminderJSON(ekReminder)
            if degraded { dict["degraded"] = true }
            return dict
        }

        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }

    private func parseRecurrenceRule(repeat: String?, every: Int, days: String?, until: String?) throws -> EKRecurrenceRule? {
        guard let repeatValue = `repeat`?.lowercased() else { return nil }
        let freq: EKRecurrenceFrequency
        switch repeatValue {
        case "daily", "day": freq = .daily
        case "weekly", "week": freq = .weekly
        case "monthly", "month": freq = .monthly
        case "yearly", "year": freq = .yearly
        default: throw ValidationError("无效重复：\(repeatValue)。使用 daily / weekly / monthly / yearly")
        }
        var daysOfWeek: [EKRecurrenceDayOfWeek]? = nil
        if let days {
            daysOfWeek = try days.split(separator: ",").map { name in
                let n = name.trimmingCharacters(in: .whitespaces).lowercased()
                guard let d = dayMap[n], let weekday = EKWeekday(rawValue: d) else {
                    throw ValidationError("无效星期：\(name).trimmingCharacters(in: .whitespaces)。使用 mon,tue,wed,thu,fri,sat,sun")
                }
                return EKRecurrenceDayOfWeek(dayOfTheWeek: weekday, weekNumber: 0)
            }
        }
        let end: EKRecurrenceEnd? = try {
            guard let until else { return nil }
            guard let date = parseDueDate(until) else {
                throw ValidationError("无效结束日期：\(until)。使用 YYYY-MM-DD")
            }
            return EKRecurrenceEnd(end: date)
        }()
        return EKRecurrenceRule(
            recurrenceWith: freq,
            interval: max(1, every),
            daysOfTheWeek: daysOfWeek,
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
            daysOfTheYear: nil, setPositions: nil, end: end
        )
    }
}

// MARK: - complete / reopen

struct Complete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "complete",
        abstract: "Mark a reminder as completed (ReminderKit write, EventKit fallback)"
    )

    @Argument(help: "Reminder ID")
    var id: String

    @Flag(name: .long, help: "Un-complete instead (reopen)")
    var reopen: Bool = false

    func run() throws {
        guardWriteEnabled()
        let completed = !reopen
        let request: [String: Any] = ["op": "complete", "id": id, "completed": completed, "author": "remindkit"]

        let (source, result) = try writeWithReminderKit(request) {
            let store = RemindersAuth.requestAccessSync()
            let writer = RemindersWriter(store: store)
            let reminder = try ekResolveReminder(id, writer: writer)
            try writer.setCompleted(reminder, completed: completed)
            return ["id": id, "completed": completed, "completionDate": reminder.completionDate?.timeIntervalSince1970 ?? 0]
        }

        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }

        // 重复提醒：完成后 remindd 会自动把同一 ID 滚动到下一期（dueDate 变未来、仍未完成）。
        // 显式提示 agent，避免把「已完成」误判为永久完成（如每月充值、每周 gtd）。
        if completed, let next = nextOccurrenceAfterComplete(id: id) {
            out["nextOccurrence"] = next.epoch
            out["nextOccurrenceText"] = next.text
        }
        try jsonOut(out)
    }
}

/// 完成操作后重新查询该提醒：若同一 ID 仍未完成且带未来 dueDate，
/// 说明重复规则已滚动到下一期，返回下一期日期（epoch + 可读文本）。
private func nextOccurrenceAfterComplete(id: String) -> (epoch: Double, text: String)? {
    let data = fetchEnrichedData()
    guard let r = data.reminders.first(where: { $0.id == id }) else { return nil }
    guard !r.completed, let due = r.dueDate else { return nil }
    return (due, reminderDateText(due, timeZone: r.timeZone) ?? "")
}

// MARK: - Recently-deleted cache

/// Local record of reminders deleted through remindkit. ReminderKit cannot
/// enumerate marked-for-delete objects, so we keep the IDs we deleted and
/// verify their status on demand via `fetchReminderIncludingMarkedForDelete`.
struct DeletedRecord: Codable {
    let id: String
    let title: String
    let listName: String
    let deletedAt: Double
}

private func deletedCacheURL() -> URL {
    // Override with REMINDKIT_DELETED_CACHE (e.g. a temp file in tests) so
    // the smoke test never touches the user's real recently-deleted cache.
    if let env = ProcessInfo.processInfo.environment["REMINDKIT_DELETED_CACHE"],
       !env.isEmpty {
        return URL(fileURLWithPath: env)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/remindkit/deleted.json")
}

private func loadDeletedCache() -> [DeletedRecord] {
    let url = deletedCacheURL()
    guard let data = try? Data(contentsOf: url) else { return [] }
    guard let records = try? JSONDecoder().decode([DeletedRecord].self, from: data) else {
        // 损坏的 deleted.json 不能静默当空：备份后再返回空，避免覆盖真实记录。
        backupCorruptFile(url, label: "deleted.json")
        return []
    }
    return records
}

private func saveDeletedCache(_ records: [DeletedRecord]) {
    let url = deletedCacheURL()
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(records) else { return }
    // 原子写（唯一 tmp + replace）：崩溃不损坏 deleted.json。
    let tmp = uniqueTempURL(for: url)
    do {
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    } catch {
        fputs("remindkit: warning: 无法写入最近删除缓存（\(error.localizedDescription)）\n", stderr)
    }
}

private func appendDeletedRecord(_ record: DeletedRecord) {
    var records = loadDeletedCache()
    records.removeAll { $0.id == record.id }
    records.append(record)
    saveDeletedCache(records)
}

private func removeDeletedRecord(id: String) {
    var records = loadDeletedCache()
    records.removeAll { $0.id == id }
    saveDeletedCache(records)
}

// MARK: - recently-deleted

struct RecentlyDeleted: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recently-deleted",
        abstract: "List reminders deleted via remindkit that are still in Recently Deleted"
    )

    func run() throws {
        let records = loadDeletedCache()
        guard !records.isEmpty else {
            try jsonOut(["count": 0, "items": []])
            return
        }

        // Verify which are still marked-for-delete via the subprocess.
        let request: [String: Any] = ["op": "deleted", "ids": records.map { $0.id }, "author": "remindkit"]
        var stillDeleted: [String: Any] = [:]
        var verification = "verified"
        switch runReminderKitWrite(request) {
        case .success(let rk):
            if let ok = rk["ok"] as? Bool, ok,
               let deleted = rk["deleted"] as? [[String: Any]] {
                for d in deleted {
                    if let id = d["id"] as? String {
                        stillDeleted[id] = d
                    }
                }
            }
        case .unavailable:
            verification = "unavailable"
        case .unknownOutcome:
            // 无法确认哪些还在「最近删除」：保留全部记录并显式标注，避免
            // 把「结果未知」误报成「已恢复或已清除」。
            verification = "unknown"
        }

        let out: [[String: Any]] = records.compactMap { record in
            if verification == "unknown" {
                return [
                    "id": record.id,
                    "title": record.title,
                    "listName": record.listName,
                    "deletedAt": record.deletedAt,
                    "verification": "unknown",
                ]
            }
            guard stillDeleted[record.id] != nil else { return nil } // restored or purged
            return [
                "id": record.id,
                "title": record.title,
                "listName": record.listName,
                "deletedAt": record.deletedAt,
            ]
        }
        var payload: [String: Any] = ["count": out.count, "items": out]
        if verification != "verified" { payload["verification"] = verification }
        try jsonOut(payload)
    }
}

// MARK: - restore

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a reminder from Recently Deleted to its original list"
    )

    @Argument(help: "Reminder ID (from recently-deleted)")
    var id: String

    @Option(name: .long, help: "Target list name (default: the list it was deleted from)")
    var list: String?

    @Option(name: .long, help: "Target list ID (preferred; disambiguates same-named lists)")
    var listId: String?

    func run() throws {
        guardWriteEnabled()
        let record = loadDeletedCache().first { $0.id == id }
        guard let record else {
            fail("noSuchDeletedRecord", "找不到删除记录：\(id)。用 recently-deleted 查看可恢复的提醒。")
        }
        let targetList = list ?? record.listName

        var request: [String: Any] = ["op": "restore", "id": id, "listName": targetList, "author": "remindkit"]
        if let listId { request["listID"] = listId }
        switch runReminderKitWrite(request) {
        case .unavailable:
            fail("reminderKitError", "ReminderKit 子进程不可用，无法恢复（恢复只支持 ReminderKit 路径）。")
        case .unknownOutcome(let detail):
            fail("writeResultUnknown", "恢复结果未知：\(detail)。请用 recently-deleted 核对后重试。")
        case .success(let rk):
            if let ok = rk["ok"] as? Bool, ok {
                removeDeletedRecord(id: id)
                var out: [String: Any] = ["ok": true, "source": "reminderKit"]
                for (k, v) in rk where k != "ok" { out[k] = v }
                try jsonOut(out)
            } else {
                failReminderKitError(rk)
            }
        }
    }
}

// MARK: - delete

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a reminder (soft delete → Recently Deleted; ReminderKit write, no EventKit fallback)"
    )

    @Argument(help: "Reminder ID")
    var id: String

    func run() throws {
        guardWriteEnabled()
        let request: [String: Any] = ["op": "delete", "id": id, "author": "remindkit"]

        // EventKit fallback deliberately disabled for delete: the public-API
        // path (`EKEventStore.remove`) is a HARD delete, while the ReminderKit
        // path soft-deletes into Recently Deleted. Falling back could
        // permanently destroy a reminder — fail instead.
        let (source, result) = try writeWithReminderKit(request) {
            fail("reminderKitRequired",
                 "删除提醒需要 ReminderKit 子进程（EventKit 兜底是硬删除，会绕过「最近删除」，已禁用）。请检查子进程可用性。")
        }

        // Record in the recently-deleted cache (both paths are soft deletes).
        if let title = result["title"] as? String,
           let listName = result["listName"] as? String {
            appendDeletedRecord(DeletedRecord(
                id: id, title: title, listName: listName,
                deletedAt: Date().timeIntervalSince1970
            ))
        }

        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}

// MARK: - update (flagged/urgent on existing reminders)

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an existing reminder: fields (title/notes/due/priority/tags/url/repeat) and flags (flag/urgent)"
    )

    @Argument(help: "Reminder ID")
    var id: String

    @Option(name: .long, help: "New title")
    var title: String?

    @Option(name: .long, help: "New notes")
    var notes: String?

    @Option(name: .long, help: "New due date (YYYY-MM-DD all-day | YYYY-MM-DD HH:MM)")
    var due: String?

    @Option(name: .long, help: "New start date")
    var start: String?

    @Option(name: .long, help: "New priority: high|medium|low")
    var priority: String?

    @Option(name: .long, help: "Set tags (repeatable)")
    var tag: [String] = []

    @Option(name: .long, help: "New URL")
    var url: String?

    @Option(name: .customLong("repeat"), help: "Repeat rule: daily|weekly|monthly|yearly")
    var repeatRule: String?

    @Option(name: .long, help: "Repeat every N units")
    var every: Int?

    @Option(name: .long, help: "Repeat on days: mon,tue,wed,thu,fri,sat,sun")
    var days: String?

    @Option(name: .long, help: "Repeat until YYYY-MM-DD")
    var until: String?

    @Option(name: .long, help: "Append to the existing notes (instead of replacing)")
    var notesAppend: String?

    @Option(name: .long, help: "Set an absolute alarm (YYYY-MM-DD HH:MM, repeatable)")
    var alarmAt: [String] = []

    @Option(name: .long, help: "Parent reminder ID (attach this reminder as a subtask; parent must be in the same list and itself not a subtask)")
    var parent: String?

    @Flag(name: .long, help: "Detach from its parent (make this reminder a top-level task)")
    var noParent: Bool = false

    @Option(name: .long, help: "Move to a section (must exist in the list; use add-section first)")
    var section: String?

    @Option(name: .long, help: "Smart list name or ID — move the reminder into a section OF THE SMART LIST (virtual view) instead of its physical list's section")
    var smartList: String?

    @Option(name: .long, help: "Alarm N minutes before the due date (requires --due)")
    var alarmBefore: Int?

    @Option(name: .long, help: "Location reminder title (requires --latitude/--longitude)")
    var location: String?

    @Option(name: .long, help: "Latitude for the location reminder")
    var latitude: Double?

    @Option(name: .long, help: "Longitude for the location reminder")
    var longitude: Double?

    @Option(name: .long, help: "Proximity for location reminder: arrive (default) or leave")
    var proximity: String?

    @Flag(name: [.customLong("flag"), .customLong("flagged")], help: "Set the flag (当前关注的短期任务)")
    var flag: Bool = false

    @Flag(name: [.customLong("no-flag"), .customLong("no-flagged")], help: "Clear the flag")
    var noFlag: Bool = false

    @Flag(name: .long, help: "Mark urgent")
    var urgent: Bool = false

    @Flag(name: .long, help: "Unmark urgent")
    var noUrgent: Bool = false

    func validate() throws {
        if flag && noFlag {
            throw ValidationError("--flag and --no-flag are mutually exclusive")
        }
        if urgent && noUrgent {
            throw ValidationError("--urgent and --no-urgent are mutually exclusive")
        }
        if parent != nil && noParent {
            throw ValidationError("--parent and --no-parent are mutually exclusive")
        }
        if title == nil && notes == nil && notesAppend == nil && due == nil && start == nil && priority == nil
            && tag.isEmpty && url == nil && repeatRule == nil && until == nil
            && alarmAt.isEmpty && alarmBefore == nil && location == nil
            && !flag && !noFlag && !urgent && !noUrgent && section == nil && parent == nil && !noParent {
            throw ValidationError("specify at least one field or flag to update")
        }
    }

    func run() throws {
        guardWriteEnabled()
        var request: [String: Any] = ["op": "update", "id": id, "author": "remindkit"]
        if let title { request["title"] = title }
        if let notes { request["notes"] = notes }
        // --notes-append: read current notes and append (avoids a read+concat round-trip).
        var effectiveNotes = notes
        if let append = notesAppend {
            let data = fetchEnrichedData(includeSections: false)
            let current = data.reminders.first { $0.id == id }?.notes ?? ""
            effectiveNotes = current.isEmpty ? append : current + "\n" + append
            request["notes"] = effectiveNotes
        }
        let dueRequested = try parseDateEpoch(due)
        if let dueRequested { request["due"] = dueRequested }
        if let start, let epoch = try parseDateEpoch(start) { request["start"] = epoch }
        if let priority {
            let p = try parsePriority(priority)
            if p != 0 { request["priority"] = p }
        }
        if !tag.isEmpty { request["tags"] = tag }
        if let url, !url.isEmpty { request["url"] = url }
        if let recurrence = try parseRecurrenceDict(repeat: repeatRule, every: every ?? 1,
                                                    days: days, until: until, onDay: nil,
                                                    lastWorkday: false, months: nil, onWeekday: nil) {
            request["recurrence"] = recurrence
        }
        if flag { request["flagged"] = true }
        if noFlag { request["flagged"] = false }
        if urgent { request["urgent"] = true }
        if noUrgent { request["urgent"] = false }
        if let section, !section.isEmpty { request["section"] = section }
        if let smartList, !smartList.isEmpty {
            if smartList.contains("-") && smartList.count >= 8 {
                request["smartListID"] = smartList
            } else {
                request["smartListName"] = smartList
            }
        }
        if let parent, !parent.isEmpty { request["parentId"] = parent }
        if noParent { request["noParent"] = true }

        // --alarm-before 基准：本次显式 --due 优先，否则用提醒当前 dueDate。
        var alarmDueEpoch = dueRequested
        if alarmBefore != nil && alarmDueEpoch == nil {
            let data = fetchEnrichedData(includeSections: false)
            alarmDueEpoch = data.reminders.first { $0.id == id }?.dueDate
        }
        let alarms = try buildAlarms(alarmAt: alarmAt, alarmBefore: alarmBefore, location: location,
                                     latitude: latitude, longitude: longitude, proximity: proximity,
                                     dueEpoch: alarmDueEpoch)
        if !alarms.isEmpty { request["alarms"] = alarms }

        let (source, result) = try writeWithReminderKit(request) {
            // EventKit fallback: core fields only (tags/repeat/flag/urgent degrade).
            let store = RemindersAuth.requestAccessSync()
            let writer = RemindersWriter(store: store)
            guard let reminder = writer.reminder(id: id) else {
                fail("noSuchReminder", "找不到提醒：\(id)")
            }
            try writer.update(
                reminder,
                title: title,
                notes: effectiveNotes,
                due: try parseDateOption(due),
                start: try parseDateOption(start),
                priority: priority.flatMap { try? parsePriority($0) }
            )
            var dict = reminderJSON(reminder)
            if !tag.isEmpty || repeatRule != nil || flag || noFlag || urgent || noUrgent || section != nil
                || parent != nil || noParent || url != nil || !alarmAt.isEmpty || alarmBefore != nil || location != nil {
                dict["degraded"] = true
            }
            return dict
        }

        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}

// MARK: - move

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a reminder to another list (ReminderKit write, EventKit fallback)"
    )

    @Argument(help: "Reminder ID")
    var id: String

    @Option(name: .long, help: "Target list name or ID")
    var to: String?

    @Option(name: .long, help: "Target list ID (preferred; disambiguates same-named lists)")
    var toId: String?

    func run() throws {
        guardWriteEnabled()
        guard to != nil || toId != nil else {
            throw ValidationError("需要指定目标列表：--to 或 --to-id")
        }
        var request: [String: Any] = ["op": "move", "id": id, "author": "remindkit"]
        if let to { request["toListName"] = to }
        if let toId { request["toListID"] = toId }

        let (source, result) = try writeWithReminderKit(request) {
            let store = RemindersAuth.requestAccessSync()
            let writer = RemindersWriter(store: store)
            let reminder = try ekResolveReminder(id, writer: writer)
            let fromTitle = reminder.calendar.title
            // toId 优先；都走严格解析（重名/前缀冲突报 ambiguousList）
            let target = try ekResolveList(toId ?? to ?? "", writer: writer)
            try writer.move(reminder, to: target)
            return ["id": id, "from": fromTitle, "to": target.title]
        }

        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}

// MARK: - delete-list

struct DeleteList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-list",
        abstract: "Permanently delete a list (regular or smart list)"
    )

    @Argument(help: "List name (optional if --id is given)")
    var name: String?

    @Option(name: .long, help: "List ID (preferred; disambiguates same-named lists)")
    var id: String?

    @Flag(name: .long, help: "Confirm deletion (required — permanent, no undo)")
    var yes: Bool = false

    func run() throws {
        guardWriteEnabled()
        guard name != nil || id != nil else {
            throw ValidationError("需要指定列表：name 参数或 --id")
        }
        guard yes else {
            fail("confirmationRequired",
                 "delete-list is permanent and cannot be undone (the whole list incl. its reminders is gone). Pass --yes to confirm.")
        }
        var request: [String: Any] = ["op": "deleteList", "author": "remindkit"]
        if let name { request["listName"] = name }
        if let id { request["listID"] = id }

        // EventKit fallback deliberately disabled for delete-list: the
        // public-API path removes the calendar outright (permanent, no undo),
        // and can only resolve lists by name/ID — never smart lists or
        // groups. Fail instead of risking a wrong/permanent deletion.
        let (source, result) = try writeWithReminderKit(request) {
            fail("reminderKitRequired",
                 "删除列表需要 ReminderKit 子进程（EventKit 兜底无法处理智能列表/分组且为永久删除，已禁用）。请检查子进程可用性。")
        }

        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}

// MARK: - update-list

struct UpdateList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-list",
        abstract: "Rename a list, group, or smart list (re-icon/re-color lists only)"
    )

    @Argument(help: "List / group / smart list name (optional if --id is given)")
    var name: String?

    @Option(name: .long, help: "ID (preferred; disambiguates same-named entities)")
    var id: String?

    @Option(name: .long, help: "New name")
    var newName: String?

    @Option(name: .long, help: "New icon (single emoji; lists only)")
    var icon: String?

    @Option(name: .long, help: "New color: #RRGGBB hex or a preset name (red/orange/yellow/green/blue/purple/gray/brown); lists only")
    var color: String?

    @Option(name: .long, help: "Entity type to narrow resolution: list | group | smartlist")
    var type: String?

    func run() throws {
        guardWriteEnabled()
        guard name != nil || id != nil else {
            throw ValidationError("需要指定名称：name 参数或 --id")
        }
        if newName == nil && icon == nil && color == nil {
            throw ValidationError("至少提供一个要更新的字段：--new-name / --icon / --color")
        }
        if let type {
            let allowed: Set<String> = ["list", "group", "smartlist"]
            guard allowed.contains(type.lowercased()) else {
                throw ValidationError("--type 只接受 list | group | smartlist（收到：\(type)）")
            }
        }

        var request: [String: Any] = ["op": "updateList", "author": "remindkit"]
        if let name { request["listName"] = name }
        if let id { request["listID"] = id }
        if let newName { request["newName"] = newName }
        if let icon { request["icon"] = icon }
        if let color {
            request["color"] = normalizeColor(color)
            // pass the palette name through so the subprocess can pick the
            // right REMColor symbolic name (gray/lightBlue/indigo/pink/rose
            // honor the hex; red/orange/yellow/green/blue/purple/brown use the
            // system palette color).
            request["colorName"] = canonicalColorName(color)
        }
        if let type { request["type"] = type.lowercased() }

        let (source, result) = try writeWithReminderKit(request) {
            // EventKit fallback: rename via EKCalendar. icon/color are not
            // writable via EventKit — surface a degraded marker instead of
            // pretending an empty update succeeded. Groups / smart lists are
            // not exposed to EventKit at all (noSuchList on resolution).
            let store = RemindersAuth.requestAccessSync()
            let writer = RemindersWriter(store: store)
            let lookup = id ?? name ?? ""
            let calendar = try ekResolveList(lookup, writer: writer)
            if let newName { calendar.title = newName }
            try store.saveCalendar(calendar, commit: true)
            var dict: [String: Any] = ["listName": newName ?? name ?? "", "updated": true]
            if icon != nil || color != nil {
                dict["degraded"] = true
                dict["degradedReason"] = "EventKit 无法写入图标/颜色（仅支持改名）；如需图标/颜色请用 ReminderKit 子进程"
            }
            return dict
        }

        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }

    /// Map the 12-color Reminders palette: preset names use the symbolic color,
    /// others (lightBlue/indigo/pink/gray/rose) honor the hex value.
    /// Returns the hex to write for a given color name (or the raw hex input).
    private func canonicalColorName(_ value: String) -> String {
        let canonical: [String: String] = [
            "red": "red", "orange": "orange", "yellow": "yellow", "green": "green",
            "lightblue": "lightBlue", "blue": "blue", "indigo": "indigo", "pink": "pink",
            "purple": "purple", "brown": "brown", "gray": "gray", "grey": "gray",
            "rose": "rose",
        ]
        if let name = canonical[value.lowercased()] { return name }
        return "gray"
    }

    private func normalizeColor(_ value: String) -> String {
        let palette: [String: String] = [
            "red": "#FF383C", "orange": "#FF8D28", "yellow": "#FFCC00",
            "green": "#83D754", "lightblue": "#5AC8FA", "blue": "#007AFF",
            "indigo": "#5856D6", "pink": "#FF2D55", "purple": "#CB30E0",
            "brown": "#AC7F5E", "gray": "#5B626A", "grey": "#5B626A",
            "rose": "#D9A69F",
        ]
        if let hex = palette[value.lowercased()] { return hex }
        return value
    }
}

// MARK: - add-list

struct AddList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-list",
        abstract: "Create a new reminder list (optionally inside a group)"
    )

    @Argument(help: "New list name")
    var name: String

    @Option(name: .long, help: "Create the list inside this group (group name)")
    var group: String?

    @Option(name: .long, help: "Create the list inside this group (group ID)")
    var groupId: String?

    func run() throws {
        guardWriteEnabled()
        guard group == nil || groupId == nil else {
            throw ValidationError("--group and --group-id are mutually exclusive")
        }
        var request: [String: Any] = ["op": "createList", "name": name, "author": "remindkit"]
        if let group { request["groupName"] = group }
        if let groupId { request["groupID"] = groupId }

        let (source, result) = try writeWithReminderKit(request) {
            // EventKit fallback: no group support — plain top-level lists only.
            guard group == nil && groupId == nil else {
                fail("unsupportedByEventKit", "EventKit 兜底不支持在分组内创建列表（需要 ReminderKit 子进程）")
            }
            let store = RemindersAuth.requestAccessSync()
            let writer = RemindersWriter(store: store)
            let calendar = try writer.createList(named: name)
            return ["calendar": ["id": calendar.calendarIdentifier, "title": calendar.title]]
        }

        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        // Normalize the subprocess shape {id, name} to {calendar: {id, title}}.
        if let id = result["id"] as? String, out["calendar"] == nil {
            out["calendar"] = ["id": id, "title": result["name"] ?? name]
        }
        try jsonOut(out)
    }
}

// MARK: - add-group

struct AddGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-group",
        abstract: "Create a group (folder) to hold lists"
    )

    @Argument(help: "New group name")
    var name: String

    func run() throws {
        guardWriteEnabled()
        let request: [String: Any] = ["op": "createGroup", "name": name, "author": "remindkit"]
        let (source, result) = try writeWithReminderKit(request) {
            fail("unsupportedByEventKit", "EventKit 不支持分组（需要 ReminderKit 子进程）")
        }
        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        if let id = result["id"] as? String {
            out["group"] = ["id": id, "title": result["name"] ?? name]
        }
        try jsonOut(out)
    }
}

// MARK: - add-section

struct AddSection: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-section",
        abstract: "Add a section to a list or smart list (reminders can then be filed into it via add --section / update --section)"
    )

    @Argument(help: "List name or ID")
    var list: String

    @Argument(help: "New section name")
    var name: String

    @Option(name: .long, help: "List ID (preferred; disambiguates same-named lists)")
    var listId: String?

    @Flag(name: .long, help: "Target is a smart list (virtual view) instead of a regular list")
    var smartList: Bool = false

    func run() throws {
        guardWriteEnabled()
        var request: [String: Any] = ["op": "addSection", "name": name, "author": "remindkit"]
        if smartList { request["smartList"] = true }
        if let listId { request["listID"] = listId } else { request["listName"] = list }
        let (source, result) = try writeWithReminderKit(request) {
            fail("unsupportedByEventKit", "EventKit 不支持分区（需要 ReminderKit 子进程）")
        }
        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}

// MARK: - delete-section

struct DeleteSection: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-section",
        abstract: "Delete a section from a list (reminders in it move to the un-sectioned area)"
    )

    @Argument(help: "List name or ID")
    var list: String

    @Argument(help: "Section name to delete")
    var name: String

    @Option(name: .long, help: "List ID (preferred; disambiguates same-named lists)")
    var listId: String?

    func run() throws {
        guardWriteEnabled()
        var request: [String: Any] = ["op": "deleteSection", "name": name, "author": "remindkit"]
        if let listId { request["listID"] = listId } else { request["listName"] = list }
        let (source, result) = try writeWithReminderKit(request) {
            fail("unsupportedByEventKit", "EventKit 不支持分区（需要 ReminderKit 子进程）")
        }
        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}

// MARK: - add-smartlist

struct AddSmartList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-smartlist",
        abstract: "Create a custom smart list (optionally with a color and/or hashtag filter)"
    )

    @Argument(help: "New smart list name")
    var name: String

    @Option(name: .long, help: "Custom display name (defaults to the name)")
    var displayName: String?

    @Option(name: .long, help: "Color hex, e.g. #FF3B30")
    var color: String?

    @Option(name: .long, help: "Match reminders tagged with this tag (hashtag filter; repeatable)")
    var tag: [String] = []

    @Option(name: .long, help: "Create inside this group (folder) — name or UUID")
    var group: String?

    func run() throws {
        guardWriteEnabled()
        var request: [String: Any] = ["op": "createSmartList", "name": name, "author": "remindkit"]
        if let displayName { request["displayName"] = displayName }
        if let color { request["color"] = color }
        if let group, !group.isEmpty {
            // 同 list/listId 约定：含连字符的 UUID 形状按 ID 传，否则按名称传。
            if group.contains("-") && group.count >= 8 {
                request["groupID"] = group
            } else {
                request["groupName"] = group
            }
        }
        if !tag.isEmpty {
            // filterData JSON shape matches what Reminders.app writes for a
            // hashtag filter: {"hashtags":{"hashtags":["标签"]}}. Sent as a
            // string — the subprocess converts it to NSData (a raw Data value
            // cannot cross the JSON request boundary).
            let filter: [String: Any] = ["hashtags": ["hashtags": tag]]
            if let data = try? JSONSerialization.data(withJSONObject: filter),
               let jsonString = String(data: data, encoding: .utf8) {
                request["filterData"] = jsonString
            }
        }
        let (source, result) = try writeWithReminderKit(request) {
            fail("unsupportedByEventKit", "EventKit 不支持智能列表（需要 ReminderKit 子进程）")
        }
        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}

// MARK: - move-list

struct MoveList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move-list",
        abstract: "Move a list into/out of a group, or set its display order"
    )

    @Argument(help: "List name or ID")
    var list: String

    @Option(name: .long, help: "List ID (preferred; disambiguates same-named lists)")
    var listId: String?

    @Option(name: .long, help: "Target group name (move the list into this group)")
    var toGroup: String?

    @Option(name: .long, help: "Target group ID")
    var toGroupId: String?

    @Flag(name: .long, help: "Move the list out of its group to the top level")
    var outOfGroup: Bool = false

    @Option(name: .long, help: "Display order (index into the sidebar list ordering; get the length from dump listIDsOrdering)")
    var order: Int?

    @Option(name: .long, help: "Entity type to narrow resolution: list | smartlist (--type smartlist disambiguates same-named smart lists)")
    var type: String?

    func validate() throws {
        if toGroup != nil && toGroupId != nil {
            throw ValidationError("--to-group and --to-group-id are mutually exclusive")
        }
        if (toGroup != nil || toGroupId != nil) && outOfGroup {
            throw ValidationError("--to-group/--to-group-id and --out-of-group are mutually exclusive")
        }
        if toGroup == nil && toGroupId == nil && !outOfGroup && order == nil {
            throw ValidationError("specify --to-group/--to-group-id, --out-of-group, or --order")
        }
        if let type {
            let allowed = ["list", "smartlist"]
            guard allowed.contains(type.lowercased()) else {
                throw ValidationError("--type 只接受 list | smartlist（收到：\(type)）")
            }
        }
    }

    func run() throws {
        guardWriteEnabled()
        var request: [String: Any] = ["op": "moveList", "listName": list, "author": "remindkit"]
        if let listId { request["listID"] = listId }
        if let toGroup { request["groupName"] = toGroup }
        if let toGroupId { request["groupID"] = toGroupId }
        if outOfGroup { request["outOfGroup"] = true }
        if let order { request["order"] = order }
        if let type { request["type"] = type.lowercased() }

        let (source, result) = try writeWithReminderKit(request) {
            fail("unsupportedByEventKit", "EventKit 不支持分组（需要 ReminderKit 子进程）")
        }
        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}
