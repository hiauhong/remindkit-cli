import ArgumentParser
import Foundation

// MARK: - reorder

/// Reorder a reminder within its list by moving it relative to a sibling
/// (--before / --after) or to the list's top/bottom (--first / --last).
/// Backed by REMListChangeItem insertReminderChangeItem:before/after: —
/// explored and verified on a smoke list (works for un-sectioned tasks,
/// tasks inside sections, and non-manual sortingStyle; ordering persists).
struct Reorder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reorder",
        abstract: "Reorder a reminder within its list — move before/after a sibling, or to the top/bottom"
    )

    @Argument(help: "Reminder ID to move")
    var id: String

    @Option(name: .long, help: "Move before this sibling reminder ID (must be in the same list)")
    var before: String?

    @Option(name: .long, help: "Move after this sibling reminder ID (must be in the same list)")
    var after: String?

    @Flag(name: .long, help: "Move to the top of the list")
    var first: Bool = false

    @Flag(name: .long, help: "Move to the bottom of the list")
    var last: Bool = false

    func validate() throws {
        let modes = (before != nil ? 1 : 0) + (after != nil ? 1 : 0) + (first ? 1 : 0) + (last ? 1 : 0)
        guard modes == 1 else {
            throw ValidationError("需要且仅需一个定位参数：--before <sibling> / --after <sibling> / --first / --last")
        }
        if let before, before == id {
            throw ValidationError("--before 不能引用目标任务自身（顺序不会变）")
        }
        if let after, after == id {
            throw ValidationError("--after 不能引用目标任务自身（顺序不会变）")
        }
    }

    func run() throws {
        guardWriteEnabled()
        var request: [String: Any] = ["op": "reorder", "id": id, "author": "remindkit"]
        if let before { request["before"] = before }
        if let after { request["after"] = after }
        if first { request["first"] = true }
        if last { request["last"] = true }

        let (source, result) = try writeWithReminderKit(request) {
            fail("unsupportedByEventKit", "任务排序需要 ReminderKit 子进程（EventKit 不支持列表内排序）")
        }
        var out: [String: Any] = ["ok": true, "source": source]
        for (k, v) in result where k != "ok" { out[k] = v }
        try jsonOut(out)
    }
}
