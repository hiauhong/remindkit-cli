import EventKit
import Foundation

let store = EKEventStore()
let semaphore = DispatchSemaphore(value: 0)
var accessGranted = false

if #available(macOS 14.0, *) {
    Task {
        do {
            accessGranted = try await store.requestFullAccessToReminders()
            semaphore.signal()
        } catch {
            print("{\"error\": \"权限请求失败: \(error.localizedDescription)\"}")
            exit(1)
        }
    }
} else {
    store.requestAccess(to: .reminder) { granted, error in
        accessGranted = granted
        semaphore.signal()
    }
}

semaphore.wait()

guard accessGranted else {
    print("{\"error\": \"权限被拒绝\"}")
    exit(1)
}

// 1. 获取所有日历列表（无论是否有任务）
let allCalendars = store.calendars(for: .reminder)
var calendarResults: [[String: String]] = []
for cal in allCalendars {
    calendarResults.append([
        "id": cal.calendarIdentifier,
        "title": cal.title
    ])
}

// 2. 获取任务
let predicate = store.predicateForReminders(in: allCalendars)
let fetchSemaphore = DispatchSemaphore(value: 0)
var reminderResults: [[String: Any]] = []

store.fetchReminders(matching: predicate) { reminders in
    defer { fetchSemaphore.signal() }
    let validReminders = reminders ?? []
    
    for r in validReminders {
        var dict: [String: Any] = [
            "id": r.calendarItemIdentifier,
            "title": r.title ?? "",
            "calendar": r.calendar.title,
            "calendarId": r.calendar.calendarIdentifier,
            "priority": r.priority,
            "creationDate": r.creationDate?.timeIntervalSince1970 ?? 0,
            "completed": r.isCompleted,
            "completionDate": r.completionDate?.timeIntervalSince1970 ?? 0
        ]
        
        if let dueComp = r.dueDateComponents, let dueDate = dueComp.date {
            dict["dueDate"] = dueDate.timeIntervalSince1970
        }
        
        if let startComp = r.startDateComponents, let startDate = startComp.date {
            dict["startDate"] = startDate.timeIntervalSince1970
        }
        
        if let notes = r.notes, !notes.isEmpty {
            dict["notes"] = notes
        }
        
        if let alarms = r.alarms, !alarms.isEmpty {
            dict["alarms"] = alarms.map { alarm in
                return [
                    "absoluteDate": alarm.absoluteDate?.timeIntervalSince1970 ?? 0,
                    "relativeOffset": alarm.relativeOffset ?? 0
                ]
            }
        }
        
        if let recurrenceRules = r.recurrenceRules, !recurrenceRules.isEmpty {
            dict["recurrenceRules"] = recurrenceRules.map { rule in
                var ruleDict: [String: Any] = [
                    "frequency": rule.frequency.rawValue,
                    "interval": rule.interval
                ]

                if let daysOfWeek = rule.daysOfTheWeek {
                    ruleDict["daysOfTheWeek"] = daysOfWeek.map { dow in
                        return [
                            "dayOfTheWeek": dow.dayOfTheWeek.rawValue,
                            "weekNumber": dow.weekNumber
                        ]
                    }
                }

                if let daysOfMonth = rule.daysOfTheMonth {
                    ruleDict["daysOfTheMonth"] = daysOfMonth.map { $0.intValue }
                }

                if let monthsOfYear = rule.monthsOfTheYear {
                    ruleDict["monthsOfTheYear"] = monthsOfYear.map { $0.intValue }
                }

                if let weeksOfYear = rule.weeksOfTheYear {
                    ruleDict["weeksOfTheYear"] = weeksOfYear.map { $0.intValue }
                }

                if let daysOfYear = rule.daysOfTheYear {
                    ruleDict["daysOfTheYear"] = daysOfYear.map { $0.intValue }
                }

                if let setPositions = rule.setPositions {
                    ruleDict["setPositions"] = setPositions.map { $0.intValue }
                }

                ruleDict["firstDayOfTheWeek"] = rule.firstDayOfTheWeek

                if let end = rule.recurrenceEnd {
                    var endDict: [String: Any] = [:]
                    if let endDate = end.endDate {
                        endDict["endDate"] = endDate.timeIntervalSince1970
                    }
                    if end.occurrenceCount > 0 {
                        endDict["occurrenceCount"] = end.occurrenceCount
                    }
                    ruleDict["recurrenceEnd"] = endDict
                }

                return ruleDict
            }
        }

	// ⚠️ 标签说明:
	// Apple Reminders 在 macOS 26+ 的标签无法通过 EventKit 公开 API 获取
	// (EKReminder.keywords / structuredData 均不可用)
	// ReminderKit 私有框架中有 REMHashtag 类，但其 XPC 初始化较复杂
	// AppleScript 的 "tags" 属性存在，但为复杂类型无法直接读取
	// 如需支持标签，可通过 AI Chat 手动设置 tags 字段
        
        reminderResults.append(dict)
    }
    
    // 合并输出
    let finalOutput: [String: Any] = [
        "calendars": calendarResults,
        "reminders": reminderResults
    ]
    
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: finalOutput, options: .prettyPrinted)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    } catch {
        print("{\"error\": \"JSON 序列化失败\"}")
    }
}

fetchSemaphore.wait()
exit(0)
