import XCTest
@testable import remindkit

final class SearchMatchTests: XCTestCase {

    // MARK: - searchTerms(from:)

    func testSingleTerm() {
        XCTAssertEqual(searchTerms(from: "牛奶"), ["牛奶"])
    }

    func testMultipleTermsSplitOnWhitespace() {
        XCTAssertEqual(searchTerms(from: "牛奶 面包"), ["牛奶", "面包"])
    }

    func testTermsAreLowercased() {
        XCTAssertEqual(searchTerms(from: "Camera Lens"), ["camera", "lens"])
    }

    func testCollapsesRepeatedWhitespace() {
        XCTAssertEqual(searchTerms(from: "  牛奶  面包  "), ["牛奶", "面包"])
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertEqual(searchTerms(from: ""), [])
        XCTAssertEqual(searchTerms(from: "   "), [])
    }

    // MARK: - searchMatch

    func testSingleTermMatchesTitle() {
        XCTAssertTrue(searchMatch(title: "买牛奶", notes: nil, tags: nil, terms: ["牛奶"], matchAll: false))
        XCTAssertFalse(searchMatch(title: "买面包", notes: nil, tags: nil, terms: ["牛奶"], matchAll: false))
    }

    func testORAnyTermHits() {
        XCTAssertTrue(searchMatch(title: "买牛奶", notes: nil, tags: nil, terms: ["牛奶", "面包"], matchAll: false))
        XCTAssertTrue(searchMatch(title: "买面包", notes: nil, tags: nil, terms: ["牛奶", "面包"], matchAll: false))
        XCTAssertFalse(searchMatch(title: "买鸡蛋", notes: nil, tags: nil, terms: ["牛奶", "面包"], matchAll: false))
    }

    func testANDAllTermsMustHit() {
        XCTAssertTrue(searchMatch(title: "牛奶面包", notes: nil, tags: nil, terms: ["牛奶", "面包"], matchAll: true))
        XCTAssertFalse(searchMatch(title: "买牛奶", notes: nil, tags: nil, terms: ["牛奶", "面包"], matchAll: true))
    }

    func testANDCrossesFields() {
        // 标题命中一个 term，notes 命中另一个
        XCTAssertTrue(searchMatch(title: "买牛奶", notes: "配面包", tags: nil, terms: ["牛奶", "面包"], matchAll: true))
        XCTAssertFalse(searchMatch(title: "买牛奶", notes: "配牛奶", tags: nil, terms: ["牛奶", "面包"], matchAll: true))
    }

    func testNotesAndTagsAreSearched() {
        XCTAssertTrue(searchMatch(title: "买", notes: "脱脂牛奶", tags: nil, terms: ["牛奶"], matchAll: false))
        XCTAssertTrue(searchMatch(title: "任务", notes: nil, tags: ["摄影"], terms: ["摄影"], matchAll: false))
    }

    func testCaseInsensitive() {
        // 真实调用链：query → searchTerms(from:) 先小写化，再进 searchMatch
        XCTAssertTrue(searchMatch(title: "Buy Milk", notes: nil, tags: nil, terms: searchTerms(from: "milk"), matchAll: false))
        XCTAssertTrue(searchMatch(title: "Buy Milk", notes: nil, tags: nil, terms: searchTerms(from: "MILK"), matchAll: false))
        XCTAssertTrue(searchMatch(title: "Buy Milk", notes: nil, tags: nil, terms: searchTerms(from: "MILK milk"), matchAll: true))
    }

    func testEmptyTermsMatchNothing() {
        XCTAssertFalse(searchMatch(title: "任何", notes: nil, tags: nil, terms: [], matchAll: false))
        XCTAssertFalse(searchMatch(title: "任何", notes: nil, tags: nil, terms: [], matchAll: true))
    }

    func testBackwardCompatibleSingleTermBehavior() {
        // 单关键词时 OR 与 AND 等价，行为与旧版一致
        let r = (title: "买牛奶", notes: "脱脂", tags: ["日常"] as [String]?)
        XCTAssertTrue(searchMatch(title: r.title, notes: r.notes, tags: r.tags, terms: ["牛奶"], matchAll: false))
        XCTAssertTrue(searchMatch(title: r.title, notes: r.notes, tags: r.tags, terms: ["牛奶"], matchAll: true))
        XCTAssertFalse(searchMatch(title: r.title, notes: r.notes, tags: r.tags, terms: ["面包"], matchAll: false))
    }
}
