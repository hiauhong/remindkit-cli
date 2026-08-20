import EventKit
import Foundation

/// EventKit write path (public API, safe). Create/complete/delete/move
/// reminders. Note: tags, urgent, subtasks are NOT writable via EventKit —
/// those live only in the private ReminderKit layer.
public struct RemindersWriter {
    public let store: EKEventStore

    public init(store: EKEventStore) {
        self.store = store
    }

    /// Resolve calendars by a name-or-ID token, strictly:
    ///   1. full calendarIdentifier
    ///   2. UUID prefix (≥ 8 chars — the short form when copy-pasting)
    ///   3. case-insensitive exact title
    /// Substring title matching is deliberately NOT performed: `工作` must never
    /// resolve to `工作备份` / `财务` to `财务选题` on the write path.
    /// Returns every match (duplicate titles yield multiple) so callers can
    /// fail with `ambiguousList` instead of picking an arbitrary one.
    public func resolveCalendars(namedOrID: String) -> [EKCalendar] {
        let calendars = store.calendars(for: .reminder)
        let indices = Self.matchCalendars(
            identifiers: calendars.map(\.calendarIdentifier),
            titles: calendars.map(\.title),
            token: namedOrID
        )
        return indices.map { calendars[$0] }
    }

    /// Pure matching logic behind `resolveCalendars` (kept separate so the
    /// security-relevant precedence is unit-testable without an event store):
    /// full ID → UUID prefix (≥8) → case-insensitive exact title, never
    /// substring. Returns matching indices into the parallel arrays.
    public static func matchCalendars(identifiers: [String], titles: [String], token: String) -> [Int] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()

        // 1. Full ID.
        let exactID = identifiers.indices.filter { identifiers[$0] == trimmed }
        if !exactID.isEmpty { return exactID }

        // 2. UUID prefix (short form).
        if lower.count >= 8 {
            let prefix = identifiers.indices.filter { identifiers[$0].lowercased().hasPrefix(lower) }
            if !prefix.isEmpty { return prefix }
        }

        // 3. Exact title, case-insensitive (duplicates all returned).
        return titles.indices.filter { titles[$0].caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Resolve a calendar strictly (see `resolveCalendars`); returns the first
    /// match or nil. Prefer `resolveCalendars` when ambiguity must be detected.
    public func calendar(namedOrID: String) -> EKCalendar? {
        resolveCalendars(namedOrID: namedOrID).first
    }

    public func reminder(id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    @discardableResult
    public func add(
        title: String,
        to calendar: EKCalendar,
        notes: String? = nil,
        due: DateComponents? = nil,
        start: DateComponents? = nil,
        priority: Int = 0,
        recurrence: EKRecurrenceRule? = nil
    ) throws -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let notes, !notes.isEmpty {
            reminder.notes = notes
        }
        if let due {
            reminder.dueDateComponents = due
        }
        if let start {
            reminder.startDateComponents = start
        }
        reminder.priority = priority
        if let recurrence {
            reminder.recurrenceRules = [recurrence]
        }
        try store.save(reminder, commit: true)
        return reminder
    }

    public func setCompleted(_ reminder: EKReminder, completed: Bool) throws {
        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil
        try store.save(reminder, commit: true)
    }

    /// Update core fields on an existing reminder. A non-nil recurrenceRules
    /// value replaces the entire rule array; an empty array clears recurrence.
    /// tags/flag/urgent remain unavailable through EventKit.
    public func update(_ reminder: EKReminder, title: String?, notes: String?,
                       due: DateComponents?, start: DateComponents?,
                       priority: Int?, recurrenceRules: [EKRecurrenceRule]? = nil) throws {
        if let title { reminder.title = title }
        if let notes { reminder.notes = notes }
        if let due { reminder.dueDateComponents = due }
        if let start { reminder.startDateComponents = start }
        if let priority { reminder.priority = priority }
        if let recurrenceRules { reminder.recurrenceRules = recurrenceRules }
        try store.save(reminder, commit: true)
    }

    public func delete(_ reminder: EKReminder) throws {
        try store.remove(reminder, commit: true)
    }

    public func move(_ reminder: EKReminder, to calendar: EKCalendar) throws {
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
    }

    /// Create a new reminder list (calendar).
    @discardableResult
    public func createList(named title: String) throws -> EKCalendar {
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title
        calendar.source = store.defaultCalendarForNewReminders()?.source ?? store.defaultCalendarForNewEvents?.source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }
}
