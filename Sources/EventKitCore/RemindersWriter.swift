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

    /// Resolve a calendar by exact ID first, then by case-insensitive name match.
    public func calendar(namedOrID: String) -> EKCalendar? {
        let calendars = store.calendars(for: .reminder)
        return calendars.first { $0.calendarIdentifier == namedOrID }
            ?? calendars.first { $0.title.localizedCaseInsensitiveContains(namedOrID) }
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

    /// Update core fields on an existing reminder. tags/repeat/flag/urgent
    /// are NOT writable via EventKit — callers mark those as degraded.
    public func update(_ reminder: EKReminder, title: String?, notes: String?,
                       due: DateComponents?, start: DateComponents?,
                       priority: Int?) throws {
        if let title { reminder.title = title }
        if let notes { reminder.notes = notes }
        if let due { reminder.dueDateComponents = due }
        if let start { reminder.startDateComponents = start }
        if let priority { reminder.priority = priority }
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
