import XCTest
@testable import remindkit

final class DateWriteRequestTests: XCTestCase {
    func testAllDayResolutionWithSingleDate() throws {
        let due = DateWriteRequest(epoch: 1, allDay: true)
        XCTAssertEqual(try resolveRequestAllDay(due: due, start: nil), true)
    }

    func testAllDayResolutionWithMatchingDates() throws {
        let due = DateWriteRequest(epoch: 1, allDay: false)
        let start = DateWriteRequest(epoch: 2, allDay: false)
        XCTAssertEqual(try resolveRequestAllDay(due: due, start: start), false)
    }

    func testAllDayResolutionRejectsMixedGranularity() {
        let due = DateWriteRequest(epoch: 1, allDay: true)
        let start = DateWriteRequest(epoch: 2, allDay: false)
        XCTAssertThrowsError(try resolveRequestAllDay(due: due, start: start))
    }

    func testAllDayResolutionWithoutDatesIsNil() throws {
        XCTAssertNil(try resolveRequestAllDay(due: nil, start: nil))
    }
}
