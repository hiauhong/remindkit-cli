import XCTest
@testable import remindkit

final class ErrorContractTests: XCTestCase {

    // MARK: - reminderKitErrorCode (subprocess message → business code)

    func testMapsNoSuchList() {
        XCTAssertEqual(reminderKitErrorCode(for: "找不到列表：工作"), "noSuchList")
        XCTAssertEqual(reminderKitErrorCode(for: "找不到目标列表：abc"), "noSuchList")
    }

    func testMapsNoSuchReminder() {
        XCTAssertEqual(reminderKitErrorCode(for: "找不到提醒：123"), "noSuchReminder")
    }

    func testMapsNoSuchGroup() {
        XCTAssertEqual(reminderKitErrorCode(for: "找不到分组：工作"), "noSuchGroup")
    }

    func testMapsNoSuchAccount() {
        XCTAssertEqual(reminderKitErrorCode(for: "找不到账户"), "noSuchAccount")
    }

    func testMapsNoSuchDeletedRecord() {
        XCTAssertEqual(reminderKitErrorCode(for: "找不到删除记录：x"), "noSuchDeletedRecord")
    }

    func testMapsNoSuchSection() {
        XCTAssertEqual(reminderKitErrorCode(for: "列表中没有分区「待办」（先用 add-section 创建）"), "noSuchSection")
    }

    func testMapsUnknownToReminderKitError() {
        XCTAssertEqual(reminderKitErrorCode(for: "save failed: something broke"), "reminderKitError")
        XCTAssertEqual(reminderKitErrorCode(for: ""), "reminderKitError")
    }

    func testExplicitSubprocessCodeWinsOverLocalizedMessage() {
        XCTAssertEqual(reminderKitErrorCode(for: [
            "code": "noSuchSection",
            "error": "localized wording may change",
        ]), "noSuchSection")
    }
}
