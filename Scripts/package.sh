#!/bin/bash
# Package remindkit into a release tarball:
#   remindkit            main CLI (Swift)
#   fetch-remindkit      ObjC subprocess binary (must sit next to the CLI)
#   .agents/skills/      skill source for `remindkit install-skill`
#
# Usage: ./scripts/package.sh [--no-build]
# Output: dist/remindkit-darwin-<arch>.tar.gz

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--no-build" ]]; then
    echo "→ Building..."
    make build
fi

ARCH="$(uname -m)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/bin/.agents/skills"
cp .build/release/remindkit "$STAGE/bin/remindkit"
cp Binaries/fetch-remindkit "$STAGE/bin/fetch-remindkit"
cp -R .agents/skills/remindkit "$STAGE/bin/.agents/skills/remindkit"

# Stamp the packaged SKILL.md with the release version (frontmatter `skill-version:`),
# so the installed skill's auto-sync compares real semver instead of content hashes.
# Release builds run from a tag checkout (GitHub Actions): version = tag minus `v`.
# Local/dev builds keep the frontmatter as committed (e.g. `0.3.5-dev`), which sorts
# below the same-numbered release but above the previous one — hand-synced dev
# copies survive until the matching release replaces them.
SKILL_VERSION="${SKILL_VERSION:-$(git describe --tags --exact-match HEAD 2>/dev/null || true)}"
SKILL_VERSION="${SKILL_VERSION#v}"
if [[ -n "$SKILL_VERSION" ]]; then
    sed -i.bak "s/^skill-version: .*/skill-version: ${SKILL_VERSION}/" \
        "$STAGE/bin/.agents/skills/remindkit/SKILL.md"
    rm "$STAGE/bin/.agents/skills/remindkit/SKILL.md.bak"
fi

mkdir -p dist
tar -czf "dist/remindkit-darwin-${ARCH}.tar.gz" -C "$STAGE" bin
echo "✓ dist/remindkit-darwin-${ARCH}.tar.gz"
echo "  contents: remindkit, fetch-remindkit, .agents/skills/remindkit/SKILL.md"
