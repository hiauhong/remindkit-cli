import ArgumentParser
import Foundation

RemindKit.main()

struct RemindKit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remindkit",
        abstract: "Apple Reminders data pipeline CLI",
        subcommands: [Dump.self, List.self, Query.self, Today.self, Overdue.self, Scheduled.self, Flagged.self, Urgent.self, Search.self, Count.self, Tags.self, Overview.self, Doctor.self, InstallSkill.self, Note.self, Setup.self, Add.self, Complete.self, Delete.self, Move.self, Update.self, Bulk.self, AddList.self, AddGroup.self, AddSection.self, AddSmartList.self, MoveList.self, RecentlyDeleted.self, Restore.self, DeleteList.self, UpdateList.self],
        defaultSubcommand: Overview.self
    )
}
