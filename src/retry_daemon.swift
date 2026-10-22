import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import IOKit
import Vision
import Darwin

// ChatGPT capacity-error auto-retry daemon.
// Detection: window screenshot + Vision OCR for "重试"/"Retry"/"Try again" (only visible buttons count).
// Action: raise the window, click the button with a synthetic HID event, then restore the previous app.
// Safety: while the user is actively using the Mac (< idleThreshold), only the focused ChatGPT window is clicked,
//         so focus is never stolen from another app.

var args = Array(CommandLine.arguments.dropFirst())
if args.contains("--version") {
    print("codex-retry 1.0.0")
    exit(0)
}
if args.contains("--check") {
    let trusted = AXIsProcessTrusted()
    print(trusted ? "permission=ok" : "permission=missing")
    exit(trusted ? 0 : 3)
}
if args.contains("--once") { } // no-op clarity: single cycle mode parsed below
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

// OCR languages: honour --languages=..., otherwise use the system language plus English.
func preferredOCRLanguages() -> [String] {
    if let a = args.first(where: { $0.hasPrefix("--languages=") }) {
        let list = a.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
        let parsed = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !parsed.isEmpty { return parsed }
    }
    var langs: [String] = []
    if let pref = Locale.preferredLanguages.first, !pref.isEmpty {
        let parts = pref.split(separator: "-")
        if parts.count >= 2 { langs.append("\(parts[0])-\(parts[1])") } else { langs.append(pref) }
    }
    if !langs.contains("en-US") { langs.append("en-US") }
    return Array(Set(langs))
}
let ocrLanguages = preferredOCRLanguages()
let logPath = opt("log", "/tmp/codex-retry.log")
let tmpDir = "/tmp/chatgpt_retry_daemon"
try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

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
// HIDIdleTime is reset by our own synthetic mouse events, so infer user idleness from it plus our own post times.
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

// ---------- windows ----------
struct CgWindow { let id: Int; let pid: pid_t; let title: String; let x: Double; let y: Double; let w: Double; let h: Double }
func chatgptWindows() -> [CgWindow] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [CgWindow] = []
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String) == "ChatGPT",
              (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let ww = (b["Width"] as? NSNumber)?.doubleValue ?? 0
        let hh = (b["Height"] as? NSNumber)?.doubleValue ?? 0
        if ww < 200 || hh < 200 { continue }
        out.append(CgWindow(id: w[kCGWindowNumber as String] as? Int ?? 0,
                            pid: w[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                            title: w[kCGWindowName as String] as? String ?? "",
                            x: (b["X"] as? NSNumber)?.doubleValue ?? 0,
                            y: (b["Y"] as? NSNumber)?.doubleValue ?? 0, w: ww, h: hh))
    }
    return out
}
func chatgptApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.openai.codex" }
}

// ---------- AX raise ----------
func axAttr(_ el: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil }
func axStr(_ el: AXUIElement, _ n: String) -> String? { axAttr(el, n) as? String }
func axKids(_ el: AXUIElement) -> [AXUIElement] { (axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axPoint(_ el: AXUIElement) -> CGPoint? { guard let v = axAttr(el, kAXPositionAttribute) else { return nil }; var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p }
func axSize(_ el: AXUIElement) -> CGSize? { guard let v = axAttr(el, kAXSizeAttribute) else { return nil }; var s = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &s); return s }
func axWindows(_ app: AXUIElement) -> [AXUIElement] { (axAttr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func focusedWindow(_ app: AXUIElement) -> AXUIElement? { guard let v = axAttr(app, kAXFocusedWindowAttribute) else { return nil }; return (v as! AXUIElement) }
func sameWindow(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

func raise(matching cg: CgWindow) -> Bool {
    guard let app = chatgptApp() else { return false }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    for w in axWindows(axApp) {
        guard let title = axStr(w, kAXTitleAttribute), let p = axPoint(w), let s = axSize(w) else { continue }
        if abs(p.x - cg.x) < 2.5 && abs(p.y - cg.y) < 2.5 && abs(s.width - cg.w) < 2.5 && abs(s.height - cg.h) < 2.5 {
            _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = title
            return true
        }
    }
    // fall back: match by title prefix + same size
    for w in axWindows(axApp) {
        guard let title = axStr(w, kAXTitleAttribute), let s = axSize(w), let p = axPoint(w) else { continue }
        if abs(s.width - cg.w) < 2.5 && abs(s.height - cg.h) < 2.5 && (title == cg.title || cg.title.hasPrefix(String(title.prefix(20)))) && abs(p.y - cg.y) < 2.5 {
            _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return true
        }
    }
    return false
}
func axWindowFor(_ cg: CgWindow) -> AXUIElement? {
    guard let app = chatgptApp() else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    for w in axWindows(axApp) {
        guard let p = axPoint(w), let s = axSize(w) else { continue }
        if abs(p.x - cg.x) < 2.5 && abs(p.y - cg.y) < 2.5 && abs(s.width - cg.w) < 2.5 && abs(s.height - cg.h) < 2.5 { return w }
    }
    return nil
}
func findRetryButton(_ el: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
    guard depth < 60 else { return nil }
    if axStr(el, kAXRoleAttribute) == kAXButtonRole as String {
        let t = "\(axStr(el, kAXTitleAttribute) ?? "") \(axStr(el, kAXDescriptionAttribute) ?? "")"
        if t.contains("重试") || t.lowercased().contains("retry") { return el }
    }
    for c in axKids(el) { if let r = findRetryButton(c, depth + 1) { return r } }
    return nil
}
func revealRetryButton(_ cg: CgWindow) -> Bool {
    guard let w = axWindowFor(cg), let b = findRetryButton(w) else { return false }
    _ = AXUIElementPerformAction(b, "AXScrollToVisible" as CFString)
    usleep(350_000)
    return true
}

func activate(_ app: NSRunningApplication) {
    DispatchQueue.main.async { app.activate(options: []) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.28))
}
func clickAt(_ p: CGPoint) {
    lastSyntheticAt = Date()
    let src = CGEventSource(stateID: .hidSystemState)
    CGWarpMouseCursorPosition(p)
    usleep(70_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
}

// ---------- OCR detection ----------
var captureWarningLogged = false
func capture(_ winID: Int, _ path: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-l", String(winID), "-o", "-x", path]
    do { try p.run(); p.waitUntilExit() } catch { return false }
    if p.terminationStatus != 0 {
        if !captureWarningLogged {
            captureWarningLogged = true
            log("screencapture failed — grant Screen Recording permission to the terminal app running codex-retry")
        }
        return false
    }
    return true
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
func isRetryLabel(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.isEmpty { return false }
    for k in retryKeywords where t.contains(k) { return true }
    return false
}
func ocrRetryPoints(imagePath: String, win: CgWindow) -> [CGPoint] {
    guard let img = NSImage(contentsOfFile: imagePath), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
    let pxW = Double(cg.width), pxH = Double(cg.height)
    guard pxW > 0, pxH > 0 else { return [] }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = ocrLanguages
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([req])) != nil else { return [] }
    var pts: [CGPoint] = []
    for obs in (req.results ?? []) {
        guard let top = obs.topCandidates(1).first, isRetryLabel(top.string) else { continue }
        let box = obs.boundingBox
        let cx = (box.origin.x + box.size.width / 2) * pxW * (win.w / pxW)
        let cy = (1.0 - box.origin.y - box.size.height / 2) * pxH * (win.h / pxH)
        pts.append(CGPoint(x: win.x + cx, y: win.y + cy))
    }
    return pts
}

// ---------- main loop ----------
var lastClickAt: [String: Date] = [:]

func performClick(_ win: CgWindow, aggressive: Bool, front: NSRunningApplication?) -> Bool {
    guard let app = chatgptApp() else { return false }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    let key = win.title
    if let last = lastClickAt[key], Date().timeIntervalSince(last) < clickCooldown { return false }
    if aggressive { _ = revealRetryButton(win) }
    let path = "\(tmpDir)/win_\(win.id).png"
    guard capture(win.id, path) else { return false }
    let pts = ocrRetryPoints(imagePath: path, win: win)
    guard let p = pts.first else { return false }
    log("click \(aggressive ? "(user idle \(Int(userIdleSeconds()))s)" : "(front)") title=\(win.title.prefix(20)) at (\(Int(p.x)),\(Int(p.y)))")
    if dryRun { lastClickAt[key] = Date(); return true }
    let restore = (front != nil && front!.bundleIdentifier != "com.openai.codex") ? front : nil
    activate(app)
    if !raise(matching: win) { log("  skip: could not raise target window"); return false }
    usleep(250_000)
    let fw = focusedWindow(axApp)
    let focusedOK = fw.map { fwEl -> Bool in
        guard let fp = axPoint(fwEl), let fs = axSize(fwEl) else { return false }
        return abs(fp.x - win.x) <= 2 && abs(fp.y - win.y) <= 2 && abs(fs.width - win.w) <= 2.5 && abs(fs.height - win.h) <= 2.5
    } ?? false
    if !focusedOK { log("  skip: focus check failed"); return false }
    let path2 = "\(tmpDir)/win_\(win.id)_after.png"
    var livePoint: CGPoint? = nil
    if capture(win.id, path2) {
        let pts2 = ocrRetryPoints(imagePath: path2, win: win)
        livePoint = pts2.min { abs($0.y - p.y) < abs($1.y - p.y) } ?? pts2.first
    }
    guard let lp = livePoint else { log("  skip: button no longer visible after activation"); return false }
    clickAt(lp)
    usleep(500_000)
    lastClickAt[key] = Date()
    if let restore { activate(restore) }
    return true
}

func oneCycle() -> Int {
    updateUserActivity()
    let wins = chatgptWindows()
    if wins.isEmpty { return 0 }
    guard let app = chatgptApp() else { return 0 }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    let front = NSWorkspace.shared.frontmostApplication
    let chatgptFront = front?.bundleIdentifier == "com.openai.codex"
    let idle = userIdleSeconds()
    let aggressive = aggressiveAlways || idle >= idleThreshold
    let focused = focusedWindow(axApp)
    var clicks = 0
    for win in wins {
        let key = win.title
        if let last = lastClickAt[key], Date().timeIntervalSince(last) < clickCooldown { continue }
        let isFocused: Bool = {
            guard let fw = focused else { return false }
            guard let p = axPoint(fw), let s = axSize(fw) else { return false }
            return abs(p.x - win.x) < 2.5 && abs(p.y - win.y) < 2.5 && abs(s.width - win.w) < 2.5 && abs(s.height - win.h) < 2.5
        }()
        if !aggressive {
            guard chatgptFront && isFocused else { continue }
        }
        if performClick(win, aggressive: aggressive, front: front) { clicks += 1 }
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
            guard let maskedBit = Optional(head[1] & 0x80) else { return nil }
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
                if let err = obj["error"] as? [String: Any] {
                    _ = err
                    return nil
                }
                return obj["result"] as? [String: Any] ?? [:]
            }
            // otherwise a notification; keep reading
        }
    }

    func threads(limit: Int = 100) -> [ThreadInfo]? {
        _ = rpc("initialize", ["clientInfo": ["name": "codex-retry", "version": "1.0"], "capabilities": [:]])
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

func lastTurnFailedCapacity(_ path: String) -> Bool {
    guard !path.isEmpty,
          let data = FileManager.default.contents(atPath: path),
          !data.isEmpty else { return false }
    let lines = data.split(separator: 0x0A)
    var seen = 0
    for line in lines.reversed() {
        seen += 1
        if seen > 400 { break }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let t = payload["type"] as? String else { continue }
        if t == "task_started" { return false }
        if t == "task_complete" {
            guard let err = payload["error"] as? [String: Any] else { return false }
            let info = ((err["codex_error_info"] as? String) ?? "").lowercased()
            let msg = ((err["message"] as? String) ?? "").lowercased()
            return info.contains("overload") || msg.contains("at capacity") || msg.contains("capacity")
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
    let wins = chatgptWindows()
    guard !wins.isEmpty, let app = chatgptApp() else { return 0 }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var hidden: [ThreadInfo] = []
    let nowTs = Date().timeIntervalSince1970
    for t in threads {
        guard lastTurnFailedCapacity(t.path) else { continue }
        if let u = t.updatedAt, sweepRecentMin > 0, nowTs - u > sweepRecentMin * 60 { continue }
        if !force, let cd = lastSweepClick[t.id], now.timeIntervalSince(cd) < sweepCooldown { continue }
        if wins.contains(where: { titlesMatch($0.title, t.name) }) { continue }
        hidden.append(t)
    }
    guard !hidden.isEmpty else { return 0 }
    var target = wins[0]
    if let fw = focusedWindow(axApp), let fp = axPoint(fw), let fs = axSize(fw) {
        target = wins.first { w in
            abs(w.x - fp.x) < 2.5 && abs(w.y - fp.y) < 2.5 && abs(w.w - fs.width) < 2.5 && abs(w.h - fs.height) < 2.5
        } ?? target
    }
    let restore = threads.first { titlesMatch(target.title, $0.name) }
    log("sweep: \(hidden.count) hidden failed session(s); using window \(target.title.prefix(24))")
    var clicked = 0
    for t in hidden.prefix(3) {
        log("sweep: open \(t.name.prefix(28))")
        if dryRun { clicked += 1; continue }
        activate(app)
        _ = raise(matching: target)
        usleep(300_000)
        openThread(t.id)
        var shown: CgWindow? = nil
        for _ in 0..<12 {
            usleep(300_000)
            if let w = chatgptWindows().first(where: { titlesMatch($0.title, t.name) }) { shown = w; break }
        }
        guard let win = shown else { log("sweep: window did not navigate in time"); continue }
        usleep(400_000)
        lastClickAt[win.title] = nil
        if performClick(win, aggressive: true, front: nil) {
            clicked += 1
            lastSweepClick[t.id] = Date()
            log("sweep: retried \(t.name.prefix(28))")
        } else {
            log("sweep: no retry button after opening (will retry next sweep)")
        }
        usleep(400_000)
    }
    if let r = restore, !dryRun {
        log("sweep: restore \(r.name.prefix(28))")
        openThread(r.id)
        usleep(600_000)
    }
    return clicked
}

if flag("--probe-screen") {
    guard let win = chatgptWindows().first else { print("no-window"); exit(6) }
    let path = "\(tmpDir)/probe.png"
    let ok = capture(win.id, path)
    print(ok ? "screen=ok" : "screen=missing")
    exit(ok ? 0 : 4)
}

if flag("--list-threads") {
    guard let threads = fetchThreads() else { print("app-server unavailable"); exit(5) }
    for t in threads { print("\(t.id)\t\(t.name)\t\(t.path)") }
    exit(0)
}

log("retry_daemon start idle=\(Int(idleThreshold))s cooldown=\(Int(clickCooldown))s sweep=\(sweepEnabled) sweepIdle=\(Int(sweepIdle))s dryRun=\(dryRun) aggressiveAlways=\(aggressiveAlways)")
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
