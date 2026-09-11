import XCTest
@testable import remindkit

/// `RemindkitVersion`（`remindkit --version` 的取值来源）的纯逻辑测试：从内置 skill
/// 的 frontmatter `skill-version:` 还原可显示的版本串。无 TCC 依赖，CI 可跑。
final class VersionTests: XCTestCase {
    private func skill(_ version: String?) -> String {
        var front = "---\nname: remindkit\n"
        if let version { front += "skill-version: \(version)\n" }
        front += "---\n\n# body\n"
        return front
    }

    func testReadsStampedReleaseVersion() {
        XCTAssertEqual(RemindkitVersion.version(fromSkillText: skill("0.3.5")), "0.3.5")
    }

    func testKeepsPrereleaseSuffix() {
        XCTAssertEqual(RemindkitVersion.version(fromSkillText: skill("0.3.5-dev")), "0.3.5-dev")
    }

    func testDropsBuildMetadata() {
        XCTAssertEqual(RemindkitVersion.version(fromSkillText: skill("0.3.5+build.7")), "0.3.5")
    }

    func testNilWhenNotParseable() {
        XCTAssertNil(RemindkitVersion.version(fromSkillText: "no frontmatter at all"))
        XCTAssertNil(RemindkitVersion.version(fromSkillText: skill(nil)))
        XCTAssertNil(RemindkitVersion.version(fromSkillText: skill("not-a-version")))
    }

    func testFallbackMarker() {
        XCTAssertEqual(RemindkitVersion.unknown, "0.0.0-dev")
    }
}
