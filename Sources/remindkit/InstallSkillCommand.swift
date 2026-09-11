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

        guard let sourceDir = SkillSource.find() else {
            throw ValidationError("Could not find skill directory relative to binary at \(CommandLine.arguments[0]). Searched: \(SkillSource.candidates().map(\.path).joined(separator: ", "))")
        }

        let home = InstallSkill.effectiveHome
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

    /// 用户/宿主 home 目录。优先读 `$HOME`（隔离测试/沙盒宿主会设置），否则回退到系统
    /// `NSHomeDirectory()`——macOS 上后者不读 `$HOME`，会造成测试/沙盒无法隔离 skill 安装。
    static var effectiveHome: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
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

    // MARK: - Skill version (frontmatter `skill-version:`)

    /// SKILL.md frontmatter 里的 `skill-version:`，语义化版本比较（预发布版低于同号正式版）。
    /// 仓库工作区带 `-dev`（高于上一个发行版、低于同号发行版）：手工同步的 dev 副本能
    /// 活过同号发行版的自动同步，又被下一个正式版正常接管。
    struct SkillVersion: Comparable {
        let major: Int, minor: Int, patch: Int
        let prerelease: String?

        /// 还原成 frontmatter 里的版本串（`+build` 元数据不参与比较，故不回显）。
        var versionString: String {
            prerelease.map { "\(major).\(minor).\(patch)-\($0)" } ?? "\(major).\(minor).\(patch)"
        }

        static func parse(_ text: String) -> SkillVersion? {
            // 兼容 UTF-8 BOM 与 `---` 行的前导空白（不同编辑器/手工编辑可能产生）。
            let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            var lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)[...]
            guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
            lines = lines.dropFirst()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" { break }
                guard trimmed.hasPrefix("skill-version:") else { continue }
                let value = trimmed.dropFirst("skill-version:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return nil }
                // 语义化版本 X.Y.Z[-prerelease][+build]，手工解析（避免依赖 Regex 字面量的工具链要求）。
                // build 元数据（+…）不参与比较，先剥掉；prerelease（-…）保留给比较器。
                var core = value
                var prerelease: String? = nil
                if let plusIdx = value.firstIndex(of: "+") {
                    core = String(value[..<plusIdx])
                }
                if let dashIdx = core.firstIndex(of: "-") {
                    let pre = String(core[core.index(after: dashIdx)...])
                    core = String(core[..<dashIdx])
                    prerelease = pre.isEmpty ? nil : pre
                }
                let numbers = core.split(separator: ".").map { Int($0) }
                guard numbers.count == 3, numbers.allSatisfy({ $0 != nil }) else { return nil }
                return SkillVersion(
                    major: numbers[0]!, minor: numbers[1]!, patch: numbers[2]!,
                    prerelease: prerelease
                )
            }
            return nil
        }

        static func < (lhs: SkillVersion, rhs: SkillVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil): return false
            case (nil, _?): return false   // 正式版 > 预发布版
            case (_?, nil): return true
            case let (a?, b?): return comparePrerelease(a, b) < 0
            }
        }

        /// 预发布标识比较：返回 -1 / 0 / 1。按语义化版本规则逐段比较，非字典序——
        /// 纯数字段按数值、字母段按字典序，数字段 < 字母段，前段全相等时段数少者更低。
        private static func comparePrerelease(_ lhs: String, _ rhs: String) -> Int {
            let a = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let b = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let count = min(a.count, b.count)
            for i in 0..<count {
                let x = a[i], y = b[i]
                if let xn = Int(x), let yn = Int(y) {
                    if xn != yn { return xn < yn ? -1 : 1 }
                } else if Int(x) != nil {
                    return -1                       // 数字段 < 字母段
                } else if Int(y) != nil {
                    return 1                        // 字母段 > 数字段
                } else if x != y {
                    return x < y ? -1 : 1
                }
            }
            if a.count != b.count { return a.count < b.count ? -1 : 1 }
            return 0
        }

        var description: String {
            prerelease.map { "\(major).\(minor).\(patch)-\($0)" } ?? "\(major).\(minor).\(patch)"
        }
    }

    /// 内容不一致时的同步决策。两端都有可解析版本且安装版更新 → 保留（可能是手工
    /// 修订）；同号不同内容 / 任一端缺版本号（旧安装）→ 以发行版为准覆盖。
    static func skillSyncDecision(sourceText: String, destText: String) -> Bool {
        // true = 覆盖，false = 保留安装版
        switch (SkillVersion.parse(sourceText), SkillVersion.parse(destText)) {
        case (let s?, let d?) where s < d: return false
        default: return true
        }
    }

    // MARK: - Auto-sync on run

    /// 单一 skill 目录的同步核心，可注入源/目标以单测（不依赖 `NSHomeDirectory()`）。
    /// 内容相等 → 零开销跳过（no-op）；缺失 → 安装；内容不同 → 按 `skill-version:`
    /// 语义化版本比较：发行版更新则覆盖、安装版更新（手工修订）则保留并提示。
    /// 返回提示文本（nil = 无需提示/安装失败）。
    static func syncSkill(source: URL, dest: URL, using cmd: InstallSkill) -> String? {
        let destSkill = dest.appendingPathComponent("SKILL.md")
        let sourceSkill = source.appendingPathComponent("SKILL.md")
        let fm = FileManager.default
        if source.resolvingSymlinksInPath().path == dest.resolvingSymlinksInPath().path { return nil }

        // 已安装且内容一致 → 无需任何操作。
        if fm.fileExists(atPath: destSkill.path),
           let srcData = try? Data(contentsOf: sourceSkill),
           let dstData = try? Data(contentsOf: destSkill),
           srcData == dstData {
            return nil
        }

        // 缺失 → 安装；版本比较决定覆盖与否（skillVersion 各端解析失败时回落到
        // 旧的"内容不一致即覆盖"，兼容无版本戳的历史安装）。
        let wasInstalled = fm.fileExists(atPath: destSkill.path)
        if wasInstalled,
           let srcText = try? String(contentsOf: sourceSkill, encoding: .utf8),
           let dstText = try? String(contentsOf: destSkill, encoding: .utf8),
           !skillSyncDecision(sourceText: srcText, destText: dstText) {
            let srcVer = SkillVersion.parse(srcText).map { "\($0)" } ?? "未知"
            let dstVer = SkillVersion.parse(dstText).map { "\($0)" } ?? "未知"
            return "已安装的 remindkit skill（\(dstVer)）比发行版（\(srcVer)）新——可能是手工修订，已跳过自动覆盖；强制同步：remindkit install-skill --force（REMINDKIT_NO_AUTO_SKILL=1 可整体关闭自动同步）"
        }
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

    /// 每次运行自动同步 agent skill（幂等）：`~/.agents/skills/remindkit` 缺失时
    /// 安装；内容不一致时按 frontmatter `skill-version:` 语义化版本比较——发行版
    /// 更新则覆盖（brew upgrade 后 skill 随版本自动同步），安装版更新（手工修订）
    /// 则保留并提示。内容一致时零开销跳过。
    /// 关闭：环境变量 `REMINDKIT_NO_AUTO_SKILL=1`。失败静默（不阻塞主命令）。
    /// 返回提示文本（nil = 已同步/无需提示/安装失败）。
    static func autoInstallIfMissing() -> String? {
        guard ProcessInfo.processInfo.environment["REMINDKIT_NO_AUTO_SKILL"] != "1" else { return nil }
        let home = InstallSkill.effectiveHome
        let dest = URL(fileURLWithPath: home).appendingPathComponent(".agents/skills/remindkit")
        let cmd = InstallSkill()
        guard let source = SkillSource.find() else { return nil }
        return syncSkill(source: source, dest: dest, using: cmd)
    }
}

