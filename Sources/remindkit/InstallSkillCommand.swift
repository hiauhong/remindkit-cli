import ArgumentParser
import Foundation

struct InstallSkill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-skill",
        abstract: "Install the remindkit agent skill to Claude Code / agents skill directories"
    )

    @Flag(name: .long, help: "Install to Claude Code skills (~/.claude/skills)")
    var claude: Bool = false

    @Flag(name: .long, help: "Install to agents skills (~/.agents/skills)")
    var agents: Bool = false

    @Flag(name: .long, help: "Overwrite existing skill")
    var force: Bool = false

    func run() throws {
        let installClaude = claude || !agents
        let installAgents = agents || !claude

        guard let sourceDir = findSkillSource() else {
            throw ValidationError("Could not find skill directory relative to binary at \(CommandLine.arguments[0]). Searched: \(skillSourceCandidates().map(\.path).joined(separator: ", "))")
        }

        let home = NSHomeDirectory()
        var installed: [String] = []
        let failures = try install(
            source: sourceDir,
            targets: installClaude ? [home + "/.claude/skills/remindkit"] : [],
            force: force,
            installed: &installed
        ) + install(
            source: sourceDir,
            targets: installAgents ? [home + "/.agents/skills/remindkit"] : [],
            force: force,
            installed: &installed
        )

        if failures.isEmpty {
            print("Installed remindkit skill.")
            for path in installed { print("  \(path)") }
        } else {
            for message in failures {
                fputs("error: \(message)\n", stderr)
            }
            throw ExitCode.failure
        }
    }

    // MARK: - Skill discovery

    /// 解析二进制真实路径。bash/脚本从 PATH 调用时 argv[0] 是裸命令名（如 `remindkit`），
    /// 直接 `URL(fileURLWithPath:)` 会被解析成 cwd 相对路径，导致 binDir 错指到 cwd——
    /// 候选源里 cwd/.agents/skills/remindkit 会撞上目标位置，--force 时先删后拷把自己删掉。
    private func binaryURL() -> URL {
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

    private func findSkillSource() -> URL? {
        for candidate in skillSourceCandidates()
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("SKILL.md").path) {
            return candidate
        }
        return nil
    }

    private func skillSourceCandidates() -> [URL] {
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

    // MARK: - Install

    private func install(source: URL, targets: [String], force: Bool, installed: inout [String]) throws -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for target in targets {
            let dest = URL(fileURLWithPath: target)
            // Guard: if the discovered source IS the target (e.g. the cwd candidate
            // resolved to the already-installed skill directory), there is nothing
            // to copy — skipping also avoids deleting our own source with --force.
            if source.resolvingSymlinksInPath().path == dest.resolvingSymlinksInPath().path {
                installed.append(dest.path)
                continue
            }
            // 删除目标前先确认源存在，避免破坏性操作后无源可拷。
            if !fm.fileExists(atPath: source.path) {
                failures.append("skill source missing at \(source.path)")
                continue
            }
            if fm.fileExists(atPath: dest.path) {
                if !force {
                    failures.append("\(target) already exists (use --force to overwrite)")
                    continue
                }
                do {
                    try fm.removeItem(at: dest)
                } catch {
                    failures.append("failed to remove existing \(target): \(error.localizedDescription)")
                    continue
                }
            }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: dest)
                installed.append(dest.path)
            } catch {
                failures.append("failed to install to \(target): \(error.localizedDescription)")
            }
        }
        return failures
    }

    // MARK: - Auto-sync on run

    /// 每次运行自动同步 agent skill（幂等）：`~/.agents/skills/remindkit` 缺失时
    /// 安装；已存在但内容与源不一致时覆盖更新（brew upgrade 后 skill 随版本自动同步，
    /// agent 无需手动 install-skill --force）。内容一致时零开销跳过。
    /// 关闭：环境变量 `REMINDKIT_NO_AUTO_SKILL=1`。失败静默（不阻塞主命令）。
    /// 返回提示文本（nil = 已同步/无需提示/安装失败）。
    static func autoInstallIfMissing() -> String? {
        guard ProcessInfo.processInfo.environment["REMINDKIT_NO_AUTO_SKILL"] != "1" else { return nil }
        let home = NSHomeDirectory()
        let dest = URL(fileURLWithPath: home).appendingPathComponent(".agents/skills/remindkit")
        let destSkill = dest.appendingPathComponent("SKILL.md")
        let fm = FileManager.default
        let cmd = InstallSkill()
        guard let source = cmd.findSkillSource() else { return nil }
        if source.resolvingSymlinksInPath().path == dest.resolvingSymlinksInPath().path { return nil }
        let sourceSkill = source.appendingPathComponent("SKILL.md")

        // 已安装且内容一致 → 无需任何操作。
        if fm.fileExists(atPath: destSkill.path),
           let srcData = try? Data(contentsOf: sourceSkill),
           let dstData = try? Data(contentsOf: destSkill),
           srcData == dstData {
            return nil
        }

        // 缺失 → 安装；存在但内容不一致 → 覆盖更新（skill 是发行契约，随版本同步）。
        let wasInstalled = fm.fileExists(atPath: destSkill.path)
        var installed: [String] = []
        var failures: [String] = []
        failures += (try? cmd.install(source: source, targets: [dest.path], force: wasInstalled,
                                      installed: &installed)) ?? ["auto install failed"]
        guard failures.isEmpty, !installed.isEmpty else { return nil }
        if wasInstalled {
            return "已自动更新 remindkit agent skill（内容已同步到当前版本；若你手动改过可用 REMINDKIT_NO_AUTO_SKILL=1 关闭）"
        }
        return "已自动安装 remindkit agent skill 到 \(dest.path)（agent 新会话生效；REMINDKIT_NO_AUTO_SKILL=1 关闭）"
    }
}

