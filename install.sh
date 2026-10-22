#!/bin/bash
# install.sh — install codex-retry.
#
# One-liner (downloads the prebuilt universal binary from the latest GitHub release):
#   curl -fsSL https://raw.githubusercontent.com/jimmer-code/codex-retry/main/install.sh | bash
# From a git checkout (builds from source, needs Xcode Command Line Tools):
#   ./install.sh
set -euo pipefail

REPO="${CODEX_RETRY_REPO:-jimmer-code/codex-retry}"
BRANCH="${CODEX_RETRY_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
RELEASE="https://github.com/${REPO}/releases/latest/download/codex-retry-macos.tar.gz"

BIN_DIR="$HOME/.local/bin"
SHARE="$HOME/.local/share/codex-retry"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "codex-retry only supports macOS."

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build() { # build <swift source>
  command -v swiftc >/dev/null 2>&1 || die "Xcode Command Line Tools are required to build from source: xcode-select --install"
  say "Building retry_daemon ..."
  swiftc -O "$1" -o "$TMP/retry_daemon"
}

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/src/retry_daemon.swift" ]; then
  build "$SELF_DIR/src/retry_daemon.swift"
  cp "$SELF_DIR/bin/codex-retry" "$TMP/codex-retry"
elif say "Downloading the latest release ..." && curl -fsSL "$RELEASE" | tar -xz -C "$TMP" 2>/dev/null \
    && [ -x "$TMP/retry_daemon" ] && [ -f "$TMP/codex-retry" ]; then
  :
else
  say "No release available; building from source ..."
  curl -fsSL "$RAW/src/retry_daemon.swift" -o "$TMP/retry_daemon.swift" || die "download failed: $RAW/src/retry_daemon.swift"
  curl -fsSL "$RAW/bin/codex-retry" -o "$TMP/codex-retry" || die "download failed: $RAW/bin/codex-retry"
  build "$TMP/retry_daemon.swift"
fi

[ -d "/Applications/ChatGPT.app" ] || say "warning: /Applications/ChatGPT.app not found; codex-retry drives the ChatGPT (Codex) desktop app."

# Stop a running daemon before replacing the binary; restart it afterwards.
was_running=0
pkill -x retry_daemon 2>/dev/null && was_running=1

mkdir -p "$BIN_DIR" "$SHARE"
install -m 755 "$TMP/retry_daemon" "$SHARE/retry_daemon"
install -m 755 "$TMP/codex-retry" "$BIN_DIR/codex-retry"
rm -f "$SHARE/retry_daemon.swift" # left behind by 1.0.0

say ""
say "Installed $BIN_DIR/codex-retry"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "note: $BIN_DIR is not on PATH. Add:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
if [ "$was_running" = 1 ]; then
  sleep 0.5
  "$BIN_DIR/codex-retry" start
else
  say ""
  say "Next: run  codex-retry  to start (run it again to stop)."
  say "It asks for the Accessibility permission for your terminal app on first start."
fi
