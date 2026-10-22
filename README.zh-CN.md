# codex-retry

> **Selected model is at capacity. Please try a different model.**

如果这句话总在打断你的 ChatGPT / Codex 桌面端，这个小工具就是为你做的。这个报错 App 不会自己重试，
agent 只能停在那儿等你回来点「重试」。点完过一会儿，又来了。

`codex-retry` 在后台替你点。不抢焦点、不动鼠标，你干你的（或者去睡觉），agent 接着跑。

[English](README.md)

## 让你的 agent 帮你装

把下面这段话发给 Claude Code、Codex 或你在用的任何 agent：

```text
帮我安装 codex-retry（https://github.com/jimmer-code/codex-retry）：
1. 运行：curl -fsSL https://raw.githubusercontent.com/jimmer-code/codex-retry/main/install.sh | bash
2. 运行：~/.local/bin/codex-retry start
3. 如果提示缺少「辅助功能」权限，请让我给你当前运行所在的 App 打开辅助功能
   （系统设置 → 隐私与安全性 → 辅助功能），等我确认后再执行第 2 步。
4. 运行 ~/.local/bin/codex-retry status，把结果给我看。
```

## 或者自己装

```bash
curl -fsSL https://raw.githubusercontent.com/jimmer-code/codex-retry/main/install.sh | bash
codex-retry          # 开 / 关
codex-retry status   # 在不在跑、权限好不好、最近重试记录
```

需要 macOS 12+、ChatGPT 桌面端，以及给终端开「辅助功能」权限（第一次运行会自动打开设置页）。
卸载：`codex-retry uninstall`。

## 原理

- 通过 macOS 辅助功能找到「重试」按钮。不截图，不做 OCR。
- 把焦点给按钮，再直接向 ChatGPT 进程发回车，App 可以一直待在后台。只有按钮真的拿到焦点才会发回车，
  不会把你写了一半的草稿发出去。
- 万一不生效，就等你空闲时点一下按钮，再把焦点还给你。
- 没在任何窗口打开的失败会话也能处理（只读访问 App 本地的 app-server），同样只在你空闲时进行。
- 不联网，数据不出你的 Mac。

配置项（环境变量）、设计说明和排查过程：[docs/DESIGN.md](docs/DESIGN.md)、[docs/FINDINGS.md](docs/FINDINGS.md)。

非官方项目，与 OpenAI 无关。App 更新后如果失效，欢迎提 issue。

## 许可证

[MIT](LICENSE)
