# Investigation notes (2026-10-22)

Evidence collected while diagnosing the "Selected model is at capacity" loop in the ChatGPT/Codex desktop app.
Useful for maintainers and for future issue reports.

## The error

Rollout files under `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` contain a `task_complete` event:

```json
{"type":"event_msg","payload":{
  "type":"task_complete",
  "error":{"message":"Selected model is at capacity. Please try a different model.",
           "codex_error_info":"server_overloaded"}
}}
```

Retry turns started by clicking the UI Retry button carry `turn_attribution.turn_trigger` values:

- `capacity_retry_manual` — a human clicked Retry (the common case),
- `capacity_retry_automatic` — the app's own capacity retry, only seen when the server supplies a retry delay.

The error above has no retry-delay hint (`additionalDetails: null`), so the app never auto-retries it; the UI only
shows the manual Retry button.

## Session configuration at the time

`~/.codex/config.toml`:

```toml
model = "gpt-6-astra"
model_reasoning_effort = "max"
service_tier = "priority"        # "Fast" 2x-speed tier in the model picker
```

The account was not rate-limited (`account/rateLimits/read`: plan `prolite`, 51% of the weekly window used,
credits available, `ordinaryUsageAllowed: true`), confirming this is model/tier capacity, not quota.

## Why the local app-server cannot retry

The ChatGPT app maintains a managed app-server daemon:

```
codex app-server --remote-control --listen unix:// --managed-daemon
```

Its control socket is `~/.codex/app-server-control/app-server-control.sock` (a symlink to
`/private/tmp/codex-daemon-501/<hash>`). It speaks WebSocket + JSON-RPC; `initialize`, `thread/list`,
`thread/read`, `thread/turns/list`, `turn/start` etc. are all available.

However, the desktop app's own app-server holds a writer lock for every loaded thread
(`~/.codex/thread-writer-locks/<thread-id>.lock`). Resuming such a thread on the daemon fails:

```json
{"id":2,"error":{"code":-32600,"message":"thread <id> already has an active writer"}}
```

So writing/retrying from outside the UI is not possible without closing the app, which defeats the purpose.

## UI details relevant to the clicker

- Bundle id: `com.openai.codex`; window owner name is `ChatGPT`.
- The Retry button is an `AXButton` whose AXTitle is the localized label (`重试` for zh, `Retry` for en, …).
  It exposes only `AXShowMenu` / `AXScrollToVisible` actions (no `AXPress`), so a coordinate click is required.
- When the transcript has many failed attempts, the Retry button can be below the fold;
  `AXScrollToVisible` scrolls it into view.
- macOS truncates long window titles with a middle ellipsis, which is why thread↔window matching compares a
  normalized short prefix rather than the full title.
- The app has no command or keyboard shortcut for Retry, and no `codex://` deep link action for it; the deep link
  `codex://threads/<id>` can only navigate windows (used by the hidden-session sweep).

## Test environment

- macOS 26.x (also used on macOS 27 dev builds), Apple Silicon.
- ChatGPT desktop app 26.1016.61520 (bundle `com.openai.codex`), Codex CLI 0.163.0-alpha.11.1.
- Daemon verified against multi-window setups and conversations failed for several hours.
