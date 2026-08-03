#!/bin/bash
# remindkit installer — installs from a local build if present, otherwise
# downloads the latest release from GitHub. No sudo needed.
#
# Usage:
#   ./scripts/install.sh                 # local build if available, else download
#   curl -fsSL https://<site>/install | bash   # remote install
#
# Env:
#   INSTALL_DIR=~/.local/bin             # where the binaries land
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
REPO="${REPO:-hiauhong/remindkit}"
ARCH="$(uname -m)"; [[ "$ARCH" == "arm64" ]] || ARCH="x86_64"

info()  { printf "\033[1;34m→\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }

LOCAL_BUILD_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$INSTALL_DIR/.agents/skills"

if [[ -x "$LOCAL_BUILD_DIR/.build/release/remindkit" && -x "$LOCAL_BUILD_DIR/Binaries/fetch-remindkit" ]]; then
    info "Installing from local build at $LOCAL_BUILD_DIR"
    cp "$LOCAL_BUILD_DIR/.build/release/remindkit" "$INSTALL_DIR/remindkit"
    cp "$LOCAL_BUILD_DIR/Binaries/fetch-remindkit" "$INSTALL_DIR/fetch-remindkit"
    cp -R "$LOCAL_BUILD_DIR/.agents/skills/remindkit" "$INSTALL_DIR/.agents/skills/remindkit"
else
    info "Fetching latest release..."
    LATEST="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    URL="https://github.com/${REPO}/releases/download/${LATEST}/remindkit-darwin-${ARCH}.tar.gz"
    info "Downloading ${URL}"
    curl -fsSL "$URL" -o "$TMP/pkg.tar.gz"
    tar -xzf "$TMP/pkg.tar.gz" -C "$TMP"
    cp "$TMP/bin/remindkit" "$INSTALL_DIR/remindkit"
    cp "$TMP/bin/fetch-remindkit" "$INSTALL_DIR/fetch-remindkit"
    cp -R "$TMP/bin/.agents/skills/remindkit" "$INSTALL_DIR/.agents/skills/remindkit"
fi

chmod +x "$INSTALL_DIR/remindkit" "$INSTALL_DIR/fetch-remindkit"
ok "Installed remindkit to $INSTALL_DIR"

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "$INSTALL_DIR is not in your PATH. Add this line to your shell config:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

info "Next steps:"
echo "  remindkit install-skill          # make your AI agents discover the skill"
echo "  remindkit doctor --for-agent     # check Reminders permission"
