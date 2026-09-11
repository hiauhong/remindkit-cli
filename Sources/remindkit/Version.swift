import Foundation

/// The version reported by `remindkit --version`.
///
/// Deliberately derived from the *bundled* skill's `skill-version:` frontmatter
/// rather than a hardcoded constant: `Scripts/package.sh` stamps that field from
/// the release tag into the very tarball that ships this binary, so the CLI and
/// its skill can never disagree and there is no second place to bump per release.
/// Falls back to a dev marker when no bundled skill can be located (e.g. a bare
/// `swift build` run outside the repo).
enum RemindkitVersion {
    static let unknown = "0.0.0-dev"

    static var current: String {
        guard let dir = SkillSource.find(),
              let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"),
                                     encoding: .utf8) else {
            return unknown
        }
        return version(fromSkillText: text) ?? unknown
    }

    /// Pure parser (frontmatter `skill-version:` → displayable version), kept
    /// side-effect free so it can be unit tested.
    static func version(fromSkillText text: String) -> String? {
        InstallSkill.SkillVersion.parse(text)?.versionString
    }
}
