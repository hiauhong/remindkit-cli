import ArgumentParser
import Foundation

struct Note: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Read or write a per-list note (sidecar metadata — Apple has no list-description field)"
    )

    @Option(name: .long, help: "List name or ID (use a full UUID when the name is ambiguous)")
    var list: String?

    @Option(name: .long, help: "Set the note text for the list")
    var set: String?

    @Flag(name: .long, help: "Clear the note for the list")
    var clear: Bool = false

    @Flag(name: .long, help: "Print every list's note")
    var all: Bool = false

    func run() throws {
        let data = fetchEnrichedData(includeSections: false)
        let store = NotesStore(fileURL: NotesStore.defaultURL())
        var notes = store.load()

        if all {
            try printAllNotes(data, notes)
            return
        }

        guard let listFilter = list else {
            throw ValidationError("note requires --list <name-or-ID> (or --all)")
        }

        let matches = resolveListsOrFail(data.calendars, listFilter)
        guard matches.count == 1 else {
            let names = matches.map { "\($0.title) \($0.id)" }.joined(separator: ", ")
            fail("ambiguousList", "List '\(listFilter)' matches \(matches.count) lists: \(names). Use a full UUID to disambiguate.")
        }
        let cal = matches[0]

        if let text = set {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                notes.removeValue(forKey: cal.id)
            } else {
                notes[cal.id] = trimmed
            }
            try store.save(notes)
            print("ok: note \(trimmed.isEmpty ? "cleared" : "set") for '\(cal.title)'")
            return
        }
        if clear {
            notes.removeValue(forKey: cal.id)
            try store.save(notes)
            print("ok: note cleared for '\(cal.title)'")
            return
        }

        // Read mode.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = NoteResult(id: cal.id, title: cal.title, note: notes[cal.id])
        print(String(data: try encoder.encode(payload), encoding: .utf8)!)
    }

    private func printAllNotes(_ data: EnrichedData, _ notes: [String: String]) throws {
        let titlesById = Dictionary(uniqueKeysWithValues: data.calendars.map { ($0.id, $0.title) })
        let iconsById = Dictionary(uniqueKeysWithValues: data.calendars.map { ($0.id, $0.icon) })
        var rows: [NoteResult] = []
        // Preserve calendar (tree) order, skipping notes for deleted lists.
        for cal in data.calendars where !cal.isGroup {
            if let note = notes[cal.id] {
                rows.append(NoteResult(id: cal.id, title: cal.title, note: note,
                                       icon: cal.icon, parentTitle: cal.parentUUID.flatMap { titlesById[$0] }))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(rows), encoding: .utf8)!)
        if rows.isEmpty {
            fputs("remindkit: note: no notes set yet — use `note --list <列表> --set \"用途说明\"`\n", stderr)
        }
    }
}

struct NoteResult: Codable {
    let id: String
    let title: String
    let note: String?
    let icon: String?
    let parentTitle: String?

    init(id: String, title: String, note: String?, icon: String? = nil, parentTitle: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.icon = icon
        self.parentTitle = parentTitle
    }
}
