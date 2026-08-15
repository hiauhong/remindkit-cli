import Foundation

// MARK: - Per-list user notes (sidecar metadata)

/// Apple's Reminders model has no list-description field, so per-list
/// semantic notes live in a sidecar JSON file keyed by list UUID. The
/// `note` command manages them; `list`/`count` output annotates them so an
/// agent sees each list's purpose without extra calls.
///
/// Keying by UUID means notes survive list renames. Notes for deleted lists
/// are simply skipped on output.
struct NotesStore {
    let fileURL: URL

    /// Default: `~/.local/share/remindkit/notes.json`. Override with
    /// `REMINDKIT_NOTES_FILE` (e.g. a path inside iCloud Drive to get
    /// cross-device sync for free).
    static func defaultURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["REMINDKIT_NOTES_FILE"],
           !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/remindkit/notes.json")
    }

    func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        guard let raw = try? JSONDecoder().decode(RawNotes.self, from: data) else {
            // 损坏的 JSON 不能静默返回空：否则下一次 save() 会用空数据覆盖
            // 用户原有备注。先备份损坏文件（保留恢复可能），再告警。
            backupCorruptFile(fileURL, label: "notes.json")
            return [:]
        }
        return raw.notes
    }

    func save(_ notes: [String: String]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(RawNotes(version: 1, notes: notes))
        // Atomic write: 唯一临时文件 + replace，崩溃不损坏、并发进程不冲突。
        let tmp = uniqueTempURL(for: fileURL)
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}

/// 唯一临时文件（UUID 后缀）——固定 ".tmp" 会被并发进程互相覆盖。
func uniqueTempURL(for fileURL: URL) -> URL {
    fileURL.deletingLastPathComponent()
        .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
}

/// 把损坏的 JSON 侧车文件备份为 `.corrupt-<时间戳>`，避免后续 save() 覆盖。
func backupCorruptFile(_ fileURL: URL, label: String) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else { return }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backup = fileURL.deletingLastPathComponent()
        .appendingPathComponent(".\(fileURL.lastPathComponent).corrupt-\(stamp)")
    do {
        try fm.moveItem(at: fileURL, to: backup)
        fputs("remindkit: warning: \(label) 损坏（JSON 解析失败），已备份到 \(backup.path)，将重新初始化。\n", stderr)
    } catch {
        fputs("remindkit: warning: \(label) 损坏且备份失败（\(error.localizedDescription)），不会覆盖原文件。\n", stderr)
    }
}

struct RawNotes: Codable {
    let version: Int
    let notes: [String: String]
}
