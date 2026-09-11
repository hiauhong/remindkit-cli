import Foundation

/// Locates the remindkit agent skill bundled next to the running binary.
///
/// Shared by `install-skill` (which copies it to the agent skill dirs) and
/// `remindkit --version` (which reads its `skill-version:` frontmatter — the
/// release stamp `Scripts/package.sh` writes into the same tarball, so the
/// packaged skill and the CLI can never disagree on the version).
enum SkillSource {
    /// 解析二进制真实路径。bash/脚本从 PATH 调用时 argv[0] 是裸命令名（如 `remindkit`），
    /// 直接 `URL(fileURLWithPath:)` 会被解析成 cwd 相对路径，导致 binDir 错指到 cwd——
    /// 候选源里 cwd/.agents/skills/remindkit 会撞上目标位置，--force 时先删后拷把自己删掉。
    static func binaryURL() -> URL {
        let argv0 = CommandLine.arguments[0]
        if argv0.hasPrefix("/") {
            return URL(fileURLWithPath: argv0)
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(argv0)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: argv0)
    }

    static func candidates() -> [URL] {
        // Resolve symlinks so a Homebrew-installed binary (/opt/homebrew/bin/remindkit
        // → Cellar) resolves the share/remindkit/skills path relative to the real
        // Cellar bin dir, not the /opt/homebrew/bin symlink location.
        let binary = binaryURL().resolvingSymlinksInPath()
        let binDir = binary.deletingLastPathComponent()
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        return [
            binDir.deletingLastPathComponent().appendingPathComponent(".agents/skills/remindkit"),
            binDir.appendingPathComponent(".agents/skills/remindkit"),
            binDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".agents/skills/remindkit"),
            // Homebrew: formula installs the skill to share/remindkit/skills/remindkit
            binDir.deletingLastPathComponent().appendingPathComponent("share/remindkit/skills/remindkit"),
            cwd.appendingPathComponent(".agents/skills/remindkit"),
        ]
    }

    /// First candidate directory that actually contains a SKILL.md.
    static func find() -> URL? {
        for candidate in candidates()
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("SKILL.md").path) {
            return candidate
        }
        return nil
    }
}
