import ArgumentParser
import EventKitCore
import Foundation

struct Tags: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tags",
        abstract: "List all tags with reminder counts (default: incomplete only)"
    )

    @Flag(name: .long, help: "Show only completed reminders (default: incomplete)")
    var completed: Bool = false

    @Flag(name: .long, help: "Show all reminders regardless of completion")
    var all: Bool = false

    @Option(name: .long, help: "Output format: json (default) or plain")
    var format: QueryFormat = .auto()

    func validate() throws {
        if completed && all {
            throw ValidationError("--completed and --all are mutually exclusive")
        }
    }

    func run() throws {
        let data = fetchEnrichedData(includeSections: false)
        let scoped = try applyCompletionScope(data.reminders, completed: completed, all: all)

        // tag (case-insensitive) → count, preserving first-seen casing for display.
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for r in scoped {
            for t in r.tags ?? [] {
                let key = t.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = t }
            }
        }

        let rows = counts.keys.sorted().map { key in
            TagCount(tag: display[key] ?? key, count: counts[key] ?? 0)
        }

        switch format {
        case .json, .count:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = TagsResult(total: rows.reduce(0) { $0 + $1.count }, tags: rows)
            print(String(data: try encoder.encode(payload), encoding: .utf8)!)
        case .plain:
            if rows.isEmpty {
                print("(无标签)")
                return
            }
            let maxW = rows.map(\.tag.count).max() ?? 0
            for row in rows {
                print("\(row.tag.padding(toLength: maxW + 1, withPad: " ", startingAt: 0)) \(row.count)")
            }
        }
    }
}

struct TagsResult: Codable {
    let total: Int
    let tags: [TagCount]
}

struct TagCount: Codable {
    let tag: String
    let count: Int
}
