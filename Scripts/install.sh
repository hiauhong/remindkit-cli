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
REPO="${REPO:-hiauhong/remindkit-cli}"
ARCH="$(uname -m)"; [[ "$ARCH" == "arm64" ]] || ARCH="x86_64"

info()  { printf "\033[1;34m→\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }

LOCAL_BUILD_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$INSTALL_DIR/.agents/skills"

install_skill() {  # copy skill source without nesting (dest must not exist)
    rm -rf "$2" && cp -R "$1" "$2"
}

if [[ -x "$LOCAL_BUILD_DIR/.build/release/remindkit" && -x "$LOCAL_BUILD_DIR/Binaries/fetch-remindkit" ]]; then
    info "Installing from local build at $LOCAL_BUILD_DIR"
    cp "$LOCAL_BUILD_DIR/.build/release/remindkit" "$INSTALL_DIR/remindkit"
    cp "$LOCAL_BUILD_DIR/Binaries/fetch-remindkit" "$INSTALL_DIR/fetch-remindkit"
    install_skill "$LOCAL_BUILD_DIR/.agents/skills/remindkit" "$INSTALL_DIR/.agents/skills/remindkit"
    install_skill "$LOCAL_BUILD_DIR/.agents/skills/gtd" "$INSTALL_DIR/.agents/skills/gtd"
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
    install_skill "$TMP/bin/.agents/skills/remindkit" "$INSTALL_DIR/.agents/skills/remindkit"
    install_skill "$TMP/bin/.agents/skills/gtd" "$INSTALL_DIR/.agents/skills/gtd"
fi

chmod +x "$INSTALL_DIR/remindkit" "$INSTALL_DIR/fetch-remindkit"
ok "Installed remindkit to $INSTALL_DIR"

if [[ "${REMINDKIT_SKIP_SKILL:-0}" != "1" ]]; then
    info "Registering remindkit skill for AI agents..."
    if "$INSTALL_DIR/remindkit" install-skill --agents --force >/dev/null 2>&1; then
        ok "Skill installed to ~/.agents/skills/remindkit — agents (pi, codex, …) will discover remindkit automatically"
    else
        warn "Auto skill install failed — run manually: remindkit install-skill --agents"
    fi
    # GTD 方法论 skill(纯 skill,无 CLI 命令,直接同步)
    if [[ -d "$INSTALL_DIR/.agents/skills/gtd" ]]; then
        rm -rf "$HOME/.agents/skills/gtd"
        mkdir -p "$HOME/.agents/skills"
        cp -R "$INSTALL_DIR/.agents/skills/gtd" "$HOME/.agents/skills/gtd"
        ok "GTD skill installed to ~/.agents/skills/gtd"
    fi
else
    warn "REMINDKIT_SKIP_SKILL=1 — skipped skill registration. Run 'remindkit install-skill --agents' to register later."
fi

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "$INSTALL_DIR is not in your PATH. Add this line to your shell config:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

if [[ "${REMINDKIT_SKIP_SKILL:-0}" != "1" ]]; then
    info "Skill auto-registered above. Claude Code users: remindkit install-skill --claude"
fi
info "Next steps:"
echo "  remindkit doctor --for-agent     # check Reminders permission"
