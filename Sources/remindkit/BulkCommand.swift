import ArgumentParser
import EventKitCore
import Foundation

/// Bulk operations: select reminders by query conditions, then run one
/// write op on all of them. The selector reuses query's filter semantics;
/// --dry-run previews what would change; --limit caps the batch size so an
/// agent can't blow away a whole list by accident.
struct Bulk: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bulk",
        abstract: "Batch write: select reminders by conditions, then complete/delete/move/update them all"
    )

    // MARK: Operation

    @Option(name: .long, help: "Operation: complete | delete | move | update")
    var op: String

    // MARK: Selector (at least one condition required)

    @Option(name: .long, help: "Select list name or ID")
    var list: String?

    @Option(name: .long, help: "Select tag name")
    var tag: String?

    @Flag(name: .long, help: "Select only flagged reminders")
    var flagged: Bool = false

    @Flag(name: .long, help: "Select only urgent reminders")
    var urgent: Bool = false

    @Option(name: .long, help: "Select due on/after (YYYY-MM-DD [HH:MM])")
    var dueAfter: String?

    @Option(name: .long, help: "Select due before (YYYY-MM-DD [HH:MM])")
    var dueBefore: String?

    @Flag(name: .long, help: "Include completed reminders in the selection (default: incomplete only)")
    var all: Bool = false

    // MARK: Op arguments

    @Option(name: .long, help: "Target list for move (name or ID)")
    var to: String?

    @Flag(name: .long, help: "update: set the flag")
    var flag: Bool = false

    @Flag(name: .long, help: "update: clear the flag")
    var noFlag: Bool = false

    @Flag(name: .long, help: "update: mark urgent")
    var urgentOp: Bool = false

    @Flag(name: .long, help: "update: unmark urgent")
    var noUrgentOp: Bool = false

    @Option(name: .long, help: "update: set notes (replaces)")
    var notes: String?

    @Option(name: .long, help: "update: append to existing notes")
    var notesAppend: String?

    // MARK: Safety

    @Flag(name: .long, help: "Preview the selection and exit without writing")
    var dryRun: Bool = false

    @Option(name: .long, help: "Abort if more than this many reminders match (default: 50)")
    var limit: Int = 50

    func validate() throws {
        let hasSelector = list != nil || tag != nil || flagged || urgent
            || dueAfter != nil || dueBefore != nil
        guard hasSelector else {
            throw ValidationError("bulk needs at least one selector: --list/--tag/--flagged/--urgent/--due-after/--due-before")
        }
        guard ["complete", "delete", "move", "update"].contains(op.lowercased()) else {
            throw ValidationError("无效操作：\(op)。使用 complete / delete / move / update")
        }
        if op.lowercased() == "move" && to == nil {
            throw ValidationError("move 需要 --to <目标列表>")
        }
        if flag && noFlag {
            throw ValidationError("--flag and --no-flag are mutually exclusive")
        }
        if urgentOp && noUrgentOp {
            throw ValidationError("--urgent and --no-urgent are mutually exclusive")
        }
    }

    func run() throws {
        guardWriteEnabled()
        let data = fetchEnrichedData(includeSections: false)

        // Build the selection exactly like `query` does.
        var selected = data.reminders
        if let listFilter = list {
            let calIds = Set(resolveListsOrFail(data.calendars, listFilter).map(\.id))
            selected = selected.filter { calIds.contains($0.calendarId) }
        }
        if let tagFilter = tag {
            let t = tagFilter.lowercased()
            selected = selected.filter { ($0.tags ?? []).contains { $0.lowercased() == t } }
        }
        if flagged { selected = selected.filter(\.flagged) }
        if urgent { selected = selected.filter(\.urgent) }
        if let after = try parseBulkDate(dueAfter) {
            selected = selected.filter { $0.dueDate != nil && $0.dueDate! >= after }
        }
        if let before = try parseBulkDate(dueBefore) {
            selected = selected.filter { $0.dueDate != nil && $0.dueDate! < before }
        }
        if !all { selected = selected.filter { !$0.completed } }

        guard !selected.isEmpty else {
            try jsonOut(["ok": true, "op": op, "selected": 0, "dryRun": dryRun])
            return
        }
        guard selected.count <= limit else {
            fail("tooMany", "选择命中 \(selected.count) 条，超过 --limit \(limit)。加 --limit 提高上限，或用更精确的条件。")
        }

        if dryRun {
            let ids = selected.map { ["id": $0.id, "title": $0.title] }
            try jsonOut(["ok": true, "op": op, "selected": selected.count, "dryRun": true, "items": ids])
            return
        }

        // Execute per reminder, collecting per-item results.
        var ok = 0
        var results: [[String: Any]] = []
        var failures: [[String: Any]] = []
        for r in selected {
            do {
                var item = try executeOp(op: op, reminder: r)
                item["id"] = r.id
                item["title"] = r.title
                results.append(item)
                ok += 1
            } catch {
                failures.append(["id": r.id, "title": r.title, "error": error.localizedDescription])
            }
        }

        var out: [String: Any] = ["ok": true, "op": op, "selected": selected.count, "succeeded": ok, "failed": failures.count]
        if !results.isEmpty { out["results"] = results }
        if !failures.isEmpty { out["failures"] = failures }
        try jsonOut(out)
    }

    /// Run one write op on one reminder via ReminderKit (EventKit fallback
    /// where possible). Throws on failure.
    private func executeOp(op: String, reminder: ReminderEntry) throws -> [String: Any] {
        let id = reminder.id
        switch op.lowercased() {
        case "complete":
            let request: [String: Any] = ["op": "complete", "id": id, "completed": true, "author": "remindkit"]
            let (source, _) = try writeWithReminderKit(request) {
                let store = RemindersAuth.requestAccessSync()
                let writer = RemindersWriter(store: store)
                guard let ek = writer.reminder(id: id) else { fail("noSuchReminder", "找不到提醒：\(id)") }
                try writer.setCompleted(ek, completed: true)
                return ["completed": true]
            }
            return ["source": source]
        case "delete":
            let request: [String: Any] = ["op": "delete", "id": id, "author": "remindkit"]
            let (source, _) = try writeWithReminderKit(request) {
                let store = RemindersAuth.requestAccessSync()
                let writer = RemindersWriter(store: store)
                guard let ek = writer.reminder(id: id) else { fail("noSuchReminder", "找不到提醒：\(id)") }
                try writer.delete(ek)
                return ["deleted": true]
            }
            return ["source": source]
        case "move":
            guard let to else { throw ValidationError("move 需要 --to") }
            let request: [String: Any] = ["op": "move", "id": id, "toListName": to, "author": "remindkit"]
            let (source, result) = try writeWithReminderKit(request) {
                let store = RemindersAuth.requestAccessSync()
                let writer = RemindersWriter(store: store)
                guard let ek = writer.reminder(id: id) else { fail("noSuchReminder", "找不到提醒：\(id)") }
                let target = try ekResolveList(to, writer: writer)
                try writer.move(ek, to: target)
                return ["to": target.title]
            }
            var dict: [String: Any] = ["source": source]
            // move preserves the reminder's identifier (true re-parent via
            // addReminderChangeItem: — no copy/delete, no new ID). Surface it
            // so callers can keep tracking the moved reminder.
            if let movedFromId = result["movedFromId"], let newId = result["id"] {
                // compat: a stale subprocess binary still reports copy+delete
                dict["movedFromId"] = movedFromId
                dict["newID"] = newId
            } else {
                dict["newID"] = id
            }
            return dict
        case "update":
            var request: [String: Any] = ["op": "update", "id": id, "author": "remindkit"]
            if flag { request["flagged"] = true }
            if noFlag { request["flagged"] = false }
            if urgentOp { request["urgent"] = true }
            if noUrgentOp { request["urgent"] = false }
            if let notes { request["notes"] = notes }
            // --notes-append: read current notes and append (per reminder, since
            // notes differ per item — reuse the read-side fetch).
            var effectiveNotes = notes
            if let append = notesAppend {
                let data = fetchEnrichedData(includeSections: false)
                let current = data.reminders.first { $0.id == id }?.notes ?? ""
                effectiveNotes = current.isEmpty ? append : current + "\n" + append
                request["notes"] = effectiveNotes
            }
            let (source, result) = try writeWithReminderKit(request) {
                // EventKit supports notes but not flags/urgent.
                if flag || noFlag || urgentOp || noUrgentOp {
                    fail("unsupportedByEventKit", "EventKit cannot write flagged/urgent; ReminderKit subprocess unavailable")
                }
                let store = RemindersAuth.requestAccessSync()
                let writer = RemindersWriter(store: store)
                guard let ek = writer.reminder(id: id) else { fail("noSuchReminder", "找不到提醒：\(id)") }
                try writer.update(ek, title: nil, notes: effectiveNotes, due: nil, start: nil, priority: nil)
                return ["updated": true]
            }
            var dict: [String: Any] = ["source": source]
            if let changes = result["changes"] { dict["changes"] = changes }
            return dict
        default:
            throw ValidationError("无效操作：\(op)")
        }
    }

    private func parseBulkDate(_ value: String?) throws -> TimeInterval? {
        guard let value else { return nil }
        guard let d = parseDueDate(value) else {
            throw ValidationError("无效日期：\(value)。使用 YYYY-MM-DD 或 YYYY-MM-DD HH:MM")
        }
        return d.timeIntervalSince1970
    }
}
