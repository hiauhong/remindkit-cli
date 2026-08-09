import ArgumentParser
import Darwin
import Foundation

// MARK: - Query output

enum QueryFormat: String, ExpressibleByArgument, Codable {
    case json
    case plain
    case count

    /// Default output format: plain on a TTY (human reads it), json when
    /// stdout is piped (an agent or script consumes it) — so agents don't
    /// need to remember `--format json` on every call.
    static func auto() -> QueryFormat {
        isatty(STDOUT_FILENO) != 0 ? .plain : .json
    }
}

let dueDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

// MARK: - Count breakdown

struct CountResult: Codable {
    let total: Int
    let incomplete: Int
    let completed: Int
    let flagged: Int
    let urgent: Int
    let dueToday: Int
    let overdue: Int
    /// Lists a `--list` filter resolved to (absent when unscoped).
    var matchedLists: [ListRef]? = nil
}

/// Compute a compact count breakdown for a (possibly filtered) reminder set.
/// `incomplete` / `completed` are always both reported so the scope is explicit.
func countBreakdown(_ entries: [ReminderEntry]) -> CountResult {
    let today = startOfToday()
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

    let incomplete = entries.filter { !$0.completed }
    return CountResult(
        total: entries.count,
        incomplete: incomplete.count,
        completed: entries.filter(\.completed).count,
        flagged: entries.filter(\.flagged).count,
        urgent: entries.filter(\.urgent).count,
        dueToday: incomplete.filter {
            guard let due = $0.dueDate else { return false }
            let dueDate = Date(timeIntervalSince1970: due)
            return dueDate >= today && dueDate < tomorrow
        }.count,
        overdue: incomplete.filter {
            guard let due = $0.dueDate else { return false }
            return Date(timeIntervalSince1970: due) < today
        }.count
    )
}

/// Shared plain/JSON/count renderer for reminder query results.
/// `fields` (when set) projects each reminder to only those keys — the token
/// optimization for agents that only need a few fields from a large set.
func printReminderEntries(_ entries: [ReminderEntry], format: QueryFormat,
                          listNameById: [String: String] = [:],
                          fields: [String]? = nil) throws {
    switch format {
    case .json:
        if let fields, !fields.isEmpty {
            let projected = try entries.map { try projectReminder($0, fields: fields, listNameById: listNameById) }
            let data = try JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        print(String(data: data, encoding: .utf8)!)
    case .count:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(countBreakdown(entries))
        print(String(data: data, encoding: .utf8)!)
    case .plain:
        for r in entries {
            let status = r.completed ? "x" : " "
            let list = listNameById[r.calendarId] ?? ""
            let due = r.dueDate.map { dueDateFormatter.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            let tags = (r.tags ?? []).joined(separator: ",")
            print("[\(status)] \(r.title)\t\(list)\t\(due)\t\(tags)")
        }
    }
}

// MARK: - Field projection (--fields)

/// Decode any Encodable into JSONSerialization-compatible Foundation objects
/// (so a Codable struct can be embedded in a [String: Any] payload).
func jsonCompatible<T: Encodable>(_ value: T) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data)
}

/// Identity/state core that is ALWAYS present in every reminder JSON, even
/// under `--fields` projection. These are the fields downstream tooling relies
/// on to route and act on a reminder (complete/flag/move/query by list), so a
/// projection can never strip them — otherwise agents could silently misjudge
/// completion state (e.g. `--fields id,title` hiding `completed`).
let fixedReminderFields: Set<String> = [
    "id", "calendarId", "title", "completed", "priority",
    "allDay", "flagged", "urgent", "order", "subtaskIds",
]

/// Project a reminder to only the requested keys (unknown keys are ignored).
/// The fixed identity/state fields are ALWAYS retained (see `fixedReminderFields`);
/// `--fields` only selects which OPTIONAL fields are added on top.
/// `listTitle` / `list` are resolved from the calendars map (not stored on the
/// reminder itself), so list-aggregation queries don't need a full dump+join.
func projectReminder(_ r: ReminderEntry, fields: [String], listNameById: [String: String] = [:]) throws -> [String: Any] {
    let dict = try jsonCompatible(r) as? [String: Any] ?? [:]
    guard !fields.isEmpty else { return dict }
    var out: [String: Any] = [:]
    for f in fixedReminderFields {
        if let v = dict[f] { out[f] = v }
    }
    for f in fields where !f.isEmpty {
        if let v = dict[f] { out[f] = v }
    }
    if fields.contains("listTitle") || fields.contains("list") {
        out["listTitle"] = listNameById[r.calendarId] ?? ""
    }
    return out
}

/// Parse a `--fields` option value ("id,title,dueDate") into a key list.
func parseFieldsOption(_ value: String?) -> [String]? {
    guard let value, !value.isEmpty else { return nil }
    let names = value.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    return names.isEmpty ? nil : names
}

// MARK: - Completion scope

/// Apply the completion scope: default incomplete, `--completed` = only completed,
/// `--all` = everything. `--completed` and `--all` together are an error.
func applyCompletionScope(_ entries: [ReminderEntry], completed: Bool, all: Bool) throws -> [ReminderEntry] {
    if completed && all {
        throw ValidationError("--completed and --all are mutually exclusive")
    }
    if all { return entries }
    if completed { return entries.filter(\.completed) }
    return entries.filter { !$0.completed }
}

// MARK: - Date parsing

/// Parse a `YYYY-MM-DD` (start of day) or `YYYY-MM-DD HH:MM` due-date filter.
func parseDueDate(_ s: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm"
    if let d = f.date(from: s) { return d }
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
}

func startOfToday() -> Date {
    Calendar.current.startOfDay(for: Date())
}
