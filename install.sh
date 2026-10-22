#!/bin/bash
# install.sh — build and install codex-retry.
#
# From a git checkout:
#   ./install.sh
# From a one-liner (after the repo is published):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/codex-retry/main/install.sh | bash
set -euo pipefail

REPO="${CODEX_RETRY_REPO:-jiaweizhang1995/codex-retry}"
BRANCH="${CODEX_RETRY_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

BIN_DIR="$HOME/.local/bin"
SHARE="$HOME/.local/share/codex-retry"
STATE="$HOME/.local/state/codex-retry"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "codex-retry only supports macOS."

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
TMP=""
cleanup() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/src/retry_daemon.swift" ] && [ -f "$SELF_DIR/bin/codex-retry" ]; then
  SRC_DAEMON="$SELF_DIR/src/retry_daemon.swift"
  SRC_CLI="$SELF_DIR/bin/codex-retry"
else
  say "Downloading codex-retry sources from GitHub ..."
  TMP="$(mktemp -d)"
  command -v curl >/dev/null 2>&1 || die "curl is required for the remote install."
  curl -fsSL "$RAW/src/retry_daemon.swift" -o "$TMP/retry_daemon.swift" \
    || die "download failed: $RAW/src/retry_daemon.swift"
  curl -fsSL "$RAW/bin/codex-retry" -o "$TMP/codex-retry" \
    || die "download failed: $RAW/bin/codex-retry"
  SRC_DAEMON="$TMP/retry_daemon.swift"
  SRC_CLI="$TMP/codex-retry"
fi

if ! command -v swiftc >/dev/null 2>&1; then
  say "Xcode Command Line Tools are required to build the daemon."
  die "Install them first:  xcode-select --install"
fi

if [ ! -d "/Applications/ChatGPT.app" ]; then
  say "warning: /Applications/ChatGPT.app was not found."
  say "         codex-retry drives the ChatGPT (Codex) desktop app; install it first."
fi

# Stop an already running daemon before replacing the binary.
for pid in $(ps -axo pid=,command= 2>/dev/null | grep -E '[r]etry_daemon( --|$)' | awk '{print $1}'); do
  kill "$pid" 2>/dev/null || true
done

say "Building retry_daemon ..."
mkdir -p "$BIN_DIR" "$SHARE" "$STATE"
swiftc -O "$SRC_DAEMON" -o "$SHARE/retry_daemon"
install -m 755 "$SRC_CLI" "$BIN_DIR/codex-retry"
install -m 644 "$SRC_DAEMON" "$SHARE/retry_daemon.swift"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "note: $BIN_DIR is not on PATH. Add:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

say ""
say "Installed:"
say "  $BIN_DIR/codex-retry"
say "  $SHARE/retry_daemon"
say ""
say "Next steps:"
say "  1) Grant 'Accessibility' and 'Screen Recording' to the terminal app you use"
say "     (System Settings > Privacy & Security)."
say "  2) Run:  codex-retry          # start / stop toggle"
say "     Run:  codex-retry doctor   # verify permissions and app state"
