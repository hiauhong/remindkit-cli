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
            return [:]
        }
        return raw.notes
    }

    func save(_ notes: [String: String]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(RawNotes(version: 1, notes: notes))
        // Atomic write: temp file + replace, so a crash can't corrupt notes.
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}

struct RawNotes: Codable {
    let version: Int
    let notes: [String: String]
}
