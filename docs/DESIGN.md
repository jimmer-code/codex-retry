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
| `bin/codex-retry` | Pure bash CLI: toggle/start/stop/status/doctor/sweep/threads. Starts the daemon detached with `nohup`, passes configuration via flags, checks permissions via the daemon's helper modes. |
| `src/retry_daemon.swift` | Single-file Swift daemon: window discovery, Accessibility, OCR, clicking, idle tracking, hidden-session sweep, app-server client. |
| `install.sh` | Builds the daemon with `swiftc`, installs in `~/.local/bin` and `~/.local/share/codex-retry`. Supports both a local checkout and `curl | bash` (downloads the two source files from GitHub raw). |

## macOS APIs used

- **CoreGraphics** `CGWindowListCopyWindowInfo` — find ChatGPT windows on screen (id, bounds, title).
- **Accessibility** (`AXUIElement`) — raise/focus windows, `AXScrollToVisible` on the Retry button so it is rendered
  even when the transcript is scrolled.
- **ScreenCaptureKit via `/usr/sbin/screencapture -l <window-id>`** — capture just the ChatGPT window (requires
  Screen Recording permission).
- **Vision** `VNRecognizeTextRequest` — on-device OCR to find the localized Retry label and its center point.
- **CGEvent** — synthetic mouse down/up at the OCR point (`kCGHIDEventTap`), plus `CGWarpMouseCursorPosition`.
- **IOKit** (`IORegistry` → `IOHIDSystem` → `HIDIdleTime`) — system idle time for user-activity gating.
- **LaunchServices** (`open codex://threads/<id>`) — navigate a window to a specific thread for the hidden sweep.

## Clicking strategy

For each window:

1. If the user has been idle long enough, run `AXScrollToVisible` on the Retry button (found by AX title/keyword).
2. Capture a screenshot, OCR it, and find the label center in window points.
3. Activate the app, raise the target window, verify `AXFocusedWindow` matches the target.
4. Re-capture and re-detect (layout may have shifted during activation).
5. Click, then reactivate the previously frontmost app (unless it was the ChatGPT app).

One click per window per cycle, with a cooldown per window title. If the click does not trigger a retry (observed
rarely when the first click only activates the window), the next cycle retries.

## Idle model

`HIDIdleTime` is reset by *any* HID event, including our synthetic `CGEvent`s, so it cannot be used directly after we
click. The daemon tracks `lastSyntheticAt` and `lastUserEventAt`. At each poll it reads `m = HIDIdleTime`:

- if `m + 0.4s < now - lastSyntheticAt`, the latest event happened after our last synthetic post, i.e. it was a real
  user event → `lastUserEventAt = now - m`;
- otherwise the latest event is our own synthetic post (or older), so the user idle estimate is unchanged.

User idle = `now - lastUserEventAt`. With idle < threshold the daemon only clicks the focused ChatGPT window (no
focus stealing); above the threshold it may raise other windows and restore focus afterwards.

## Hidden-session sweep

Failed sessions that are not displayed in any window have no rendered Retry button. Sweep:

1. Read the thread list (id, name, rollout path, updatedAt) from the app's local app-server through a read-only
   unix-socket WebSocket JSON-RPC client (`initialize` + `thread/list`). No writes.
2. For each thread updated within `sweep-recent-min` (default 120 min), read the last few lines of its rollout and
   check whether the last `task_complete` carries a capacity error and no newer `task_started` exists.
3. Skip threads already visible in a window (window title ≈ thread name; macOS truncates window titles, so compare a
   normalized 12-character prefix).
4. While the user is idle and at most once per `sweep-every` seconds, for each hidden failed thread:
   activate/raise a target window, `open codex://threads/<id>`, poll until the window title matches the thread,
   reveal + OCR + click Retry, then continue.
5. At the end, navigate the window back to the thread it showed before the sweep.

Per-thread cooldown (`sweep-cooldown`) prevents retrying the same session on every sweep.

## Permissions and TCC

The daemon is launched by the CLI from the user's terminal. macOS attributes the required TCC permissions
(Accessibility / "Device Control and Data Access", Screen Recording) to the **terminal application**, not to the
daemon binary. Consequences:

- Run `codex-retry` from a terminal that has both permissions.
- The daemon keeps working after the terminal window closes, as long as the terminal application process is alive.
- A user who installs the CLI and runs it from a different terminal must grant permissions to that terminal.

## Why not lcu / CUA / MCP

Those systems provide agent-facing computer-use APIs, but they either require a host agent to be installed or
explicitly refuse to control the ChatGPT app itself ("forbidden for safety reasons"). The retry click is a single,
well-defined UI action, so a small standalone tool with direct macOS APIs is simpler, has fewer moving parts, and
works for any agent or human that can run a shell command.

## Known limitations

- OCR depends on the localized button label; the keyword table covers common languages but a new UI language would
  need a keyword addition.
- The app version may change the AX tree, banner layout, or the app-server protocol; the code degrades gracefully
  (logs a skip) but retry automation may need an update.
- Only the capacity error case is handled (button-based retry).
