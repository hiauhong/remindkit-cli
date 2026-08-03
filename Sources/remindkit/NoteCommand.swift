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

        // 普通列表/分组 → 智能列表（系统+自定义）逐级匹配：
        // calendars 无匹配时回退到 smartLists，这样「旗标/今天」等特殊列表也能读写备注。
        let calMatches = (try? resolveListFilter(data.calendars, listFilter)) ?? []
        let smartMatches = calMatches.isEmpty ? resolveSmartListFilter(data.smartLists, listFilter) : []
        let total = calMatches.count + smartMatches.count
        guard total == 1 else {
            if total == 0 {
                fail("noSuchList", "No list matches '\(listFilter)' (searched lists/groups and smart lists)")
            }
            let names = (calMatches.map { "\($0.title) \($0.id)" } + smartMatches.map { "\($0.name ?? "") \($0.uuid)" })
                .joined(separator: ", ")
            fail("ambiguousList", "List '\(listFilter)' matches \(total) lists: \(names). Use a full UUID to disambiguate.")
        }

        let target: (id: String, title: String) =
            calMatches.count == 1
                ? (calMatches[0].id, calMatches[0].title)
                : (smartMatches[0].uuid, smartMatches[0].name ?? smartMatches[0].type ?? "smartList")

        if let text = set {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                notes.removeValue(forKey: target.id)
            } else {
                notes[target.id] = trimmed
            }
            try store.save(notes)
            print("ok: note \(trimmed.isEmpty ? "cleared" : "set") for '\(target.title)'")
            return
        }
        if clear {
            notes.removeValue(forKey: target.id)
            try store.save(notes)
            print("ok: note cleared for '\(target.title)'")
            return
        }

        // Read mode.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = NoteResult(id: target.id, title: target.title, note: notes[target.id])
        print(String(data: try encoder.encode(payload), encoding: .utf8)!)
    }

    private func printAllNotes(_ data: EnrichedData, _ notes: [String: String]) throws {
        let titlesById = Dictionary(uniqueKeysWithValues: data.calendars.map { ($0.id, $0.title) })
        var rows: [NoteResult] = []
        // Preserve calendar (tree) order, skipping notes for deleted lists.
        // 分组（文件夹）备注也输出（isGroup 标识），与 list 树形一致。
        for cal in data.calendars {
            if let note = notes[cal.id] {
                rows.append(NoteResult(id: cal.id, title: cal.title, note: note,
                                       icon: cal.icon, isGroup: cal.isGroup,
                                       parentTitle: cal.parentUUID.flatMap { titlesById[$0] }))
            }
        }
        // 智能列表（系统+自定义）备注：isSmartList 标识 + type（custom 或系统类型全名）。
        for sl in data.smartLists {
            if let note = notes[sl.uuid] {
                rows.append(NoteResult(id: sl.uuid, title: sl.name ?? sl.type ?? "smartList",
                                       note: note, icon: sl.icon, isSmartList: true, smartListType: sl.type))
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
    let isGroup: Bool?
    let isSmartList: Bool?
    let smartListType: String?
    let parentTitle: String?

    init(id: String, title: String, note: String?, icon: String? = nil, isGroup: Bool? = nil,
         isSmartList: Bool? = nil, smartListType: String? = nil, parentTitle: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.icon = icon
        self.isGroup = isGroup
        self.isSmartList = isSmartList
        self.smartListType = smartListType
        self.parentTitle = parentTitle
    }
}
