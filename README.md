# codex-retry

> **Selected model is at capacity. Please try a different model.**

If that line keeps interrupting your ChatGPT / Codex desktop app, this is for you. The app won't retry this error on
its own, so your agent just sits there until you come back and click **Retry**. Again. And again.

`codex-retry` clicks it for you, in the background. It doesn't steal focus or move your mouse, so you can keep working
(or go to sleep) while your agents keep going.

[中文说明](README.zh-CN.md)

## Let your agent install it

Paste this into Claude Code, Codex, or whatever agent you use:

```text
Install codex-retry for me (https://github.com/jimmer-code/codex-retry):
1. Run: curl -fsSL https://raw.githubusercontent.com/jimmer-code/codex-retry/main/install.sh | bash
2. Run: ~/.local/bin/codex-retry start
3. If it says the Accessibility permission is missing, ask me to enable Accessibility for the app you are
   running in (System Settings → Privacy & Security → Accessibility), wait until I confirm, then run step 2 again.
4. Run ~/.local/bin/codex-retry status and show me the result.
```

## Or do it yourself

```bash
curl -fsSL https://raw.githubusercontent.com/jimmer-code/codex-retry/main/install.sh | bash
codex-retry          # on / off toggle
codex-retry status   # is it running? permissions OK? recent retries
```

You need macOS 12+, the ChatGPT desktop app, and **Accessibility** permission for your terminal (the first run opens
the right settings page). Uninstall with `codex-retry uninstall`.

## How it works

- Finds the Retry button through macOS Accessibility. No screenshots, no OCR.
- Focuses the button and sends Return straight to the ChatGPT process, so the app can stay in the background. Return
  is only sent once the button really has focus, so it can't send a half-written draft.
- If that doesn't work, it waits until you're idle, clicks the button, and gives focus back.
- It also catches failed chats that aren't open in any window (via the app's local app-server, read-only), while
  you're idle.
- No network calls, nothing leaves your Mac.

Settings (env vars), design notes and the debugging story: [docs/DESIGN.md](docs/DESIGN.md),
[docs/FINDINGS.md](docs/FINDINGS.md).

Unofficial and not affiliated with OpenAI. If an app update breaks it, please open an issue.

## License

[MIT](LICENSE)
