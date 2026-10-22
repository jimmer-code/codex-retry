# codex-retry

Auto-click the **Retry** button in the ChatGPT / Codex macOS desktop app when the model is at capacity.

When the desktop app shows `Selected model is at capacity. Please try a different model.` it only offers a manual
Retry button. `codex-retry` runs a small background daemon that clicks that button for you — for windows you can
see **and** for failed sessions that only exist in the sidebar — until the request gets through and your agent
continues working.

[中文说明](README.zh-CN.md)

## Why this exists

- The message is a server-side capacity response (`server_overloaded`). The app only retries automatically when the
  server returns a retry delay, which it does not for this error.
- The desktop app's local app-server cannot be used to retry from outside: while a chat is open the app holds that
  thread's writer lock (`already has an active writer`).
- That leaves the UI Retry button as the only reliable trigger — so this project finds and clicks it.

No lcu, no CUA, no MCP, no Python, no browser automation, no network calls.

## Features

- Finds the Retry button with **on-device Vision OCR**, after scrolling it into view through the Accessibility API.
- Clicks with synthesized mouse events (`CGEvent`), restores the previously focused app afterwards.
- Covers **hidden sidebar sessions**: while you are idle it opens each recently failed thread through the
  `codex://threads/<id>` deep link, clicks Retry, then returns to your previous view.
- **Idle-aware**: when you are actively using the Mac it only clicks the focused window; it only brings background
  windows forward after ~10 s of inactivity.
- Multi-window, multi-language UI, configurable timings, dry-run and debug helpers.

## Requirements

- macOS (tested on macOS 26 / 27, Apple Silicon).
- The ChatGPT desktop app, bundle id `com.openai.codex`.
- Xcode Command Line Tools to build the daemon: `xcode-select --install`.
- Two macOS permissions, granted to **the terminal app you run `codex-retry` from**:
  - **Accessibility** (newer macOS: "Device Control and Data Access") — to scroll and click buttons.
  - **Screen Recording** — to capture the window and locate the Retry button with OCR.

> Tip: any terminal that already has these permissions works. Other terminals will be prompted by
> `codex-retry start`, which opens the relevant System Settings pane.

## Install

From source:

```bash
git clone https://github.com/jiaweizhang1995/codex-retry.git
cd codex-retry
./install.sh
```

Or the one-liner (after the repository is published):

```bash
curl -fsSL https://raw.githubusercontent.com/jiaweizhang1995/codex-retry/main/install.sh | bash
```

The installer compiles the daemon, installs `~/.local/bin/codex-retry`, and stores the binary under
`~/.local/share/codex-retry/`.

## Usage

```bash
codex-retry           # toggle: start if stopped, stop if running
codex-retry status    # status, permissions, recent log lines
codex-retry log       # follow the log (Ctrl-C to quit)
codex-retry doctor    # self-check
codex-retry sweep     # process hidden failed sessions once, right now
codex-retry threads   # debug: threads known to the local app-server
codex-retry start / stop / restart
```

Run `codex-retry` once to start the background daemon; run it again to stop it. The daemon keeps working after the
terminal window is closed as long as the host app / terminal process is still alive (it inherits the terminal's
permissions).

## Configuration

All settings are environment variables; defaults are sensible.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CODEX_RETRY_LANG` | system locale | CLI language (`en` or `zh`) |
| `CODEX_RETRY_IDLE` | `10` | seconds of user idle before clicking background windows |
| `CODEX_RETRY_COOLDOWN` | `8` | minimum seconds between clicks in the same window |
| `CODEX_RETRY_INTERVAL` | `2` | scan interval in seconds |
| `CODEX_RETRY_SWEEP` | `1` | set to `0` to disable hidden-session retries |
| `CODEX_RETRY_SWEEP_IDLE` | `15` | idle seconds before a sweep starts |
| `CODEX_RETRY_SWEEP_EVERY` | `60` | minimum seconds between sweeps |
| `CODEX_RETRY_SWEEP_COOLDOWN` | `120` | per-session cooldown between hidden retries |
| `CODEX_RETRY_SWEEP_RECENT_MIN` | `120` | only sweep sessions updated within this many minutes |

## How it works

1. Enumerate ChatGPT windows with CoreGraphics.
2. Locate the Retry button: Accessibility `AXScrollToVisible` brings it into view, then a window screenshot is
   recognised locally with Vision OCR to get exact coordinates of the `重试` / `Retry` label.
3. Click it with a synthesized mouse event: activate the app, raise the window, verify focus, click, then restore the
   previously focused app.
4. Idle tracking: `HIDIdleTime` is reset by our own synthetic clicks, so the daemon tracks its own events and derives
   real user idleness from that.
5. Hidden sessions: read the thread list from the desktop app's local app-server (read-only unix-socket WebSocket
   JSON-RPC), check each thread's last turn in its rollout file, open failed threads via `codex://threads/<id>`,
   click Retry, and navigate back.

## Supported UI languages

Chinese (Simplified/Traditional), English, Japanese, Korean, German, French, Spanish, Italian, Portuguese, Russian,
Dutch, Polish, Turkish. OCR uses the system language plus English; extra languages can be passed to the daemon with
`--languages=zh-Hans,en-US`.

## Privacy & security

- Window screenshots are captured locally, processed on-device with Vision OCR, and discarded. Nothing is uploaded.
- The daemon has no networking code. It talks only to macOS APIs and the local app-server unix socket.
- It only activates the ChatGPT app and only clicks retry buttons.
- Unofficial project, not affiliated with OpenAI. Review the code before running; UI changes in the app may break
  detection.

## Limitations

- Only capacity errors that expose a Retry button can be retried.
- macOS only; the desktop app must stay open.
- The hidden-session sweep briefly switches the focused window while you are idle (can be disabled).
- App UI changes can break the OCR/AX selectors.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `accessibility: missing` | Grant Accessibility to the terminal app (System Settings › Privacy & Security). |
| `screen recording: missing` | Grant Screen Recording to the same terminal app. |
| No clicks at all | `codex-retry doctor`, then `codex-retry log`; try `codex-retry sweep`. |
| Still nothing | The app version may have changed the UI; open an issue with your macOS + app version. |

## Development

- `src/retry_daemon.swift` — daemon (window discovery, AX, Vision OCR, clicks, idle tracking, sweep, app-server client).
- `bin/codex-retry` — CLI wrapper.
- `install.sh`, `uninstall.sh`.
- `.github/workflows/build.yml` compiles on macOS; tagging `v*` builds a universal binary release.
- `dev/` holds debugging tools used while developing and is not part of the published package.

Build manually:

```bash
swiftc -O src/retry_daemon.swift -o retry_daemon
```

## License

[MIT](LICENSE)
