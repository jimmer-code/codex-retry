import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import IOKit
import Darwin

// ChatGPT capacity-error auto-retry daemon.
// Detection: the Retry button in the app's Accessibility tree (no screenshots, no OCR).
// Action: focus the button through Accessibility and send Return to the app process, which works while the
//         app stays in the background. If that fails and the user is idle, fall back to a real mouse click.
// Safety: Return is only sent after the button reports keyboard focus, so it can never submit a draft; while
//         the user is working in ChatGPT nothing is touched until they have been idle for a while.

let version = "1.1.0"
let codexBundleID = "com.openai.codex"
var args = Array(CommandLine.arguments.dropFirst())
if args.contains("--version") {
    print("codex-retry \(version)")
    exit(0)
}
if args.contains("--check") {
    let trusted = AXIsProcessTrusted()
    print(trusted ? "permission=ok" : "permission=missing")
    exit(trusted ? 0 : 3)
}
func flag(_ n: String) -> Bool { args.contains(n) }
func opt(_ n: String, _ def: String) -> String {
    if let a = args.first(where: { $0.hasPrefix("--\(n)=") }) { return String(a.split(separator: "=", maxSplits: 1).last!) }
    return def
}
let idleThreshold = Double(opt("idle", "10")) ?? 10
let clickCooldown = Double(opt("cooldown", "8")) ?? 8
let pollInterval = Double(opt("interval", "2")) ?? 2
let once = flag("--once")
let dryRun = flag("--dry-run")
let aggressiveAlways = flag("--aggressive")
let sweepEnabled = !flag("--no-sweep") && ProcessInfo.processInfo.environment["CODEX_RETRY_SWEEP"] != "0"
let sweepIdle = Double(opt("sweep-idle", "15")) ?? 15
let sweepEvery = Double(opt("sweep-every", "60")) ?? 60
let sweepCooldown = Double(opt("sweep-cooldown", "120")) ?? 120
let sweepRecentMin = Double(opt("sweep-recent-min", "120")) ?? 120
let sweepOnce = flag("--sweep-once")
let logPath = opt("log", "/tmp/codex-retry.log")

let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
func log(_ s: String) {
    let line = "[\(df.string(from: Date()))] \(s)"
    print(line); fflush(stdout)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); h.closeFile()
    } else {
        try? (line + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// ---------- user-activity tracking ----------
// HIDIdleTime is reset by our own synthetic mouse events (fallback clicks), so infer user idleness from it plus our own post times.
var lastSyntheticAt = Date(timeIntervalSinceNow: -3600)
var lastUserEventAt = Date(timeIntervalSinceNow: -30)
var activityInitialized = false
func hidIdleSeconds() -> Double {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &it) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(it) }
    let svc = IOIteratorNext(it)
    guard svc != 0 else { return 0 }
    defer { IOObjectRelease(svc) }
    guard let prop = IORegistryEntryCreateCFProperty(svc, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? UInt64 else { return 0 }
    return Double(prop) / 1_000_000_000.0
}
func updateUserActivity() {
    let now = Date()
    let m = hidIdleSeconds()
    if !activityInitialized { lastUserEventAt = now.addingTimeInterval(-m); activityInitialized = true; return }
    // latest event is ours only when idle <= time since our last synthetic post; otherwise a user event happened m ago
    if m + 0.4 < now.timeIntervalSince(lastSyntheticAt) { lastUserEventAt = now.addingTimeInterval(-m) }
}
func userIdleSeconds() -> Double { max(0, Date().timeIntervalSince(lastUserEventAt)) }


// ---------- Accessibility ----------
func axAttr(_ el: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil }
func axStr(_ el: AXUIElement, _ n: String) -> String? { axAttr(el, n) as? String }
func axBool(_ el: AXUIElement, _ n: String) -> Bool { axAttr(el, n) as? Bool ?? false }
func axKids(_ el: AXUIElement) -> [AXUIElement] { (axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axSet(_ el: AXUIElement, _ n: String, _ v: CFTypeRef) { AXUIElementSetAttributeValue(el, n as CFString, v) }
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pv = axAttr(el, kAXPositionAttribute), let sv = axAttr(el, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
func focusedWindow(_ app: AXUIElement) -> AXUIElement? { axAttr(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement } }

struct Win { let el: AXUIElement; let title: String }
func chatgptApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == codexBundleID }
}
var axEnabledFor: pid_t = 0
func chatgptAX(_ app: NSRunningApplication) -> AXUIElement {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    if axEnabledFor != app.processIdentifier {
        // Chromium-based apps build their full AX tree only once an assistive client asks for it.
        axSet(ax, "AXManualAccessibility", kCFBooleanTrue)
        axEnabledFor = app.processIdentifier
    }
    return ax
}
func appWindows(_ app: AXUIElement) -> [Win] {
    ((axAttr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).compactMap { w in
        guard axStr(w, kAXRoleAttribute) == kAXWindowRole as String else { return nil }
        return Win(el: w, title: axStr(w, kAXTitleAttribute) ?? "")
    }
}

// Localized labels of the retry button in the ChatGPT/Codex desktop UI.
let retryKeywords = [
    "重试", "重試", "retry", "try again",
    "再試行", "リトライ", "다시 시도", "재시도",
    "erneut versuchen", "wiederholen", "réessayer", "reessayer",
    "reintentar", "intentar de nuevo", "riprova", "ripeti",
    "tentar novamente", "повторить", "opnieuw proberen",
    "spróbuj ponownie", "yeniden dene", "tekrar dene",
]
// A button label is short: accept the keyword plus at most a couple of extra characters.
func isRetryLabel(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return retryKeywords.contains { t.contains($0) && t.count <= $0.count + 2 }
}
func findAll(_ el: AXUIElement, role: String, depth: Int = 0, _ match: (AXUIElement) -> Bool = { _ in true }) -> [AXUIElement] {
    guard depth < 60 else { return [] }
    var out: [AXUIElement] = []
    if axStr(el, kAXRoleAttribute) == role && match(el) { out.append(el) }
    for c in axKids(el) { out += findAll(c, role: role, depth: depth + 1, match) }
    return out
}
// The newest error, and so the live Retry button, is the bottom-most one.
func retryButton(in w: AXUIElement) -> AXUIElement? {
    findAll(w, role: kAXButtonRole as String) {
        isRetryLabel(axStr($0, kAXTitleAttribute) ?? "") || isRetryLabel(axStr($0, kAXDescriptionAttribute) ?? "")
    }.max { (axFrame($0)?.minY ?? 0) < (axFrame($1)?.minY ?? 0) }
}
func waitUntilGone(_ w: AXUIElement) -> Bool {
    for _ in 0..<10 {
        usleep(150_000)
        if retryButton(in: w) == nil { return true }
    }
    return false
}

// ---------- pressing ----------
// Background press: make the window the app's main window, give the button keyboard focus, and post Return
// to the app process. The app is not activated and the mouse is not moved.
func pressInBackground(_ b: AXUIElement, _ w: Win, _ app: NSRunningApplication, _ axApp: AXUIElement) -> Bool {
    let prevMain = focusedWindow(axApp)
    let composer = findAll(w.el, role: kAXTextAreaRole as String).first
    let composerFocused = composer.map { axBool($0, kAXFocusedAttribute) } ?? false
    defer {
        if composerFocused, let c = composer { axSet(c, kAXFocusedAttribute, kCFBooleanTrue) }
        if let p = prevMain, !CFEqual(p, w.el) { axSet(p, kAXMainAttribute, kCFBooleanTrue) }
    }
    axSet(w.el, kAXMainAttribute, kCFBooleanTrue)
    axSet(b, kAXFocusedAttribute, kCFBooleanTrue)
    usleep(150_000)
    // Return goes to whatever holds keyboard focus; never send it unless that is the button.
    guard axBool(b, kAXFocusedAttribute) else { log("  focus did not land on the button"); return false }
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)?.postToPid(app.processIdentifier)
        usleep(40_000)
    }
    return waitUntilGone(w.el)
}

func activate(_ app: NSRunningApplication) {
    DispatchQueue.main.async { app.activate(options: []) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.28))
}
// Fallback: bring the window forward and click the button's centre, then give focus back.
func clickButton(_ b: AXUIElement, _ w: Win, _ app: NSRunningApplication, _ axApp: AXUIElement, front: NSRunningApplication?) -> Bool {
    _ = AXUIElementPerformAction(b, "AXScrollToVisible" as CFString)
    usleep(300_000)
    activate(app)
    _ = AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
    axSet(w.el, kAXMainAttribute, kCFBooleanTrue)
    usleep(250_000)
    defer { if let front, front.bundleIdentifier != codexBundleID { activate(front) } }
    guard let fw = focusedWindow(axApp), CFEqual(fw, w.el) else { log("  skip: could not focus the window"); return false }
    guard let f = axFrame(b), let wf = axFrame(w.el), wf.contains(CGPoint(x: f.midX, y: f.midY)) else {
        log("  skip: button is outside the window"); return false
    }
    let p = CGPoint(x: f.midX, y: f.midY)
    lastSyntheticAt = Date()
    let src = CGEventSource(stateID: .hidSystemState)
    CGWarpMouseCursorPosition(p)
    usleep(70_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    return waitUntilGone(w.el)
}

// ---------- main loop ----------
var lastClickAt: [String: Date] = [:]

func retry(_ b: AXUIElement, _ w: Win, _ app: NSRunningApplication, _ axApp: AXUIElement,
           allowClick: Bool, front: NSRunningApplication?) -> Bool {
    let name = w.title.prefix(24)
    lastClickAt[w.title] = Date()
    if dryRun { log("retry (dry-run) title=\(name)"); return true }
    if pressInBackground(b, w, app, axApp) { log("retry (background) title=\(name)"); return true }
    guard allowClick else { log("skip title=\(name): background press failed; will click once the user is idle"); return false }
    if clickButton(b, w, app, axApp, front: front) { log("retry (click) title=\(name)"); return true }
    return false
}

func oneCycle() -> Int {
    updateUserActivity()
    guard let app = chatgptApp() else { return 0 }
    let axApp = chatgptAX(app)
    let front = NSWorkspace.shared.frontmostApplication
    let idle = aggressiveAlways || userIdleSeconds() >= idleThreshold
    // Moving keyboard focus would disturb someone typing in ChatGPT, so wait until they pause.
    if front?.bundleIdentifier == codexBundleID && !idle { return 0 }
    var clicks = 0
    for w in appWindows(axApp) {
        if let last = lastClickAt[w.title], Date().timeIntervalSince(last) < clickCooldown { continue }
        guard let b = retryButton(in: w.el) else { continue }
        if retry(b, w, app, axApp, allowClick: idle, front: front) { clicks += 1 }
    }
    return clicks
}

// ---------- hidden-session sweep ----------
// A session whose last turn failed with a capacity error but that is not shown in any window never
// exposes its Retry button to the clicker. While the user is idle we briefly open each such session
// through the codex:// deeplink, click Retry, then go back to what the window showed before.

// ---------- app-server client (read-only) ----------
// The desktop app maintains a local app-server daemon that speaks JSON-RPC over a unix-socket
// WebSocket. We only call initialize + thread/list, to map thread ids to titles and rollout paths.

struct ThreadInfo { let id: String; let name: String; let path: String; let updatedAt: Double? }

func appServerSocketPath() -> String? {
    let base = NSString(string: "~/.codex/app-server-control").expandingTildeInPath
    let direct = base + "/app-server-control.sock"
    if FileManager.default.fileExists(atPath: direct) { return direct }
    if let names = try? FileManager.default.contentsOfDirectory(atPath: base) {
        for n in names where n.hasSuffix(".sock") { return base + "/" + n }
    }
    return nil
}

final class AppServerClient {
    private let fd: Int32
    private var buffer = Data()
    private var nextId = 1

    init?(socketPath: String, timeout: TimeInterval = 8) {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let sockLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, sockLen)
            }
        }
        guard rc == 0 else { close(s); return nil }
        fd = s
        guard handshake() else { close(s); return nil }
    }

    deinit { close(fd) }

    private func writeAll(_ data: Data) -> Bool {
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                send(fd, raw.baseAddress!.advanced(by: written), data.count - written, 0)
            }
            if n <= 0 { return false }
            written += n
        }
        return true
    }

    private func readExact(_ n: Int) -> Data? {
        while buffer.count < n {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let got = recv(fd, &chunk, chunk.count, 0)
            if got <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<got])
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    private func handshake() -> Bool {
        let keyData = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = keyData.base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        guard writeAll(Data(request.utf8)) else { return false }
        var head = Data()
        while true {
            guard let one = readExact(1) else { return false }
            head.append(one)
            if head.count >= 4, head.suffix(4) == Data("\r\n\r\n".utf8) { break }
            if head.count > 16384 { return false }
        }
        let text = String(decoding: head, as: UTF8.self)
        return text.hasPrefix("HTTP/1.1 101") || text.contains(" 101 ")
    }

    private func sendFrame(_ text: String) {
        let payload = Data(text.utf8)
        var header = Data([0x81])
        let mask = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        if payload.count < 126 {
            header.append(UInt8(0x80 | payload.count))
        } else if payload.count < 65536 {
            header.append(0x80 | 126)
            var len = UInt16(payload.count).bigEndian
            header.append(Data(bytes: &len, count: 2))
        } else {
            header.append(0x80 | 127)
            var len = UInt64(payload.count).bigEndian
            header.append(Data(bytes: &len, count: 8))
        }
        header.append(mask)
        var masked = Data(capacity: payload.count)
        for (i, byte) in payload.enumerated() {
            masked.append(byte ^ mask[i % 4])
        }
        _ = writeAll(header + masked)
    }

    private func sendPong(_ payload: Data) {
        var header = Data([0x8A])
        if payload.count < 126 {
            header.append(UInt8(0x80 | payload.count))
        } else {
            header.append(0x80 | 126)
            var len = UInt16(payload.count).bigEndian
            header.append(Data(bytes: &len, count: 2))
        }
        let mask = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        header.append(mask)
        var masked = Data(capacity: payload.count)
        for (i, byte) in payload.enumerated() { masked.append(byte ^ mask[i % 4]) }
        _ = writeAll(header + masked)
    }

    /// Reads one complete (possibly fragmented) text message.
    private func readMessage() -> Data? {
        var message = Data()
        var started = false
        while true {
            guard let head = readExact(2) else { return nil }
            let fin = (head[0] & 0x80) != 0
            let opcode = head[0] & 0x0F
            let maskedBit = head[1] & 0x80
            var length = Int(head[1] & 0x7F)
            if length == 126 {
                guard let ext = readExact(2) else { return nil }
                length = Int(ext[0]) << 8 | Int(ext[1])
            } else if length == 127 {
                guard let ext = readExact(8) else { return nil }
                var value: UInt64 = 0
                for b in ext { value = value << 8 | UInt64(b) }
                length = Int(value)
            }
            var mask: Data? = nil
            if maskedBit != 0 {
                guard let m = readExact(4) else { return nil }
                mask = m
            }
            guard let payload = readExact(length) else { return nil }
            var data = payload
            if let mask = mask, !mask.isEmpty {
                var unmasked = Data(capacity: data.count)
                for (i, b) in data.enumerated() { unmasked.append(b ^ mask[i % 4]) }
                data = unmasked
            }
            switch opcode {
            case 0x9: sendPong(data); continue
            case 0x8: return nil
            case 0x1: message = data; started = true
            case 0x0: message.append(data)
            default: continue
            }
            if fin && started { return message }
        }
    }

    private func rpc(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        let id = nextId; nextId += 1
        let msg: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return nil }
        sendFrame(text)
        while true {
            guard let frame = readMessage(),
                  let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { return nil }
            if let rid = obj["id"] as? Int, rid == id {
                if obj["error"] != nil { return nil }
                return obj["result"] as? [String: Any] ?? [:]
            }
            // otherwise a notification; keep reading
        }
    }

    func threads(limit: Int = 100) -> [ThreadInfo]? {
        _ = rpc("initialize", ["clientInfo": ["name": "codex-retry", "version": version], "capabilities": [:]])
        guard let result = rpc("thread/list", ["limit": limit]),
              let data = result["data"] as? [[String: Any]] else { return nil }
        return data.compactMap { t in
            guard let id = t["id"] as? String, !id.isEmpty else { return nil }
            return ThreadInfo(id: id,
                              name: (t["name"] as? String) ?? "",
                              path: (t["path"] as? String) ?? "",
                              updatedAt: t["updatedAt"] as? Double)
        }
    }
}

func fetchThreads() -> [ThreadInfo]? {
    guard let path = appServerSocketPath(), let client = AppServerClient(socketPath: path) else { return nil }
    return client.threads()
}

func titleKey(_ s: String) -> String {
    // macOS truncates long window titles with an ellipsis in the middle, so compare a short prefix
    // after dropping ellipsis characters.
    let cleaned = s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
    return String(cleaned.prefix(12))
}
func titlesMatch(_ a: String, _ b: String) -> Bool {
    if a.isEmpty || b.isEmpty { return false }
    if a == b { return true }
    let ka = titleKey(a), kb = titleKey(b)
    return !ka.isEmpty && ka == kb
}

// Rollouts can grow to tens of MB, so only the tail is read.
func lastTurnFailedCapacity(_ path: String) -> Bool {
    guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    try? fh.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
    guard let data = try? fh.readToEnd(), !data.isEmpty else { return false }
    for line in data.split(separator: 0x0A).reversed().prefix(400) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let t = payload["type"] as? String else { continue }
        if t == "task_started" { return false }
        if t == "task_complete" {
            guard let err = payload["error"] as? [String: Any] else { return false }
            let info = ((err["codex_error_info"] as? String) ?? "").lowercased()
            let msg = ((err["message"] as? String) ?? "").lowercased()
            return info.contains("overload") || msg.contains("capacity")
        }
    }
    return false
}

func openThread(_ id: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["codex://threads/\(id)"]
    do { try p.run(); p.waitUntilExit() } catch { }
}


var lastSweepAt = Date(timeIntervalSinceNow: -3600)
var lastSweepClick: [String: Date] = [:]

func sweep(force: Bool = false) -> Int {
    guard sweepEnabled || force else { return 0 }
    updateUserActivity()
    let now = Date()
    if !force {
        guard aggressiveAlways || userIdleSeconds() >= sweepIdle else { return 0 }
        guard now.timeIntervalSince(lastSweepAt) >= sweepEvery else { return 0 }
    }
    guard let threads = fetchThreads(), !threads.isEmpty else { return 0 }
    lastSweepAt = now
    guard let app = chatgptApp() else { return 0 }
    let axApp = chatgptAX(app)
    let wins = appWindows(axApp)
    guard !wins.isEmpty else { return 0 }
    var hidden: [ThreadInfo] = []
    let nowTs = Date().timeIntervalSince1970
    for t in threads {
        if let u = t.updatedAt, sweepRecentMin > 0, nowTs - u > sweepRecentMin * 60 { continue }
        if !force, let cd = lastSweepClick[t.id], now.timeIntervalSince(cd) < sweepCooldown { continue }
        if wins.contains(where: { titlesMatch($0.title, t.name) }) { continue }
        guard lastTurnFailedCapacity(t.path) else { continue }
        hidden.append(t)
    }
    guard !hidden.isEmpty else { return 0 }
    let target = focusedWindow(axApp).flatMap { fw in wins.first { CFEqual($0.el, fw) } } ?? wins[0]
    let restore = threads.first { titlesMatch(target.title, $0.name) }
    let front = NSWorkspace.shared.frontmostApplication
    log("sweep: \(hidden.count) hidden failed session(s); using window \(target.title.prefix(24))")
    var clicked = 0
    for t in hidden.prefix(3) {
        log("sweep: open \(t.name.prefix(28))")
        if dryRun { clicked += 1; continue }
        // the deep link navigates the app's main window (and activates the app)
        axSet(target.el, kAXMainAttribute, kCFBooleanTrue)
        openThread(t.id)
        var button: AXUIElement? = nil
        var shown: Win? = nil
        for _ in 0..<15 {
            usleep(300_000)
            shown = appWindows(axApp).first { titlesMatch($0.title, t.name) }
            if let w = shown, let b = retryButton(in: w.el) { button = b; break }
        }
        guard let w = shown, let b = button else { log("sweep: no retry button after opening (will retry next sweep)"); continue }
        lastClickAt[w.title] = nil
        if retry(b, w, app, axApp, allowClick: true, front: nil) {
            clicked += 1
            lastSweepClick[t.id] = Date()
        }
    }
    if let r = restore, !dryRun {
        log("sweep: restore \(r.name.prefix(28))")
        axSet(target.el, kAXMainAttribute, kCFBooleanTrue)
        openThread(r.id)
        usleep(600_000)
    }
    if let front, front.bundleIdentifier != codexBundleID, !dryRun { activate(front) }
    return clicked
}

if flag("--list-threads") {
    guard let threads = fetchThreads() else { print("app-server unavailable"); exit(5) }
    for t in threads { print("\(t.id)\t\(t.name)\t\(t.path)") }
    exit(0)
}

log("retry_daemon \(version) start idle=\(Int(idleThreshold))s cooldown=\(Int(clickCooldown))s sweep=\(sweepEnabled) sweepIdle=\(Int(sweepIdle))s dryRun=\(dryRun) aggressiveAlways=\(aggressiveAlways)")
if sweepOnce {
    activityInitialized = true
    lastUserEventAt = Date(timeIntervalSinceNow: -3600)
    let n = sweep(force: true)
    log("sweep-once done clicked=\(n)")
} else if once {
    let n = oneCycle()
    log("cycle done clicks=\(n)")
} else {
    while true {
        _ = oneCycle()
        _ = sweep()
        Thread.sleep(forTimeInterval: pollInterval)
    }
}
