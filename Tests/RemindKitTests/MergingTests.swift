import XCTest
@testable import remindkit

final class MergingTests: XCTestCase {

    // MARK: - mergedReminders (parentId ↔ subtaskIds index)

    func testMergedRemindersBuildsSubtaskIndex() {
        let raw: [ReminderRaw] = [
            ReminderRaw(externalIdentifier: "parent-1", listID: "L1", title: "父任务", notes: nil,
                        priority: 0, completed: false, creationDate: nil, completionDate: nil,
                        dueDate: nil, startDate: nil, allDay: false, timeZone: nil,
                        recurrenceRules: nil, order: 0, section: nil, flagged: false, urgent: false,
                        url: nil, alarms: nil, parentId: nil, tags: nil),
            ReminderRaw(externalIdentifier: "child-1", listID: "L1", title: "子任务1", notes: nil,
                        priority: 0, completed: false, creationDate: nil, completionDate: nil,
                        dueDate: nil, startDate: nil, allDay: false, timeZone: nil,
                        recurrenceRules: nil, order: 1, section: nil, flagged: false, urgent: false,
                        url: nil, alarms: nil, parentId: "parent-1", tags: nil),
            ReminderRaw(externalIdentifier: "child-2", listID: "L1", title: "子任务2", notes: nil,
                        priority: 0, completed: false, creationDate: nil, completionDate: nil,
                        dueDate: nil, startDate: nil, allDay: false, timeZone: nil,
                        recurrenceRules: nil, order: 2, section: nil, flagged: false, urgent: false,
                        url: nil, alarms: nil, parentId: "parent-1", tags: nil),
        ]

        let merged = mergedReminders(from: raw)
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })

        XCTAssertEqual(byID["parent-1"]?.subtaskIds.sorted(), ["child-1", "child-2"])
        XCTAssertEqual(byID["child-1"]?.parentId, "parent-1")
        XCTAssertEqual(byID["child-2"]?.parentId, "parent-1")
        // children themselves have no subtasks
        XCTAssertTrue(byID["child-1"]?.subtaskIds.isEmpty ?? false)
    }

    func testMergedRemindersNoParentsYieldsEmptySubtasks() {
        let raw: [ReminderRaw] = [
            ReminderRaw(externalIdentifier: "a", listID: "L1", title: "A", notes: nil,
                        priority: 0, completed: false, creationDate: nil, completionDate: nil,
                        dueDate: nil, startDate: nil, allDay: false, timeZone: nil,
                        recurrenceRules: nil, order: 0, section: nil, flagged: false, urgent: false,
                        url: nil, alarms: nil, parentId: nil, tags: nil),
        ]
        let merged = mergedReminders(from: raw)
        XCTAssertTrue(merged[0].subtaskIds.isEmpty)
        XCTAssertNil(merged[0].parentId)
    }

    func testMergedRemindersDanglingParentKeepsParentId() {
        // A child whose parent is not in the dataset must keep parentId (the
        // read side surfaces it; integrity checks elsewhere catch dangling refs).
        let raw: [ReminderRaw] = [
            ReminderRaw(externalIdentifier: "orphan", listID: "L1", title: "孤儿", notes: nil,
                        priority: 0, completed: false, creationDate: nil, completionDate: nil,
                        dueDate: nil, startDate: nil, allDay: false, timeZone: nil,
                        recurrenceRules: nil, order: 0, section: nil, flagged: false, urgent: false,
                        url: nil, alarms: nil, parentId: "missing-parent", tags: nil),
        ]
        let merged = mergedReminders(from: raw)
        XCTAssertEqual(merged[0].parentId, "missing-parent")
        XCTAssertTrue(merged[0].subtaskIds.isEmpty)
    }

    // MARK: - mergedCalendars (parentUUID normalization)

    func testMergedCalendarsNormalizesNullParentUUID() {
        let lists: [ListRaw] = [
            ListRaw(uuid: "L1", name: "顶层", isGroup: false, icon: nil, color: nil,
                    group: nil, sections: nil, parentUUID: "null"),
            ListRaw(uuid: "L2", name: "组内", isGroup: false, icon: nil, color: nil,
                    group: nil, sections: nil, parentUUID: "G1"),
            ListRaw(uuid: "G1", name: "分组", isGroup: true, icon: nil, color: nil,
                    group: nil, sections: nil, parentUUID: nil),
        ]
        let merged = mergedCalendars(from: lists)
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        // "null" string from the subprocess must become a real nil
        XCTAssertNil(byID["L1"]?.parentUUID)
        XCTAssertEqual(byID["L2"]?.parentUUID, "G1")
        XCTAssertTrue(byID["G1"]?.isGroup ?? false)
    }

    // MARK: - resolveListFilter (UUID → prefix → exact title → substring)

    private func makeCalendars() -> [CalendarEntry] {
        [
            CalendarEntry(id: "AAAAAAAA-1111-2222-3333-444444444444", title: "工作", isGroup: false,
                          icon: nil, color: nil, sections: nil, parentUUID: nil, order: 0),
            CalendarEntry(id: "BBBBBBBB-1111-2222-3333-444444444444", title: "工作", isGroup: false,
                          icon: nil, color: nil, sections: nil, parentUUID: nil, order: 1),
            CalendarEntry(id: "CCCCCCCC-1111-2222-3333-444444444444", title: "工作", isGroup: false,
                          icon: nil, color: nil, sections: nil, parentUUID: nil, order: 2),
            CalendarEntry(id: "DDDDDDDD-1111-2222-3333-444444444444", title: "测试选题", isGroup: false,
                          icon: nil, color: nil, sections: nil, parentUUID: nil, order: 3),
        ]
    }

    func testResolveListFilterExactUUID() throws {
        let hit = try resolveListFilter(makeCalendars(), "AAAAAAAA-1111-2222-3333-444444444444")
        XCTAssertEqual(hit.map(\.title), ["工作"])
    }

    func testResolveListFilterUUIDPrefix() throws {
        let hit = try resolveListFilter(makeCalendars(), "BBBBBBBB-1111")
        XCTAssertEqual(hit.map(\.title), ["工作"])
    }

    func testResolveListFilterExactTitleReturnsAllDuplicates() throws {
        let hit = try resolveListFilter(makeCalendars(), "工作")
        XCTAssertEqual(hit.count, 2) // both 工作 lists
    }

    func testResolveListFilterSubstringFallback() throws {
        let hit = try resolveListFilter(makeCalendars(), "选题")
        XCTAssertEqual(hit.map(\.title), ["测试选题"])
    }

    func testResolveListFilterNoMatchThrows() {
        XCTAssertThrowsError(try resolveListFilter(makeCalendars(), "不存在")) { error in
            XCTAssertTrue(error is ListFilterError)
            XCTAssertEqual((error as? ListFilterError)?.code, "noSuchList")
        }
    }

    // MARK: - mergedSmartLists

    func testMergedSmartListsSkipsNilUUID() {
        let raw = ReminderKitRaw(
            smartLists: [
                SmartListRaw(name: "A", uuid: "U1", type: nil, sortingStyle: nil, filterData: nil, icon: nil, color: nil),
                SmartListRaw(name: "B", uuid: nil, type: nil, sortingStyle: nil, filterData: nil, icon: nil, color: nil),
            ],
            listIDsOrdering: nil, lists: nil, reminders: nil
        )
        let merged = mergedSmartLists(raw)
        XCTAssertEqual(merged.map(\.name), ["A"])
    }
}
