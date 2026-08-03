import Foundation

// MARK: - Unified Output Schema

struct RemindKitOutput: Codable {
    let version: Int
    let exportedAt: String
    let source: DataSource
    let calendars: [CalendarEntry]
    let reminders: [ReminderEntry]
    let smartLists: [SmartListEntry]
    let listIDsOrdering: [String]
}

/// Which data source backed this export.
enum DataSource: String, Codable {
    case reminderKit
    case eventKit
}

struct CalendarEntry: Codable {
    let id: String
    let title: String
    let isGroup: Bool
    let icon: String?
    let color: String?
    let sections: [String]?
    let parentUUID: String?
    let order: Int
}

struct ReminderEntry: Codable {
    let id: String
    let calendarId: String
    let title: String
    let notes: String?
    let completed: Bool
    let priority: Int
    let creationDate: Double?
    let completionDate: Double?
    let dueDate: Double?
    let dueDateText: String?
    let startDate: Double?
    let allDay: Bool
    let timeZone: String?
    let recurrenceRules: String?
    let tags: [String]?
    let flagged: Bool
    let urgent: Bool
    let url: String?
    let alarms: [ReminderAlarm]?
    let order: Int
    let section: String?
    let parentId: String?
    let subtaskIds: [String]
}

/// Alarm on a reminder (提前提醒 / 位置提醒).
struct ReminderAlarm: Codable {
    let type: String        // date | interval | dueDateDelta | location
    let date: Double?
    let interval: Double?
    let delta: Double?
    let proximity: Int?
    let location: AlarmLocation?
}

struct AlarmLocation: Codable {
    let title: String?
    let latitude: Double?
    let longitude: Double?
}

struct SmartListEntry: Codable {
    let uuid: String
    let name: String?
    let type: String?
    let filterData: String?
    let icon: String?
    let color: String?
    let sortingStyle: String?
}

// MARK: - Raw types from ObjC subprocess

struct ReminderKitRaw: Codable {
    let smartLists: [SmartListRaw]?
    let listIDsOrdering: [String]?
    let lists: [ListRaw]?
    let reminders: [ReminderRaw]?
}

struct SmartListRaw: Codable {
    let name: String?
    let uuid: String?
    let type: String?
    let sortingStyle: String?
    let filterData: String?
    let icon: String?
    let color: String?
}

struct ListRaw: Codable {
    let uuid: String?
    let name: String?
    let isGroup: Bool?
    let icon: String?
    let color: String?
    let group: String?
    let sections: [String]?
    let parentUUID: String?
}

/// Complete reminder record emitted by the ReminderKit subprocess.
/// Core fields (dates/notes/priority/…) come from the private framework now,
/// so the subprocess is a self-contained data source.
struct ReminderRaw: Codable {
    let externalIdentifier: String?
    let listID: String?
    let title: String?
    let notes: String?
    let priority: Int?
    let completed: Bool?
    let creationDate: Double?
    let completionDate: Double?
    let dueDate: Double?
    let startDate: Double?
    let allDay: Bool?
    let timeZone: String?
    let recurrenceRules: String?
    let order: Int?
    let section: String?
    let flagged: Bool?
    let urgent: Bool?
    let url: String?
    let alarms: [ReminderAlarm]?
    let parentId: String?
    let tags: [String]?
}
