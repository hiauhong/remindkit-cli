import ArgumentParser
import EventKitCore
import Foundation

func bulkConfirmationRequired(op: String, dryRun: Bool, yes: Bool) -> Bool {
    ["delete", "move"].contains(op.lowercased()) && !dryRun && !yes
}

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

    @Option(name: .long, help: "move: file into a section of the target list (must exist; use add-section first)")
    var section: String?

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

    @Option(name: .long, help: "update: add a tag (repeatable)")
    var tagAdd: [String] = []

    @Option(name: .long, help: "update: remove a tag (repeatable)")
    var tagRemove: [String] = []

    // MARK: Safety

    @Flag(name: .long, help: "Preview the selection and exit without writing")
    var dryRun: Bool = false

    @Option(name: .long, help: "Abort if more than this many reminders match (default: 50)")
    var limit: Int = 50

    @Flag(name: .long, help: "Confirm destructive ops (delete/move) — required for them")
    var yes: Bool = false

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
        // Preview is read-only. Confirmation is required only when the
        // destructive operation will actually execute.
        if bulkConfirmationRequired(op: op, dryRun: dryRun, yes: yes) {
            throw ValidationError("bulk --op \(op.lowercased()) 是破坏性写，必须显式确认：加 --yes")
        }
        if op.lowercased() == "update" && !flag && !noFlag && !urgentOp && !noUrgentOp
            && notes == nil && notesAppend == nil && tagAdd.isEmpty && tagRemove.isEmpty {
            throw ValidationError("bulk --op update 需要至少一个更新字段：--flag/--no-flag/--urgent/--no-urgent/--notes/--notes-append/--tag-add/--tag-remove")
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
        // --notes-append needs each reminder's current notes; fetch ONCE here
        // instead of N+1 full dumps inside the loop.
        var appendNotesByID: [String: String] = [:]
        if op.lowercased() == "update", let append = notesAppend {
            let current = data.reminders
            for r in current { appendNotesByID[r.id] = r.notes ?? "" }
            _ = append
        }
        var ok = 0
        var results: [[String: Any]] = []
        var failures: [[String: Any]] = []
        for r in selected {
            do {
                var item = try executeOp(op: op, reminder: r, appendNotesByID: appendNotesByID)
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
    /// where possible). Throws on failure. `appendNotesByID` pre-fetches the
    /// current notes for `--notes-append` (built once, not per item).
    private func executeOp(op: String, reminder: ReminderEntry,
                           appendNotesByID: [String: String]) throws -> [String: Any] {
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
            // EventKit fallback 禁用（同单条 delete）：公开 API 是硬删除，会
            // 绕过「最近删除」；子进程不可用时直接失败。
            let (source, result) = try writeWithReminderKit(request) {
                fail("reminderKitRequired",
                     "批量删除需要 ReminderKit 子进程（EventKit 兜底是硬删除，已禁用）。请检查子进程可用性。")
            }
            if let title = result["title"] as? String,
               let listName = result["listName"] as? String {
                appendDeletedRecord(DeletedRecord(
                    id: id, title: title, listName: listName,
                    deletedAt: Date().timeIntervalSince1970
                ))
            }
            return ["source": source]
        case "move":
            guard let to else { throw ValidationError("move 需要 --to") }
            var request: [String: Any] = ["op": "move", "id": id, "toListName": to, "author": "remindkit"]
            if let section, !section.isEmpty { request["section"] = section }
            let (source, result) = try writeWithReminderKit(request) {
                let store = RemindersAuth.requestAccessSync()
                let writer = RemindersWriter(store: store)
                guard let ek = writer.reminder(id: id) else { fail("noSuchReminder", "找不到提醒：\(id)") }
                let target = try ekResolveList(to, writer: writer)
                try writer.move(ek, to: target)
                var dict: [String: Any] = ["to": target.title]
                if let section, !section.isEmpty {
                    // EventKit 公共 API 不支持分区，标记降级让 agent 知道分区未生效
                    dict["degraded"] = true
                }
                return dict
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
            // --notes-append: reuse the once-fetched current-notes map (no
            // per-item full dump).
            if let append = notesAppend {
                let current = appendNotesByID[id] ?? ""
                let effective = current.isEmpty ? append : current + "\n" + append
                request["notes"] = effective
            }
            // --tag-add / --tag-remove: compute the tag delta per reminder
            // (tags on the reminder are fetched once in `selected`).
            if !tagAdd.isEmpty || !tagRemove.isEmpty {
                var current = reminder.tags ?? []
                let removeSet = Set(tagRemove.map { $0.lowercased() })
                current = current.filter { !removeSet.contains($0.lowercased()) }
                for t in tagAdd where !current.contains(where: { $0.lowercased() == t.lowercased() }) {
                    current.append(t)
                }
                request["tags"] = current
            }
            let (source, result) = try writeWithReminderKit(request) {
                // EventKit supports notes but not flags/urgent.
                if flag || noFlag || urgentOp || noUrgentOp || !tagAdd.isEmpty || !tagRemove.isEmpty {
                    fail("unsupportedByEventKit", "EventKit cannot write flagged/urgent/tags; ReminderKit subprocess unavailable")
                }
                let store = RemindersAuth.requestAccessSync()
                let writer = RemindersWriter(store: store)
                guard let ek = writer.reminder(id: id) else { fail("noSuchReminder", "找不到提醒：\(id)") }
                try writer.update(ek, title: nil, notes: request["notes"] as? String, due: nil, start: nil, priority: nil)
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
