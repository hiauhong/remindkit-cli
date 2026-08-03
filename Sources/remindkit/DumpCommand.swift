import ArgumentParser
import EventKitCore
import Foundation

struct Dump: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Export all Apple Reminders data as unified JSON"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Option(name: .long, help: "Output format: json, plain, count")
    var format: OutputFormat = .json

    @Option(name: .long, help: "Only output these reminder fields (comma-separated): id,title,dueDate,completed,…")
    var fields: String?

    @Flag(name: .long, help: "Also include system smart lists (今天/旗标/已完成/已分配) — virtual views whose items live in regular lists; excluded by default")
    var systemSmartlists: Bool = false

    func run() throws {
        let data = fetchEnrichedData()

        // 系统智能列表（今天/旗标/已完成/已分配）是虚拟视图，事项都引用自普通列表，
        // 默认不输出；自定义智能列表（type: custom）始终保留。
        let smartLists = systemSmartlists ? data.smartLists
            : data.smartLists.filter { !isSystemSmartList($0) }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // --fields: project reminders only (calendars/smartLists stay intact).
        if let names = parseFieldsOption(fields) {
            let reminders = try data.reminders.map { try projectReminder($0, fields: names) }
            var out: [String: Any] = [
                "version": 1,
                "exportedAt": dateFormatter.string(from: Date()),
                "source": data.source.rawValue,
                "reminders": reminders,
            ]
            out["calendars"] = try data.calendars.map { try jsonCompatible($0) }
            out["smartLists"] = try smartLists.map { try jsonCompatible($0) }
            out["listIDsOrdering"] = data.listIDsOrdering
            try jsonOut(out)
            return
        }

        let output = RemindKitOutput(
            version: 1,
            exportedAt: dateFormatter.string(from: Date()),
            source: data.source,
            calendars: data.calendars,
            reminders: data.reminders,
            smartLists: smartLists,
            listIDsOrdering: data.listIDsOrdering
        )

        switch format {
        case .json:
            let encoder = JSONEncoder()
            if pretty {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            }
            let jsonData = try encoder.encode(output)
            print(String(data: jsonData, encoding: .utf8)!)
        case .plain:
            printPlain(output)
        case .count:
            printCount(output)
        }
    }
}

// MARK: - Helpers

/// 系统智能列表（今天/旗标/已完成/已分配）是虚拟视图，事项都引用自普通列表，
/// dump 默认不输出；自定义智能列表（type: custom）始终输出。
private func isSystemSmartList(_ sl: SmartListEntry) -> Bool {
    guard let type = sl.type else { return false }
    return type.hasPrefix("com.apple.reminders.smartlist.") && type != "com.apple.reminders.smartlist.custom"
}

// MARK: - Output Formats

private func printPlain(_ output: RemindKitOutput) {
    for cal in output.calendars {
        print("list\t\(cal.id)\t\(cal.title)")
    }
    for rem in output.reminders {
        let status = rem.completed ? "x" : " "
        let due = rem.dueDate.map { String($0) } ?? ""
        let tags = (rem.tags ?? []).joined(separator: ",")
        print("reminder\t\(rem.id)\t[\(status)]\t\(rem.title)\t\(due)\t\(tags)")
    }
}

private func printCount(_ output: RemindKitOutput) {
    let totalReminders = output.reminders.count
    let completedReminders = output.reminders.filter(\.completed).count
    let flaggedReminders = output.reminders.filter(\.flagged).count
    print("Calendars:\t\(output.calendars.count)")
    print("Lists:\t\(output.calendars.filter { !$0.isGroup }.count)")
    print("Groups:\t\(output.calendars.filter(\.isGroup).count)")
    print("Smart lists:\t\(output.smartLists.count)")
    print("Reminders:\t\(totalReminders)")
    print("Completed:\t\(completedReminders)")
    print("Flagged:\t\(flaggedReminders)")
}

enum OutputFormat: String, ExpressibleByArgument, Codable {
    case json
    case plain
    case count
}
