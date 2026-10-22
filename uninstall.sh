#!/bin/bash
# uninstall.sh — stop codex-retry and remove the installed files.
set -u

BASE="${CODEX_RETRY_HOME:-$HOME/.local/share/codex-retry}"
STATE="${CODEX_RETRY_STATE:-$HOME/.local/state/codex-retry}"
BIN="$HOME/.local/bin/codex-retry"

for pid in $(ps -axo pid=,command= 2>/dev/null | grep -E '[r]etry_daemon( --|$)' | awk '{print $1}'); do
  kill "$pid" 2>/dev/null || true
done

rm -f "$BIN"
rm -rf "$BASE" "$STATE"

printf '%s\n' "codex-retry uninstalled."
