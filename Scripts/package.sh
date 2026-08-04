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
cp -R .agents/skills/gtd "$STAGE/bin/.agents/skills/gtd"

mkdir -p dist
tar -czf "dist/remindkit-darwin-${ARCH}.tar.gz" -C "$STAGE" bin
echo "✓ dist/remindkit-darwin-${ARCH}.tar.gz"
echo "  contents: remindkit, fetch-remindkit, .agents/skills/remindkit/SKILL.md, .agents/skills/gtd/SKILL.md"
