import XCTest
@testable import remindkit

final class CommandContractTests: XCTestCase {
    func testBulkDryRunDoesNotRequireConfirmation() {
        XCTAssertFalse(bulkConfirmationRequired(op: "delete", dryRun: true, yes: false))
        XCTAssertFalse(bulkConfirmationRequired(op: "move", dryRun: true, yes: false))
    }

    func testBulkDestructiveExecutionRequiresConfirmation() {
        XCTAssertTrue(bulkConfirmationRequired(op: "delete", dryRun: false, yes: false))
        XCTAssertTrue(bulkConfirmationRequired(op: "move", dryRun: false, yes: false))
        XCTAssertFalse(bulkConfirmationRequired(op: "delete", dryRun: false, yes: true))
    }

    func testPriorityNoneMapsToZero() throws {
        XCTAssertEqual(try parsePriority("none"), 0)
        XCTAssertEqual(try parsePriority("0"), 0)
    }

    func testSectionCannotDisableSectionLoading() {
        XCTAssertThrowsError(try validateQuerySectionOptions(
            section: "Inbox", noSections: true, tree: false, smartList: nil
        ))
    }

    func testSmartListTreeIsExplicitlyUnsupported() {
        XCTAssertThrowsError(try validateQuerySectionOptions(
            section: nil, noSections: false, tree: true, smartList: "Flagged"
        ))
    }
}
