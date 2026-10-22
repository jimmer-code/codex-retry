# Design notes

## Problem

The ChatGPT / Codex desktop app (bundle `com.openai.codex`) shows
`Selected model is at capacity. Please try a different model.` when the backend rejects a model call for capacity
reasons (`codex_error_info: "server_overloaded"`). The error banner has a manual **Retry** button. The app does not
retry automatically for this error, because its automatic capacity retry only runs when the server provides a retry
delay, which it does not here.

Retrying by API is impossible from outside the app while the chat is open: the desktop app's own app-server holds a
per-thread writer lock (`.codex/thread-writer-locks/<thread-id>.lock`, error `thread ... already has an active
writer`). A second app-server (e.g. the `--remote-control` daemon) can list threads read-only but cannot start a turn
on a thread the desktop app owns.

Therefore the only reliable trigger is the UI button.

## Components

| File | Role |
| --- | --- |
| `bin/codex-retry` | Pure bash CLI: toggle/start/stop/status/sweep/threads/uninstall. Starts the daemon detached with `nohup`, passes configuration via flags, checks permissions via the daemon's helper modes. |
| `src/retry_daemon.swift` | Single-file Swift daemon: Accessibility lookup, background press, fallback click, idle tracking, hidden-session sweep, app-server client. |
| `install.sh` | Installs in `~/.local/bin` and `~/.local/share/codex-retry`. `curl | bash` downloads the universal binary from the latest release (falls back to building the source with `swiftc`); a local checkout builds from source. Restarts a running daemon. |

## Configuration

Environment variables read by `codex-retry` (also listed by `codex-retry help`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `CODEX_RETRY_LANG` | system locale | CLI language (`en` or `zh`) |
| `CODEX_RETRY_IDLE` | `10` | idle seconds before acting while ChatGPT is frontmost (and before fallback clicks) |
| `CODEX_RETRY_COOLDOWN` | `8` | minimum seconds between retries in the same window |
| `CODEX_RETRY_INTERVAL` | `2` | scan interval in seconds |
| `CODEX_RETRY_SWEEP` | `1` | set to `0` to disable hidden-session retries |
| `CODEX_RETRY_SWEEP_IDLE` | `15` | idle seconds before a sweep starts |
| `CODEX_RETRY_SWEEP_EVERY` | `60` | minimum seconds between sweeps |
| `CODEX_RETRY_SWEEP_COOLDOWN` | `120` | per-session cooldown between hidden retries |
| `CODEX_RETRY_SWEEP_RECENT_MIN` | `120` | only sweep sessions updated within this many minutes |

For development: `swiftc -O src/retry_daemon.swift -o retry_daemon && ./retry_daemon --once --dry-run` runs one
scan and logs what would be retried.

## macOS APIs used

- **Accessibility** (`AXUIElement`) — enumerate ChatGPT windows and their titles, find the Retry `AXButton`, set
  `AXMain` on a window and `AXFocused` on the button, read the button frame for the fallback click.
  `AXManualAccessibility` is set on the app once so the Chromium-based UI exposes its full tree.
- **CGEvent** `postToPid` — Return key down/up delivered straight to the ChatGPT process (no activation).
  Fallback: mouse down/up at the button centre through `kCGHIDEventTap`, plus `CGWarpMouseCursorPosition`.
- **IOKit** (`IORegistry` → `IOHIDSystem` → `HIDIdleTime`) — system idle time for user-activity gating.
- **LaunchServices** (`open codex://threads/<id>`) — navigate a window to a specific thread for the hidden sweep.

No screenshots and no OCR, so only the Accessibility permission is needed.

## Pressing strategy

The Retry button exposes no `AXPress` action (only `AXShowMenu` / `AXScrollToVisible`), but it is a real focusable
button. For each window with a Retry button (bottom-most one if several):

1. Remember the app's main window and whether the composer text area has focus.
2. Set `AXMain` on the target window and `AXFocused` on the button.
3. Check that the button now reports `AXFocused == true`. If not, stop: Return would go to whatever has focus,
   which could be the composer with a draft in it. (The app-level `AXFocusedUIElement` is `nil` while the app is
   in the background, so the check has to read the button's own attribute.)
4. Post Return to the app's pid. The button disappears within about a second when the retry starts.
5. Restore the composer focus and the previous main window.
6. If the button is still there and the user is idle: scroll it into view, activate the app, raise the window,
   click the button centre, and reactivate the previously frontmost app.

One attempt per window per cooldown (`cooldown`, keyed by window title).

What did not work in testing (2026-10-22, app 26.1016.61520): mouse events sent with `postToPid` (with or without
the window-number fields 91/92), and Space instead of Return.

## Idle model

`HIDIdleTime` is reset by *any* HID event, including the fallback's synthetic clicks. The daemon tracks
`lastSyntheticAt` and `lastUserEventAt`. At each poll it reads `m = HIDIdleTime`:

- if `m + 0.4s < now - lastSyntheticAt`, the latest event happened after our last synthetic post, i.e. it was a real
  user event → `lastUserEventAt = now - m`;
- otherwise the latest event is our own synthetic post (or older), so the user idle estimate is unchanged.

User idle = `now - lastUserEventAt`. While ChatGPT is frontmost and the user is active, nothing is touched (moving
keyboard focus would disturb typing). Otherwise background presses happen right away; the fallback click and the
sweep, which activate the app, wait for idle.

## Hidden-session sweep

Failed sessions that are not displayed in any window have no rendered Retry button. Sweep:

1. Read the thread list (id, name, rollout path, updatedAt) from the app's local app-server through a read-only
   unix-socket WebSocket JSON-RPC client (`initialize` + `thread/list`). No writes.
2. For each thread updated within `sweep-recent-min` (default 120 min), read the last few lines of its rollout and
   check whether the last `task_complete` carries a capacity error and no newer `task_started` exists.
3. Skip threads already visible in a window (window title ≈ thread name; macOS truncates window titles, so compare a
   normalized 12-character prefix).
4. While the user is idle and at most once per `sweep-every` seconds, for each hidden failed thread:
   make the target window the main window, `open codex://threads/<id>`, poll until the window title matches the
   thread and a Retry button exists, press it as above, then continue.
5. At the end, navigate the window back to the thread it showed before the sweep and reactivate the app that was
   frontmost. (The deep link activates ChatGPT even when opened with `activates = false`.)

Per-thread cooldown (`sweep-cooldown`) prevents retrying the same session on every sweep.

## Permissions and TCC

The daemon is launched by the CLI from the user's terminal. macOS attributes the required TCC permissions
(Accessibility / "Device Control and Data Access") to the **terminal application**, not to the
daemon binary. Consequences:

- Run `codex-retry` from a terminal that has the permission.
- The daemon keeps working after the terminal window closes, as long as the terminal application process is alive.
- A user who installs the CLI and runs it from a different terminal must grant the permission to that terminal.

## Why not lcu / CUA / MCP

Those systems provide agent-facing computer-use APIs, but they either require a host agent to be installed or
explicitly refuse to control the ChatGPT app itself ("forbidden for safety reasons"). The retry press is a single,
well-defined UI action, so a small standalone tool with direct macOS APIs is simpler, has fewer moving parts, and
works for any agent or human that can run a shell command.

## Known limitations

- Detection depends on the localized button label; the keyword table covers common languages but a new UI language would
  need a keyword addition.
- The app version may change the AX tree, banner layout, or the app-server protocol; the code degrades gracefully
  (logs a skip) but retry automation may need an update.
- Only the capacity error case is handled (button-based retry).
