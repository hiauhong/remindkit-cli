import EventKitCore
import XCTest

/// 安全关键逻辑：EventKit fallback 的列表解析必须严格（完整 ID → UUID 前缀
/// → 精确标题），**禁止子串匹配**——`工作` 绝不能解析到 `工作备份`。
/// REVIEW.md #1 的回归测试。
final class StrictListMatchTests: XCTestCase {

    private let ids = [
        "A1B2C3D4-E5F6-47A8-9B0C-1D2E3F4A5B6C",   // 工作
        "11111111-2222-3333-4444-555555555555",   // 工作备份
        "22222222-3333-4444-5555-666666666666",   // 财务
        "33333333-4444-5555-6666-777777777777",   // 财务选题
        "44444444-5555-6666-7777-888888888888",   // 日常
    ]
    private let titles = ["工作", "工作备份", "财务", "财务选题", "日常"]

    private func match(_ token: String) -> [Int] {
        RemindersWriter.matchCalendars(identifiers: ids, titles: titles, token: token)
    }

    func testExactTitleMatchesOnlyItselfNotSubstring() {
        // 「工作」只匹配「工作」，绝不匹配「工作备份」
        XCTAssertEqual(match("工作"), [0])
        XCTAssertEqual(match("财务"), [2])
        XCTAssertEqual(match("日常"), [4])
    }

    func testExactIDWins() {
        XCTAssertEqual(match("11111111-2222-3333-4444-555555555555"), [1])
    }

    func testUUIDPrefixMatches() {
        // ≥8 位前缀命中
        XCTAssertEqual(match("A1B2C3D4-E5F6"), [0])
        // 短于 8 位的前缀不匹配（避免把普通词当 UUID）
        XCTAssertTrue(match("A1B2").isEmpty)
    }

    func testPrefixPrecedesExactTitle() {
        // token 同时是某列表 ID 前缀和另一列表标题时，ID 前缀优先
        let samePrefixIds = [
            "ABCD1234-1111-2222-3333-444444444444",
            "ABCD5678-1111-2222-3333-444444444444",
        ]
        let result = RemindersWriter.matchCalendars(
            identifiers: samePrefixIds, titles: ["ABCD1234-1111", "x"], token: "ABCD1234-1111")
        XCTAssertEqual(result, [0])
    }

    func testCaseInsensitiveExactTitle() {
        // 标题匹配大小写不敏感：OKR / okr 命中同一列表
        let result = RemindersWriter.matchCalendars(
            identifiers: ["ID1"], titles: ["OKR"], token: "okr")
        XCTAssertEqual(result, [0])
    }

    func testDuplicateTitlesAllReturned() {
        let dupIds = ["D1", "D2"]
        let result = RemindersWriter.matchCalendars(
            identifiers: dupIds, titles: ["同名", "同名"], token: "同名")
        XCTAssertEqual(result, [0, 1])
    }

    func testEmptyOrWhitespaceToken() {
        XCTAssertTrue(match("").isEmpty)
        XCTAssertTrue(match("   ").isEmpty)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(match("不存在的列表").isEmpty)
    }
}
