# codex-retry

自动点击 ChatGPT / Codex macOS 桌面端的「重试」按钮，解决模型满载报错。

桌面端出现 `Selected model is at capacity. Please try a different model.` 时，只提供一个手动「重试」按钮。
`codex-retry` 会在后台运行一个小 daemon，帮你点这个按钮——无论是你能看到的窗口，还是只存在于侧边栏里的
失败会话——直到请求成功、agent 继续干活。

[English README](README.md)

## 为什么需要它

- 这个报错是服务端容量不足（`server_overloaded`）。App 只有在服务端返回 retry delay 时才会自动重试，
  而这条错误没有返回 delay。
- 桌面端本地的 app-server 无法从外部触发重试：会话打开时 App 持有该 thread 的 writer 锁
  （`already has an active writer`）。
- 所以 UI 上的「重试」按钮是唯一可靠的触发方式——本项目负责找到并点击它。

不需要 lcu、不需要 CUA、不需要 MCP、不需要 Python、不涉及浏览器自动化、不联网。

## 功能

- 用**本地 Vision OCR** 识别「重试」按钮；按钮不在可视区时先通过 Accessibility API 的 `AXScrollToVisible`
  滚进可视区再识别。
- 用合成的鼠标事件（`CGEvent`）点击，点完把焦点还给原来的 App。
- **覆盖侧边栏里的隐藏会话**：用户空闲时，通过 `codex://threads/<id>` 深链临时打开最近失败的会话、
  点重试、再切回原来的视图。
- **感知用户活动**：你在用电脑时只点当前焦点窗口；空闲约 10 秒后才把后台窗口抬起来操作。
- 多窗口、多语言 UI、可配置节奏，附带 dry-run 和调试命令。

## 环境要求

- macOS（在 macOS 26 / 27、Apple Silicon 上测试）。
- ChatGPT 桌面端，bundle id 为 `com.openai.codex`。
- 编译 daemon 需要 Xcode Command Line Tools：`xcode-select --install`。
- 给**运行 `codex-retry` 的终端 App** 授予两个权限：
  - **辅助功能**（新系统叫「设备控制和数据访问」）——用来滚动和点击按钮。
  - **屏幕录制**——用来截取窗口、用 OCR 定位「重试」按钮。

> 提示：任何已获得这两个权限的终端都可以。没有授权的终端执行 `codex-retry start` 时会提示，
> 并自动打开对应的系统设置页面。

## 安装

从源码：

```bash
git clone https://github.com/jiaweizhang1995/codex-retry.git
cd codex-retry
./install.sh
```

或者一行命令（仓库发布后可用）：

```bash
curl -fsSL https://raw.githubusercontent.com/jiaweizhang1995/codex-retry/main/install.sh | bash
```

安装脚本会编译 daemon，把命令装到 `~/.local/bin/codex-retry`，程序放在 `~/.local/share/codex-retry/`。

## 使用

```bash
codex-retry           # 开关：没运行就启动；正在运行就停止
codex-retry status    # 状态、权限、最近日志
codex-retry log       # 跟踪日志（Ctrl-C 退出）
codex-retry doctor    # 自检
codex-retry sweep     # 立即处理一次隐藏的失败会话
codex-retry threads   # 调试：列出本地 app-server 的会话
codex-retry start / stop / restart
```

运行一次 `codex-retry` 启动后台 daemon，再运行一次即关闭。终端窗口关闭后 daemon 仍会继续工作
（它继承的是终端 App 的权限），直到终端 App 退出或手动停止。

## 配置

全部通过环境变量配置，默认值即可直接用。

| 变量 | 默认 | 含义 |
| --- | --- | --- |
| `CODEX_RETRY_LANG` | 跟随系统 | CLI 语言（`en` / `zh`） |
| `CODEX_RETRY_IDLE` | `10` | 用户空闲多少秒后才点后台窗口 |
| `CODEX_RETRY_COOLDOWN` | `8` | 同一窗口两次点击的最小间隔秒数 |
| `CODEX_RETRY_INTERVAL` | `2` | 扫描间隔秒数 |
| `CODEX_RETRY_SWEEP` | `1` | 设为 `0` 关闭「隐藏会话」自动重试 |
| `CODEX_RETRY_SWEEP_IDLE` | `15` | 开始扫描隐藏会话前的空闲秒数 |
| `CODEX_RETRY_SWEEP_EVERY` | `60` | 两次扫描的最小间隔秒数 |
| `CODEX_RETRY_SWEEP_COOLDOWN` | `120` | 同一隐藏会话两次重试的最小间隔秒数 |
| `CODEX_RETRY_SWEEP_RECENT_MIN` | `120` | 只处理最近多少分钟内更新过的隐藏会话 |

## 工作原理

1. 用 CoreGraphics 枚举 ChatGPT 窗口。
2. 定位「重试」按钮：先 Accessibility `AXScrollToVisible` 让它可见，再截窗口图用本地 Vision OCR
   找出「重试 / Retry」文字的精确坐标。
3. 用合成鼠标事件点击：激活 App、抬升窗口、校验焦点、点击，最后把焦点还给原来的 App。
4. 用户空闲检测：系统 `HIDIdleTime` 会被我们自己的合成点击重置，所以 daemon 单独记录自己发过的
   合成事件，用差分推算真实用户空闲时间。
5. 隐藏会话：从桌面端本地 app-server（只读的 unix socket WebSocket JSON-RPC）读取会话列表，
   读取每个会话 rollout 的最后回合状态；对失败的会话用 `codex://threads/<id>` 打开、点重试、再切回。

## 支持的界面语言

简体/繁体中文、英文、日文、韩文、德文、法文、西班牙文、意大利文、葡萄牙文、俄文、荷兰文、波兰文、土耳其文。
OCR 默认使用系统语言加英文，也可以给 daemon 传 `--languages=zh-Hans,en-US` 指定。

## 隐私与安全

- 窗口截图只在本地截取、本地 Vision OCR 处理，处理后即丢弃，不会上传。
- daemon 没有任何网络代码，只调用 macOS API 和本地 app-server 的 unix socket。
- 只会激活 ChatGPT App，且只会点击「重试」按钮。
- 非官方项目，与 OpenAI 无关。运行前请自行审阅代码；App 改版可能导致识别失效。

## 限制

- 只能重试会显示「重试」按钮的容量类错误。
- 仅支持 macOS，且桌面端必须保持运行。
- 用户空闲时，隐藏会话扫描会短暂切换前台窗口（可关闭）。
- App 的 UI 改版可能让 OCR/AX 选择器失效。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| `accessibility: missing` | 给终端 App 打开「辅助功能」（系统设置 › 隐私与安全性）。 |
| `screen recording: missing` | 给同一个终端 App 打开「屏幕录制」。 |
| 完全不点 | 先 `codex-retry doctor`，再看 `codex-retry log`，或试 `codex-retry sweep`。 |
| 还是不点 | App 可能改版了，请带上 macOS 和 App 版本提 issue。 |

## 开发

- `src/retry_daemon.swift` — daemon（窗口发现、AX、Vision OCR、点击、空闲检测、隐藏会话扫描、app-server 客户端）。
- `bin/codex-retry` — CLI 包装。
- `install.sh`、`uninstall.sh`。
- `.github/workflows/build.yml` 在 macOS 上编译检查；打 `v*` tag 会构建通用二进制 Release。
- `dev/` 是开发期调试工具，不随包发布。

手动编译：

```bash
swiftc -O src/retry_daemon.swift -o retry_daemon
```

## 许可证

[MIT](LICENSE)
