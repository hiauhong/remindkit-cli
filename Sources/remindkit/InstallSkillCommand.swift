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
        let failures = try install(
            source: sourceDir,
            targets: installClaude ? [home + "/.claude/skills/remindkit"] : [],
            force: force
        ) + install(
            source: sourceDir,
            targets: installAgents ? [home + "/.agents/skills/remindkit"] : [],
            force: force
        )

        if failures.isEmpty {
            print("Installed remindkit skill.")
            print("  \(home)/.claude/skills/remindkit")
            print("  \(home)/.agents/skills/remindkit")
        } else {
            for message in failures {
                fputs("error: \(message)\n", stderr)
            }
            throw ExitCode.failure
        }
    }

    // MARK: - Skill discovery

    private func findSkillSource() -> URL? {
        for candidate in skillSourceCandidates()
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("SKILL.md").path) {
            return candidate
        }
        return nil
    }

    private func skillSourceCandidates() -> [URL] {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
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

    private func install(source: URL, targets: [String], force: Bool) throws -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for target in targets {
            let dest = URL(fileURLWithPath: target)
            if fm.fileExists(atPath: dest.path) {
                if !force {
                    failures.append("\(target) already exists (use --force to overwrite)")
                    continue
                }
                try? fm.removeItem(at: dest)
            }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: dest)
            } catch {
                failures.append("failed to install to \(target): \(error.localizedDescription)")
            }
        }
        return failures
    }
}
