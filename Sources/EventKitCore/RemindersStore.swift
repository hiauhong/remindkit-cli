import EventKit
import Foundation

public struct RemindersStore {
    public let store: EKEventStore

    public init(store: EKEventStore) {
        self.store = store
    }

    public func fetchAllCalendars() -> [EventKitCalendar] {
        store.calendars(for: .reminder).map {
            EventKitCalendar(id: $0.calendarIdentifier, title: $0.title)
        }
    }

    public func fetchAllReminders(in calendars: [EKCalendar]) async -> [EventKitReminder] {
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { ekReminders in
                let reminders = (ekReminders ?? []).map { EventKitReminder(from: $0) }
                continuation.resume(returning: reminders)
            }
        }
    }

    public func fetchAll() async -> EventKitRaw {
        let calendars = fetchAllCalendars()
        let ekCalendars = store.calendars(for: .reminder)
        let reminders = await fetchAllReminders(in: ekCalendars)
        return EventKitRaw(calendars: calendars, reminders: reminders)
    }
}
