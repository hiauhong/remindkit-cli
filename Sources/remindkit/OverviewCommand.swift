import ArgumentParser
import EventKitCore
import Foundation

struct Overview: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overview",
        abstract: "One-call summary: today, overdue, upcoming, flagged focus, urgent — the agent's default 'what should I look at'"
    )

    @Option(name: .long, help: "Upcoming window in days from today (default: 7)")
    var within: Int = 7

    @Option(name: .long, help: "Output format: json, plain")
    var format: QueryFormat = .auto()

    func run() throws {
        let data = fetchEnrichedData(includeSections: false)
        let titlesById = calendarTitles(from: data.calendars)
        let today = startOfToday()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let windowEnd = Calendar.current.date(byAdding: .day, value: within + 1, to: today)!

        let incomplete = data.reminders.filter { !$0.completed }

        let todayItems = incomplete.filter {
            guard let due = $0.dueDate else { return false }
            let d = Date(timeIntervalSince1970: due)
            return d >= today && d < tomorrow
        }
        let overdueItems = incomplete.filter {
            guard let due = $0.dueDate else { return false }
            return Date(timeIntervalSince1970: due) < today
        }
        let upcomingItems = incomplete.filter {
            guard let due = $0.dueDate else { return false }
            let d = Date(timeIntervalSince1970: due)
            return d >= tomorrow && d < windowEnd
        }
        let flaggedItems = incomplete.filter(\.flagged)
        let urgentItems = incomplete.filter(\.urgent)

        let byDue: (ReminderEntry) -> Double = { $0.dueDate ?? .greatestFiniteMagnitude }
        let items = { (entries: [ReminderEntry]) in
            entries.sorted { byDue($0) < byDue($1) }.map {
                OverviewItem(id: $0.id, title: $0.title, list: titlesById[$0.calendarId],
                             dueDate: $0.dueDate, flagged: $0.flagged, urgent: $0.urgent,
                             section: $0.section)
            }
        }

        switch format {
        case .json:
            let result = OverviewResult(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                summary: countBreakdown(data.reminders),
                today: items(todayItems),
                overdue: items(overdueItems),
                upcoming: items(upcomingItems),
                flagged: items(flaggedItems),
                urgent: items(urgentItems),
                conventionsConfigured: ConventionsStore(fileURL: ConventionsStore.defaultURL()).load() != nil,
                notesCount: NotesStore(fileURL: NotesStore.defaultURL()).load().count
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(data: try encoder.encode(result), encoding: .utf8)!)
        case .plain, .count:
            let dateOf = { (ts: Double?) -> String in
                ts.map { dueDateFormatter.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            }
            print("📊 未完成 \(incomplete.count) / 共 \(data.reminders.count) 条")
            print("⏰ 今天到期 (\(todayItems.count)):")
            for r in todayItems.sorted(by: { byDue($0) < byDue($1) }) {
                print("   [\(r.title)] \(titlesById[r.calendarId] ?? "")\t\(dateOf(r.dueDate))\(r.flagged ? " 🚩" : "")\(r.urgent ? " ⚡" : "")")
            }
            print("🔴 已过期 (\(overdueItems.count)):")
            for r in overdueItems.sorted(by: { byDue($0) < byDue($1) }) {
                print("   [\(r.title)] \(titlesById[r.calendarId] ?? "")\t\(dateOf(r.dueDate))\(r.flagged ? " 🚩" : "")\(r.urgent ? " ⚡" : "")")
            }
            print("📅 未来 \(within) 天 (\(upcomingItems.count)):")
            for r in upcomingItems.sorted(by: { byDue($0) < byDue($1) }) {
                print("   [\(r.title)] \(titlesById[r.calendarId] ?? "")\t\(dateOf(r.dueDate))\(r.flagged ? " 🚩" : "")\(r.urgent ? " ⚡" : "")")
            }
            print("🚩 旗标焦点 (\(flaggedItems.count)): \(flaggedItems.map(\.title).joined(separator: "、"))")
            print("⚡ 紧急 (\(urgentItems.count)): \(urgentItems.map(\.title).joined(separator: "、"))")
        }
    }
}

/// Slim view of a reminder for overview — enough for an agent to triage
/// without the token cost of full fields.
struct OverviewItem: Codable {
    let id: String
    let title: String
    let list: String?
    let dueDate: Double?
    let flagged: Bool
    let urgent: Bool
    let section: String?
}

struct OverviewResult: Codable {
    let generatedAt: String
    let summary: CountResult
    let today: [OverviewItem]
    let overdue: [OverviewItem]
    let upcoming: [OverviewItem]
    let flagged: [OverviewItem]
    let urgent: [OverviewItem]
    let conventionsConfigured: Bool
    let notesCount: Int
}
