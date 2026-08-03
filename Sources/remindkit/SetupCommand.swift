import ArgumentParser
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "First-run guided setup: record how you use Reminders (conventions + list notes)"
    )

    @Flag(name: .long, help: "Non-interactive: print conventions status and exit (agent-friendly)")
    var status: Bool = false

    @Flag(name: .long, help: "Re-run setup even if conventions already exist")
    var force: Bool = false

    func run() throws {
        let convStore = ConventionsStore(fileURL: ConventionsStore.defaultURL())
        let notesStore = NotesStore(fileURL: NotesStore.defaultURL())

        // Agent path: report state, never block on stdin.
        if status {
            try printStatus(convStore)
            return
        }

        let existing = convStore.load()
        if existing != nil && !force {
            print("remindkit: conventions already exist at \(convStore.fileURL.path)")
            print()
            print(existing!)
            print()
            print("Re-run with `remindkit setup --force` to reconfigure.")
            return
        }

        guard isInteractive() else {
            fail("nonInteractive",
                 "`setup` is a guided interview; run it in a terminal, or check state with `setup --status`.")
        }

        print("""
        ─────────────────────────────────────────────────────────
        remindkit 首次设置：记录你「怎么用提醒事项」
        回答几个问题，结果会保存为：
          约定层 → conventions.md（agent 读它理解你的方法论）
          语义层 → 列表备注（note），查询时自动携带
        ─────────────────────────────────────────────────────────
        """)

        let data = fetchEnrichedData(includeSections: false)
        let listNames = data.calendars.filter { !$0.isGroup }.map(\.title)
        let joined = listNames.joined(separator: "、")

        var a = SetupAnswers()
        a.inboxList = ask("「收集」这类列表你叫什么（新想法先放这）", default: a.inboxList, choices: listNames) ?? a.inboxList
        a.inboxPurpose = ask("「\(a.inboxList)」是做什么的？", default: a.inboxPurpose) ?? a.inboxPurpose
        a.okrList = ask("长期目标规划用哪个列表？", default: a.okrList, choices: listNames) ?? a.okrList
        a.okrPurpose = ask("「\(a.okrList)」是做什么的？", default: a.okrPurpose) ?? a.okrPurpose
        a.flagMeaning = ask("旗标（flagged）代表什么？", default: a.flagMeaning) ?? a.flagMeaning
        a.defaultList = ask("新建提醒默认放哪个列表？", default: a.defaultList, choices: listNames) ?? a.defaultList

        print("\n你当前有这些列表：\(joined)")
        print("想为其中几个添加用途备注（note）吗？列表备注能让 agent 读写时选对列表。")
        var notesDone = 0
        while true {
            let input = ask("输入列表名添加备注（直接回车结束）", default: nil, choices: listNames)
            guard let name = input, !name.isEmpty else { break }
            let matches = resolveListsOrFail(data.calendars, name)
            if matches.count > 1 {
                print("  「\(name)」重名，请用完整 UUID：\(matches.map(\.id).joined(separator: " 或 "))")
                continue
            }
            let cal = matches[0]
            let purpose = ask("  「\(cal.title)」的用途？", default: nil, choices: nil)
            if let purpose, !purpose.isEmpty {
                var notes = notesStore.load()
                notes[cal.id] = purpose
                try notesStore.save(notes)
                notesDone += 1
                print("  ✓ 已保存备注")
            }
        }

        print("\n其它想告诉 agent 的使用约定？（如「新提醒默认加 #生活 标签」，空行结束）")
        while true {
            let line = ask("  >", default: nil, choices: nil)
            guard let line, !line.isEmpty else { break }
            a.extra.append(line)
        }

        try convStore.save(renderConventions(a))
        print("\n✓ 约定已保存到 \(convStore.fileURL.path)")
        print("✓ 本次设置了 \(notesDone) 条列表备注")
        print("\n完成。之后 agent 会读取这些信息来理解你的提醒事项。")
        print("（可用 `remindkit setup --force` 重新配置）")
    }

    private func printStatus(_ convStore: ConventionsStore) throws {
        let exists = convStore.load()
        if let text = exists {
            print("{\"configured\":true,\"file\":\"\(convStore.fileURL.path)\"}")
            print()
            print(text)
        } else {
            print("{\"configured\":false,\"file\":\"\(convStore.fileURL.path)\"}")
            print()
            print("remindkit: conventions not set up yet. Run `remindkit setup` in a terminal to record how you use Reminders.")
        }
    }

    // MARK: - Interview helpers

    private func isInteractive() -> Bool {
        isatty(FileHandle.standardInput.fileDescriptor) != 0
    }

    /// Ask one question with an optional default and optional choice hint.
    /// Returns nil when the user just hits enter with no default.
    private func ask(_ prompt: String, default dflt: String?, choices: [String]? = nil) -> String? {
        var hint = ""
        if let choices, !choices.isEmpty {
            hint = "（可选：\(choices.joined(separator: "、"))）"
        }
        if let dflt {
            print("\(prompt) [\(dflt)]\(hint)")
        } else {
            print("\(prompt)\(hint)")
        }
        print("> ", terminator: "")
        fflush(stdout)
        guard let line = readLine() else { return dflt }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return dflt }
        return trimmed
    }
}
