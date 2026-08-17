import ArgumentParser
import Darwin
import Foundation

// 每次运行自动同步 agent skill（幂等）：~/.agents/skills/remindkit 缺失时自动安装，
// 内容与源不一致时自动更新（brew upgrade 后 skill 随版本同步）。只在交互终端（TTY）
// 打印提示，管道/agent 场景静默；install-skill/--help/--version 跳过；
// REMINDKIT_NO_AUTO_SKILL=1 可关闭。
let argv = CommandLine.arguments
let isMetaInvocation = argv.contains("install-skill") || argv.contains("--help")
    || argv.contains("-h") || argv.contains("--version")
if !isMetaInvocation,
   let note = InstallSkill.autoInstallIfMissing(),
   isatty(STDERR_FILENO) != 0 {
    FileHandle.standardError.write((note + "\n").data(using: .utf8)!)
}

RemindKit.main()

struct RemindKit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remindkit",
        abstract: "Apple Reminders data pipeline CLI",
        subcommands: [Dump.self, List.self, Query.self, Today.self, Overdue.self, Scheduled.self, Flagged.self, Urgent.self, Search.self, Count.self, Tags.self, Overview.self, Doctor.self, Authorize.self, InstallSkill.self, Note.self, Setup.self, Add.self, Complete.self, Delete.self, Move.self, Reorder.self, Update.self, Bulk.self, AddList.self, AddGroup.self, AddSection.self, DeleteSection.self, AddSmartList.self, MoveList.self, RecentlyDeleted.self, Restore.self, DeleteList.self, UpdateList.self],
        defaultSubcommand: Overview.self
    )
}
