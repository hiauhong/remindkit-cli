import EventKit
import Foundation

// MARK: - Raw EventKit types

public struct EventKitRaw: Codable {
    public let calendars: [EventKitCalendar]
    public let reminders: [EventKitReminder]

    public init(calendars: [EventKitCalendar], reminders: [EventKitReminder]) {
        self.calendars = calendars
        self.reminders = reminders
    }
}

public struct EventKitCalendar: Codable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct EventKitReminder: Codable {
    public let id: String
    public let title: String
    public let calendar: String
    public let calendarId: String
    public let priority: Int
    public let creationDate: Double?
    public let completed: Bool
    public let completionDate: Double?
    public let dueDate: Double?
    public let startDate: Double?
    public let notes: String?
    public let recurrenceRules: String?

    public init(from ekReminder: EKReminder) {
        self.id = ekReminder.calendarItemIdentifier
        self.title = ekReminder.title ?? ""
        self.calendar = ekReminder.calendar.title
        self.calendarId = ekReminder.calendar.calendarIdentifier
        self.priority = ekReminder.priority
        self.creationDate = ekReminder.creationDate?.timeIntervalSince1970
        self.completed = ekReminder.isCompleted
        self.completionDate = ekReminder.completionDate?.timeIntervalSince1970
        self.dueDate = ekReminder.dueDateComponents?.date?.timeIntervalSince1970
        self.startDate = ekReminder.startDateComponents?.date?.timeIntervalSince1970
        self.notes = ekReminder.notes?.isEmpty == false ? ekReminder.notes : nil
        self.recurrenceRules = Self.encodeRecurrenceRules(ekReminder.recurrenceRules)
    }

    private static func encodeRecurrenceRules(_ rules: [EKRecurrenceRule]?) -> String? {
        guard let rules = rules, !rules.isEmpty else { return nil }
        var result: [[String: Any]] = []
        for rule in rules {
            var dict: [String: Any] = [
                "frequency": rule.frequency.rawValue,
                "interval": rule.interval,
            ]
            if let daysOfWeek = rule.daysOfTheWeek {
                dict["daysOfTheWeek"] = daysOfWeek.map { ["dayOfTheWeek": $0.dayOfTheWeek.rawValue, "weekNumber": $0.weekNumber] }
            }
            if let daysOfMonth = rule.daysOfTheMonth {
                dict["daysOfTheMonth"] = daysOfMonth.map { $0.intValue }
            }
            if let monthsOfYear = rule.monthsOfTheYear {
                dict["monthsOfTheYear"] = monthsOfYear.map { $0.intValue }
            }
            if let weeksOfYear = rule.weeksOfTheYear {
                dict["weeksOfTheYear"] = weeksOfYear.map { $0.intValue }
            }
            if let daysOfYear = rule.daysOfTheYear {
                dict["daysOfTheYear"] = daysOfYear.map { $0.intValue }
            }
            if let setPositions = rule.setPositions {
                dict["setPositions"] = setPositions.map { $0.intValue }
            }
            dict["firstDayOfTheWeek"] = rule.firstDayOfTheWeek
            if let end = rule.recurrenceEnd {
                var endDict: [String: Any] = [:]
                if let endDate = end.endDate {
                    endDict["endDate"] = endDate.timeIntervalSince1970
                }
                if end.occurrenceCount > 0 {
                    endDict["occurrenceCount"] = end.occurrenceCount
                }
                dict["recurrenceEnd"] = endDict
            }
            result.append(dict)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
