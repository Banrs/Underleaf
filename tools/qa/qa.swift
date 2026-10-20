// qa: on-screen QA driver for macOS apps (AX + CGEvent + screencapture).
// Build: xcrun swiftc -O -o qa qa.swift
import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - basics

// The session scratchpad: lock file, appearance.dylib, default app and data paths live under it.
let SCR = ProcessInfo.processInfo.environment["QA_SCRATCH"] ?? NSTemporaryDirectory() + "texlocal-qa"
let env = ProcessInfo.processInfo.environment
setvbuf(stdout, nil, _IOLBF, 0)
/// QA_BG=1: the owner is using the Mac. Nothing fronts the app or posts an event: Accessibility
/// calls and window captures only, and the app is opened behind what is frontmost.
let BG = env["QA_BG"] == "1"

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("qa: " + msg + "\n").utf8))
    exit(code)
}
func emit(_ obj: Any) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: d, as: UTF8.self))
}
func sleepS(_ s: Double) { Thread.sleep(forTimeInterval: s) }

var args = Array(CommandLine.arguments.dropFirst())

/// Remove `--name value` from args and return the value.
func takeOpt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func takeFlag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

let bundleID = takeOpt("--bundle") ?? env["QA_BUNDLE"] ?? "com.texlocal.mac.qa"
let appPath = takeOpt("--app") ?? env["QA_APP"] ?? "\(SCR)/dd-frontend/Build/Products/Debug/TeXLocal.app"

guard !args.isEmpty else {
    fail("usage: qa <launch|quit|front|window|resize|move|shot|screen|menu|menus|key|type|click|move-mouse|drag|scroll|tree|find|press|set|get|toolbar|wait|wait-for|lock|check> …")
}
let cmd = args.removeFirst()

// MARK: - lock

func acquireLock() {
    if env["QA_LOCK_HELD"] == "1" { return }
    let fd = open("\(SCR)/qa/lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    if fd < 0 { fail("cannot open lock file") }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write(Data("qa: waiting for lock…\n".utf8))
        if flock(fd, LOCK_EX) != 0 { fail("flock failed") }
    }
    // fd stays open for the life of the process (CLOEXEC: children do not inherit it).
}

acquireLock()

if cmd == "lock" {
    if args.first == "--" { args.removeFirst() }
    guard !args.isEmpty else { fail("usage: qa lock -- <command> [args…]") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    var e = env
    e["QA_LOCK_HELD"] = "1"
    p.environment = e
    do { try p.run() } catch { fail("cannot run \(args[0]): \(error)") }
    p.waitUntilExit()
    exit(p.terminationStatus)
}

// MARK: - permissions

func checkAX() {
    if !AXIsProcessTrusted() {
        fail("MISSING PERMISSION: Accessibility is not granted to the hosting process (System Settings > Privacy & Security > Accessibility)", 2)
    }
}
func checkScreen() {
    if !CGPreflightScreenCaptureAccess() {
        // preflight can be stale; try a real capture
        let t = "\(NSTemporaryDirectory())qa-perm-\(getpid()).png"
        defer { try? FileManager.default.removeItem(atPath: t) }
        let r = run("/usr/sbin/screencapture", ["-x", "-R0,0,8,8", t])
        if r != 0 || !FileManager.default.fileExists(atPath: t) {
            fail("MISSING PERMISSION: Screen Recording is not granted to the hosting process", 2)
        }
    }
}
@discardableResult
func run(_ path: String, _ a: [String], capture: Bool = false) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = a
    if !capture { p.standardOutput = FileHandle.nullDevice }
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - AX helpers

func axApp(_ pid: pid_t) -> AXUIElement {
    let a = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(a, 5)
    return a
}
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func attrStr(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
func attrEls(_ e: AXUIElement, _ name: String) -> [AXUIElement] { (attr(e, name) as? [AXUIElement]) ?? [] }
func pointOf(_ v: CFTypeRef?) -> CGPoint? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}
func sizeOf(_ v: CFTypeRef?) -> CGSize? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}
func frameOf(_ e: AXUIElement) -> CGRect? {
    guard let p = pointOf(attr(e, "AXPosition")), let s = sizeOf(attr(e, "AXSize")) else { return nil }
    return CGRect(origin: p, size: s)
}
func setPoint(_ e: AXUIElement, _ name: String, _ p: CGPoint) {
    var p = p
    if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(e, name as CFString, v) }
}
func setSize(_ e: AXUIElement, _ name: String, _ s: CGSize) {
    var s = s
    if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(e, name as CFString, v) }
}

struct El {
    let ref: AXUIElement
    var role = "", sub = "", title = "", desc = "", value = "", ident = "", help = ""
    var frame: CGRect?
    var enabled: Bool?
    var focused: Bool?
    var children: [AXUIElement] = []
    var label: String { [title, desc, value].first { !$0.isEmpty } ?? "" }
}
let loadNames = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier",
                 "AXPosition", "AXSize", "AXEnabled", "AXFocused", "AXChildren", "AXHelp"] as CFArray
func load(_ e: AXUIElement) -> El {
    var el = El(ref: e)
    var out: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(e, loadNames, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
          let arr = out as? [Any] else { return el }
    func ok(_ i: Int) -> CFTypeRef? {
        let v = arr[i] as CFTypeRef
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
        return v
    }
    func s(_ i: Int) -> String {
        guard let v = ok(i) else { return "" }
        if let x = v as? String { return x }
        if let x = v as? NSNumber { return x.stringValue }
        return ""
    }
    el.role = s(0); el.sub = s(1); el.title = s(2); el.desc = s(3); el.value = s(4); el.ident = s(5)
    if let p = pointOf(ok(6)), let sz = sizeOf(ok(7)) { el.frame = CGRect(origin: p, size: sz) }
    el.enabled = (ok(8) as? NSNumber)?.boolValue
    el.focused = (ok(9) as? NSNumber)?.boolValue
    el.children = (ok(10) as? [AXUIElement]) ?? []
    el.help = s(11)
    return el
}

func walk(_ root: AXUIElement, maxDepth: Int = 40, _ visit: (El, [Int], Int) -> Bool) {
    var count = 0
    func rec(_ e: AXUIElement, _ path: [Int], _ depth: Int) {
        count += 1
        if count > 20000 { return }
        let el = load(e)
        if !visit(el, path, depth) { return }
        if depth >= maxDepth { return }
        for (i, c) in el.children.enumerated() { rec(c, path + [i], depth + 1) }
    }
    rec(root, [], 0)
}

// MARK: - target app

func targetApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
}
func needApp() -> NSRunningApplication {
    guard let a = targetApp() else { fail("\(bundleID) is not running (use: qa launch)") }
    return a
}
func appEl() -> AXUIElement { axApp(needApp().processIdentifier) }

func axWindows() -> [AXUIElement] { attrEls(appEl(), "AXWindows") }

func mainWindow() -> AXUIElement {
    let a = appEl()
    for n in ["AXMainWindow", "AXFocusedWindow"] {
        if let w = attr(a, n), CFGetTypeID(w) == AXUIElementGetTypeID() {
            let e = w as! AXUIElement
            if frameOf(e) != nil { return e }
        }
    }
    if let w = attrEls(a, "AXWindows").first { return w }
    fail("\(bundleID) has no window")
}
func windowID(_ w: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    if _AXUIElementGetWindow(w, &id) == .success && id != 0 { return id }
    // 27.2: the private call can fail for a background app; the app's largest normal window by pid instead.
    let pid = needApp().processIdentifier
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    func area(_ w: [String: Any]) -> CGFloat {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return 0 }
        return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    return (mine.max { area($0) < area($1) }?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
}
func pickWindow(_ title: String?) -> AXUIElement {
    guard let t = title else { return mainWindow() }
    for w in axWindows() where (attrStr(w, "AXTitle") ?? "").localizedCaseInsensitiveContains(t) { return w }
    fail("no window with title containing '\(t)'")
}
func rel(_ r: CGRect, _ win: CGRect) -> [Double] {
    [r.origin.x - win.origin.x, r.origin.y - win.origin.y, r.width, r.height].map { (v: CGFloat) -> Double in (Double(v) * 10).rounded() / 10 }
}

func front() {
    if BG { return }
    let app = needApp()
    let a = axApp(app.processIdentifier)
    if app.isHidden { app.unhide() }
    app.activate(options: [.activateAllWindows])
    AXUIElementSetAttributeValue(a, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let w = attr(a, "AXMainWindow") ?? attrEls(a, "AXWindows").first {
        AXUIElementPerformAction(w as! AXUIElement, kAXRaiseAction as CFString)
    }
    for _ in 0..<30 {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
        sleepS(0.1)
    }
}

func windowInfo(_ w: AXUIElement, main: Bool) -> [String: Any] {
    var d: [String: Any] = ["main": main, "title": attrStr(w, "AXTitle") ?? ""]
    if let id = windowID(w) { d["id"] = id }
    if let f = frameOf(w) { d["frame"] = [f.origin.x, f.origin.y, f.width, f.height] }
    if let s = sizeOf(attr(w, "AXMinSize")) { d["minSize"] = [s.width, s.height] }
    d["role"] = attrStr(w, "AXRole") ?? ""
    d["subrole"] = attrStr(w, "AXSubrole") ?? ""
    return d
}
func windowList() -> [[String: Any]] {
    let m = mainWindow()
    let mid = windowID(m)
    var out = [windowInfo(m, main: true)]
    for w in axWindows() where windowID(w) != mid { out.append(windowInfo(w, main: false)) }
    return out
}

// MARK: - events

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "t": 17, "y": 16, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
    "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
    "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
    "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
    "f11": 103, "f12": 111,
]
func parseChord(_ s: String) -> (CGKeyCode, CGEventFlags) {
    var flags: CGEventFlags = []
    var parts = s.lowercased().components(separatedBy: "+")
    // a trailing "+" key ("cmd++")
    var key = parts.removeLast()
    if key.isEmpty { key = "="; flags.insert(.maskShift) }  // "cmd++" -> cmd+shift+=
    for p in parts {
        switch p {
        case "cmd", "command", "meta": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        case "": continue
        default: fail("unknown modifier '\(p)'")
        }
    }
    guard let code = keyCodes[key] else { fail("unknown key '\(key)'") }
    if ["left", "right", "up", "down", "home", "end", "pageup", "pagedown", "forwarddelete"].contains(key) {
        flags.insert(.maskSecondaryFn)
    }
    return (code, flags)
}
func pressKey(_ chord: String) {
    let (code, flags) = parseChord(chord)
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        post(e)
        sleepS(0.02)
    }
}
func typeText(_ t: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in t {
        if ch == "\n" { pressKey("return"); continue }
        let u = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            e?.flags = []
            post(e)
        }
        sleepS(0.012)
    }
}

func modFlags(_ s: String?) -> CGEventFlags {
    var f: CGEventFlags = []
    for p in (s ?? "").lowercased().split(separator: ",") {
        switch p {
        case "cmd", "command": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "alt", "opt", "option": f.insert(.maskAlternate)
        case "ctrl", "control": f.insert(.maskControl)
        default: fail("unknown modifier '\(p)'")
        }
    }
    return f
}
/// Safety: never deliver a click to anything but the target app (e.g. a system permission prompt on top of it).
func guardPoint(_ p: CGPoint) {
    let pid = needApp().processIdentifier
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
    for w in list {  // front to back
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p) else { continue }
        if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let opid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
        if opid == pid { return }
        if owner == "Window Server" || owner == "Dock" { continue }
        if (w[kCGWindowLayer as String] as? Int ?? 0) < 0 { continue }
        fail("refusing to click at \(Int(p.x)),\(Int(p.y)): the topmost window there belongs to '\(owner)', not the target app")
    }
}
func noEvents(_ what: String) {
    if BG { fail("background mode (QA_BG=1): \(what) posts real events; use press, set, caret, insert") }
}
func guardFrontmost() {
    let pid = needApp().processIdentifier
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        fail("refusing to send keys: the target app is not frontmost (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
    }
}
func moveMouse(_ p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
}
func clickAt(_ p: CGPoint, right: Bool = false, count: Int = 1, flags: CGEventFlags = []) {
    let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
    let btn: CGMouseButton = right ? .right : .left
    guardPoint(p)
    moveMouse(p)
    sleepS(0.05)
    for n in 1...count {
        for t in [down, up] {
            let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: btn)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            e?.flags = flags
            post(e)
            sleepS(0.03)
        }
    }
}

func nums(_ n: Int, _ usage: String) -> [Double] {
    guard args.count >= n else { fail("usage: \(usage)") }
    return (0..<n).map { (i: Int) -> Double in
        guard let v = Double(args[i]) else { fail("not a number: \(args[i])") }
        return v
    }
}
func globalPoint(_ x: Double, _ y: Double, screen: Bool) -> CGPoint {
    if screen { return CGPoint(x: x, y: y) }
    let f = frameOf(mainWindow()) ?? .zero
    return CGPoint(x: f.origin.x + x, y: f.origin.y + y)
}

// MARK: - menus

func menuBar() -> AXUIElement {
    guard let m = attr(appEl(), "AXMenuBar") else { fail("no menu bar (is the app frontmost?)") }
    return m as! AXUIElement
}
func menuItemInfo(_ e: AXUIElement, depth: Int) -> [String: Any] {
    var d: [String: Any] = [:]
    let role = attrStr(e, "AXRole") ?? ""
    d["title"] = attrStr(e, "AXTitle") ?? ""
    d["enabled"] = (attr(e, "AXEnabled") as? NSNumber)?.boolValue ?? true
    if let m = attrStr(e, "AXMenuItemMarkChar"), !m.isEmpty { d["checked"] = m }
    if let c = attrStr(e, "AXMenuItemCmdChar"), !c.isEmpty {
        let mods = (attr(e, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0
        var s = ""
        // AX modifier bits: 1 shift, 2 option, 4 control, 8 = no command
        if mods & 4 != 0 { s += "ctrl+" }
        if mods & 2 != 0 { s += "opt+" }
        if mods & 1 != 0 { s += "shift+" }
        if mods & 8 == 0 { s += "cmd+" }
        d["shortcut"] = s + c.lowercased()
    }
    if role == "AXMenuBarItem" || role == "AXMenuItem" {
        if depth < 3, let menu = attrEls(e, "AXChildren").first {
            d["items"] = attrEls(menu, "AXChildren").map { c in
                (attrStr(c, "AXTitle") ?? "").isEmpty && (attrStr(c, "AXRole") ?? "") == "AXMenuItem"
                    ? ["title": "-", "separator": true] : menuItemInfo(c, depth: depth + 1)
            }
        }
    }
    return d
}
func findMenuItem(in container: AXUIElement, _ title: String) -> AXUIElement? {
    let items = attrEls(container, "AXChildren")
    let t = title.lowercased()
    func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces) }
    return items.first { (attrStr($0, "AXTitle") ?? "").lowercased() == t }
        ?? items.first { norm(attrStr($0, "AXTitle") ?? "") == norm(title) }
        ?? items.first { (attrStr($0, "AXTitle") ?? "").lowercased().hasPrefix(t) }
}
/// AXPress can block while a menu is tracking; run it off-thread with a timeout.
/// A failed `menu` must not leave the menu open under the next command.
func closeMenus() { pressKey("escape"); sleepS(0.1); pressKey("escape"); sleepS(0.2) }
func pressAsync(_ e: AXUIElement, timeout: Double = 3) {
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { AXUIElementPerformAction(e, kAXPressAction as CFString); sem.signal() }
    _ = sem.wait(timeout: .now() + timeout)
}

// MARK: - element search

func allRoots(_ allWindows: Bool, _ title: String?) -> [AXUIElement] {
    if allWindows { return axWindows() }
    return [pickWindow(title)]
}
struct Hit { let el: El; let path: [Int]; let rank: Int; let win: CGRect }
func search(_ text: String, roots: [AXUIElement], role: String? = nil) -> [Hit] {
    var hits: [Hit] = []
    let t = text.lowercased()
    for root in roots {
        let wf = frameOf(root) ?? .zero
        walk(root) { el, path, _ in
            if let r = role, el.role != r { return true }
            let fields = [el.title, el.desc, el.value, el.ident]
            var rank = 0
            if el.ident.lowercased() == t { rank = 4 }
            else if fields.contains(where: { $0.lowercased() == t }) { rank = 3 }
            else if fields.contains(where: { $0.lowercased().contains(t) }) { rank = 2 }
            if rank > 0 { hits.append(Hit(el: el, path: path, rank: rank, win: wf)) }
            return true
        }
    }
    return hits
}
func hitJSON(_ h: Hit, _ i: Int? = nil) -> [String: Any] {
    var d: [String: Any] = ["role": h.el.role, "path": h.path.map(String.init).joined(separator: "."), "rank": h.rank]
    if let i { d["index"] = i }
    if !h.el.sub.isEmpty { d["subrole"] = h.el.sub }
    if !h.el.title.isEmpty { d["title"] = h.el.title }
    if !h.el.desc.isEmpty { d["description"] = h.el.desc }
    if !h.el.value.isEmpty { d["value"] = String(h.el.value.prefix(200)) }
    if !h.el.ident.isEmpty { d["identifier"] = h.el.ident }
    if let f = h.el.frame { d["frame"] = rel(f, h.win) }
    if let e = h.el.enabled { d["enabled"] = e }
    return d
}
func bestHit(_ text: String) -> Hit {
    let all = takeFlag("--all-windows")
    let roots = allRoots(all, takeOpt("--window"))
    let role = takeOpt("--role")
    let idx = takeOpt("--index").flatMap { Int($0) }
    var hits = search(text, roots: roots, role: role)
    if hits.isEmpty { fail("no element matches '\(text)'") }
    let top = hits.map(\.rank).max()!
    hits = hits.filter { $0.rank == top }
    if let idx {
        guard idx < hits.count else { fail("--index \(idx) out of range (\(hits.count) matches)") }
        return hits[idx]
    }
    if hits.count > 1 {
        let desc = hits.enumerated().map { "  [\($0.offset)] \($0.element.el.role) '\($0.element.el.label)' id=\($0.element.el.ident) @\($0.element.path.map(String.init).joined(separator: "."))" }.joined(separator: "\n")
        fail("'\(text)' is ambiguous (\(hits.count) matches); use --index n or --role:\n\(desc)")
    }
    return hits[0]
}

// MARK: - launch

func launch() {
    let dataDir = takeOpt("--data") ?? "\(SCR)/qa-library"
    let dark = takeFlag("--dark"), light = takeFlag("--light")
    var extra: [String] = []
    if let i = args.firstIndex(of: "--") { extra = Array(args[(i + 1)...]); args.removeSubrange(i...) }
    if targetApp() == nil || targetApp()!.isTerminated {
        var oa = (BG ? ["-g"] : []) + ["-n", "--env", "TEXLOCAL_DATA=\(dataDir)"]
        // QA_ENV="K=V;K2=V2": more environment for the app, e.g. TEXLOCAL_TEXPRESSO for a scratch engine.
        for pair in (env["QA_ENV"] ?? "").split(separator: ";") where pair.contains("=") { oa += ["--env", String(pair)] }
        oa += [appPath, "--args"]
        if light { oa += ["-NSRequiresAquaSystemAppearance", "YES"] }
        if dark { oa += ["-AppleInterfaceStyle", "Dark"] }
        // Launch arguments alone do not change the effective appearance on macOS 27; a tiny dylib
        // (qa/appearance.dylib, injected into this one process only) sets NSApp.appearance.
        if dark || light {
            let dylib = "\(SCR)/qa/appearance.dylib"
            if FileManager.default.fileExists(atPath: dylib) {
                oa = (BG ? ["-g"] : []) + ["-n", "--env", "QA_APPEARANCE=\(dark ? "dark" : "light")", "--env", "DYLD_INSERT_LIBRARIES=\(dylib)"] + Array(oa.drop { $0 == "-g" || $0 == "-n" })
            }
        }
        oa += extra
        if run("/usr/bin/open", oa) != 0 { fail("open failed for \(appPath)") }
    }
    for _ in 0..<150 {
        if let a = targetApp(), !attrEls(axApp(a.processIdentifier), "AXWindows").isEmpty { break }
        sleepS(0.2)
    }
    guard targetApp() != nil else { fail("app did not start") }
    sleepS(0.5)
    front()
    emit(["pid": Int(needApp().processIdentifier), "windows": windowList()])
}

// MARK: - commands

func printTree() {
    let depthMax = takeOpt("--depth").flatMap { Int($0) } ?? 40
    let all = takeFlag("--all-windows")
    let roots = allRoots(all, takeOpt("--window"))
    let role = takeOpt("--role")
    let help = takeFlag("--help-tags")
    for root in roots {
        let wf = frameOf(root) ?? .zero
        walk(root, maxDepth: depthMax) { el, path, depth in
            if role == nil || el.role == role {
                var s = String(repeating: "  ", count: depth) + el.role
                if !el.sub.isEmpty { s += "/" + el.sub }
                let l = el.label.replacingOccurrences(of: "\n", with: "⏎")
                if !l.isEmpty { s += " \"" + (l.count > 60 ? String(l.prefix(60)) + "…" : l) + "\"" }
                if !el.ident.isEmpty { s += " id=" + el.ident }
                if let f = el.frame { s += " " + rel(f, wf).map { String(format: "%g", $0) }.joined(separator: ",") }
                if el.enabled == false { s += " disabled" }
                if el.focused == true { s += " focused" }
                if help, !el.help.isEmpty { s += " help=\"" + el.help.replacingOccurrences(of: "\n", with: "⏎") + "\"" }
                print(s)
            }
            return true
        }
    }
}

func toolbarJSON() {
    let w = mainWindow()
    let wf = frameOf(w) ?? .zero
    var tb: El?
    walk(w, maxDepth: 6) { el, _, _ in
        if tb == nil && el.role == "AXToolbar" { tb = el }
        return tb == nil
    }
    guard let tb else { fail("no AXToolbar in the main window") }
    let tf = tb.frame
    var items: [[String: Any]] = []
    var overflow: [String: Any]?
    func add(_ el: El, depth: Int) {
        let name = !el.ident.isEmpty ? el.ident : el.label
        var d: [String: Any] = ["role": el.role, "name": name, "description": el.desc, "title": el.title, "identifier": el.ident]
        if let f = el.frame { d["frame"] = rel(f, wf) }
        if let e = el.enabled { d["enabled"] = e }
        let low = (el.ident + el.desc + el.title).lowercased()
        let isOverflowBtn = low.contains("overflow") || low.contains("more") || el.ident == "NSToolbarOverflowItem"
        var inOverflow = false
        if let f = el.frame, let tf { inOverflow = f.width == 0 || f.height == 0 || !tf.insetBy(dx: -2, dy: -2).intersects(f) }
        d["overflowButton"] = isOverflowBtn
        d["inOverflow"] = inOverflow
        if isOverflowBtn { overflow = d } else { items.append(d) }
    }
    // Toolbar items are children; groups (AXGroup) hold their buttons.
    for c in tb.children {
        let el = load(c)
        if el.role == "AXGroup" || el.role == "AXToolbar" {
            let sub = el.children.map(load)
            var g: [String: Any] = ["role": el.role, "name": el.ident.isEmpty ? el.label : el.ident, "group": true]
            if let f = el.frame { g["frame"] = rel(f, wf) }
            g["children"] = sub.map { s -> [String: Any] in
                var x: [String: Any] = ["role": s.role, "name": s.ident.isEmpty ? s.label : s.ident, "description": s.desc, "title": s.title]
                if let f = s.frame { x["frame"] = rel(f, wf) }
                if let e = s.enabled { x["enabled"] = e }
                return x
            }
            items.append(g)
        } else { add(el, depth: 0) }
    }
    var out: [String: Any] = ["items": items]
    if let tf { out["toolbarFrame"] = rel(tf, wf) }
    out["window"] = [wf.width, wf.height]
    if let overflow { out["overflow"] = overflow; out["hasOverflow"] = true } else { out["hasOverflow"] = false }
    emit(out)
}

func shotWindow(_ out: String, title: String?, noFront: Bool) {
    checkScreen()
    if !noFront { front(); sleepS(0.4) }
    let w = pickWindow(title)
    // A window whose foot runs past the screen's edge is captured short there: move it onto the visible area first
    // (AX frames are top-left, the visible frame bottom-left).
    if let f = frameOf(w), let screen = NSScreen.screens.first {
        let visible = screen.visibleFrame, top = screen.frame.maxY - visible.maxY, foot = screen.frame.maxY - visible.minY
        if f.maxY > foot || f.minY < top || f.maxX > visible.maxX || f.minX < visible.minX {
            setPoint(w, "AXPosition", CGPoint(x: max(visible.minX, min(f.minX, visible.maxX - f.width)),
                                              y: max(top, min(f.minY, foot - f.height))))
            sleepS(0.4)
            if let g = frameOf(w), g.maxY > screen.frame.maxY { FileHandle.standardError.write("qa: window taller than the screen, captured short\n".data(using: .utf8)!) }
        }
    }
    guard let id = windowID(w) else { fail("cannot get CGWindowID") }
    if run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), out]) != 0 || !FileManager.default.fileExists(atPath: out) {
        fail("screencapture failed for window \(id)")
    }
    emit(["file": out, "windowID": id])
}

switch cmd {
case "check":
    checkAX(); checkScreen()
    emit(["accessibility": true, "screenRecording": true])

case "launch":
    checkAX(); launch()

case "quit":
    checkAX()
    guard let app = targetApp() else { print("{\"running\": false}"); exit(0) }
    front()
    var done = false
    if let m = attr(axApp(app.processIdentifier), "AXMenuBar") {
        // first menu after the Apple menu is the app menu; its "Quit …" item
        let bar = m as! AXUIElement
        let tops = attrEls(bar, "AXChildren")
        if tops.count > 1, let menu = attrEls(tops[1], "AXChildren").first {
            if let q = attrEls(menu, "AXChildren").first(where: { (attrStr($0, "AXTitle") ?? "").hasPrefix("Quit") }) {
                pressAsync(q); done = true
            }
        }
    }
    for _ in 0..<50 { if targetApp() == nil { break }; sleepS(0.1) }
    if let a = targetApp() {
        // a save sheet or similar may be blocking; fall back
        if !done { a.terminate() }
        for _ in 0..<30 { if targetApp() == nil { break }; sleepS(0.1) }
        if let a2 = targetApp() { a2.forceTerminate(); sleepS(0.3) }
        emit(["running": false, "forced": true])
    } else { emit(["running": false]) }

case "front":
    checkAX(); front(); emit(["frontmost": true])

case "window":
    checkAX(); emit(windowList())

case "resize":
    checkAX()
    let wt = takeOpt("--window")
    let n = nums(2, "qa resize <w> <h> [--window t]")
    let w = pickWindow(wt)
    setSize(w, "AXSize", CGSize(width: n[0], height: n[1]))
    sleepS(0.4)
    let f = frameOf(w)!
    emit(["frame": [f.origin.x, f.origin.y, f.width, f.height], "requested": [n[0], n[1]],
          "clamped": abs(f.width - n[0]) > 1 || abs(f.height - n[1]) > 1])

case "move":
    checkAX()
    let wt = takeOpt("--window")
    let n = nums(2, "qa move <x> <y> [--window t]")
    let w = pickWindow(wt)
    setPoint(w, "AXPosition", CGPoint(x: n[0], y: n[1]))
    sleepS(0.3)
    let f = frameOf(w)!
    emit(["frame": [f.origin.x, f.origin.y, f.width, f.height]])

case "shot":
    checkAX()
    let noFront = takeFlag("--no-front") || BG
    let title = takeOpt("--window")
    guard let out = args.first else { fail("usage: qa shot <out.png> [--window t] [--no-front]") }
    shotWindow(out, title: title, noFront: noFront)

case "screen":
    checkScreen()
    let around = takeFlag("--around")  // crop to the main window plus a 60 pt margin (popovers, menus)
    guard let out = args.first else { fail("usage: qa screen <out.png> [--around]") }
    var sa = ["-x"]
    if around, let f = frameOf(mainWindow()) {
        let r = f.insetBy(dx: -60, dy: -60).intersection(CGRect(x: 0, y: 0, width: NSScreen.main!.frame.width, height: NSScreen.main!.frame.height))
        sa += ["-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
    }
    if run("/usr/sbin/screencapture", sa + [out]) != 0 { fail("screencapture failed") }
    emit(["file": out])

case "menus":
    checkAX()
    front()
    let bar = menuBar()
    let tops = attrEls(bar, "AXChildren")
    if let t = args.first {
        guard let item = tops.first(where: { (attrStr($0, "AXTitle") ?? "").lowercased() == t.lowercased() }) else { fail("no menu '\(t)'") }
        emit(menuItemInfo(item, depth: 0))
    } else {
        emit(tops.map { menuItemInfo($0, depth: 0) })
    }

case "menu":
    checkAX()
    guard args.count >= 1 else { fail("usage: qa menu <Top> [<Item> [<Subitem>]]") }
    front(); sleepS(0.2)
    let tops = attrEls(menuBar(), "AXChildren")
    guard let top = tops.first(where: { (attrStr($0, "AXTitle") ?? "").lowercased() == args[0].lowercased() }) else { fail("no menu '\(args[0])'") }
    pressAsync(top, timeout: 1.5)
    var cur = top
    for name in args.dropFirst() {
        sleepS(0.25)
        guard let menu = attrEls(cur, "AXChildren").first else { closeMenus(); fail("'\(attrStr(cur, "AXTitle") ?? "")' has no menu") }
        guard let item = findMenuItem(in: menu, name) else { closeMenus(); fail("no menu item '\(name)'") }
        if (attr(item, "AXEnabled") as? NSNumber)?.boolValue == false { closeMenus(); fail("menu item '\(name)' is disabled") }
        pressAsync(item, timeout: 1.5)
        cur = item
    }
    emit(["menu": args])

case "key":
    checkAX(); noEvents("key")
    // --no-raise: keys for a popover or a menu, which raising the main window would close.
    let noRaise = takeFlag("--no-raise")
    guard let c = args.first else { fail("usage: qa key <chord> [--no-raise]") }
    if !noRaise { front(); sleepS(0.1) }
    guardFrontmost(); pressKey(c)

case "type":
    checkAX(); noEvents("type")
    // --no-raise: typing into a window already fronted. Raising it again resigns and takes key around the keys,
    // which closes what a key window keeps open (a completion list).
    let noRaise = takeFlag("--no-raise")
    guard let t = args.first else { fail("usage: qa type <text> [--no-raise]") }
    if !noRaise { front(); sleepS(0.1) }
    guardFrontmost(); typeText(t)

case "click":
    checkAX(); noEvents("click")
    let right = takeFlag("--right"), dbl = takeFlag("--double"), screen = takeFlag("--screen")
    let mods = takeOpt("--mod")
    // --no-raise: a click in a window already fronted, on something a passing loss of key would close.
    let noRaise = takeFlag("--no-raise")
    let n = nums(2, "qa click <x> <y>")
    if !noRaise { front(); sleepS(0.1) }
    clickAt(globalPoint(n[0], n[1], screen: screen), right: right, count: dbl ? 2 : 1, flags: modFlags(mods))

case "move-mouse":
    checkAX(); noEvents("move-mouse")
    let screen = takeFlag("--screen"), noRaise = takeFlag("--no-raise")
    let n = nums(2, "qa move-mouse <x> <y>")
    if !noRaise { front() }
    moveMouse(globalPoint(n[0], n[1], screen: screen))

case "drag":
    checkAX(); noEvents("drag")
    let screen = takeFlag("--screen")
    let dur = Double(takeOpt("--duration") ?? "0.5") ?? 0.5
    let steps = Int(takeOpt("--steps") ?? "30") ?? 30
    let n = nums(4, "qa drag <x1> <y1> <x2> <y2>")
    front(); sleepS(0.1)
    let a = globalPoint(n[0], n[1], screen: screen), b = globalPoint(n[2], n[3], screen: screen)
    guardPoint(a); guardPoint(b)
    moveMouse(a); sleepS(0.05)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
        sleepS(dur / Double(steps))
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))

case "scroll":
    checkAX(); noEvents("scroll")
    let screen = takeFlag("--screen")
    let n = nums(4, "qa scroll <x> <y> <dx> <dy>")
    front(); sleepS(0.1)
    moveMouse(globalPoint(n[0], n[1], screen: screen)); sleepS(0.05)
    // positive dy scrolls content up (wheel convention: negative = down); we pass values through as pixels
    post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(n[3]), wheel2: Int32(n[2]), wheel3: 0))

case "tree":
    checkAX(); printTree()

case "find":
    checkAX()
    let all = takeFlag("--all-windows")
    let roots = allRoots(all, takeOpt("--window"))
    let role = takeOpt("--role")
    guard let t = args.first else { fail("usage: qa find <text>") }
    let hits = search(t, roots: roots, role: role)
    emit(hits.enumerated().map { hitJSON($0.element, $0.offset) })

case "press":
    checkAX()
    guard let t = args.first else { fail("usage: qa press <text> [--index n]") }
    let dbl = takeFlag("--double")
    // qa press <label> --row-control AXCheckBox: the control of that role on the label's row, for a
    // form's switch, which has no title of its own.
    if let role = takeOpt("--row-control") {
        let root = pickWindow(nil)
        guard let label = search(t, roots: [root], role: "AXStaticText").max(by: { $0.rank < $1.rank })?.el.frame else {
            fail("no label '\(t)'")
        }
        var best: (AXUIElement, CGFloat)?
        walk(root) { el, _, _ in
            if el.role == role, let f = el.frame, abs(f.midY - label.midY) < (best?.1 ?? 12) { best = (el.ref, abs(f.midY - label.midY)) }
            return true
        }
        guard let control = best?.0 else { fail("no \(role) on the row of '\(t)'") }
        pressAsync(control, timeout: 2)
        emit(["pressed": t, "value": attrStr(control, "AXValue") ?? "\(attr(control, "AXValue") ?? "" as CFString)"])
        exit(0)
    }
    let h = bestHit(t)
    // popups and menu buttons only open when the app is active
    front(); sleepS(0.3)  // also makes the window key again after a menu action
    if dbl {
        noEvents("press --double")
        guard let f = h.el.frame else { fail("element has no frame") }
        front(); clickAt(CGPoint(x: f.midX, y: f.midY), count: 2)
        emit(hitJSON(h)); exit(0)
    }
    let acts = { () -> [String] in var a: CFArray?; AXUIElementCopyActionNames(h.el.ref, &a); return (a as? [String]) ?? [] }()
    if acts.contains("AXPress") {
        pressAsync(h.el.ref, timeout: 2)
    } else if let f = h.el.frame {
        noEvents("press on an element without AXPress")
        front(); clickAt(CGPoint(x: f.midX, y: f.midY))
    } else { fail("element has no AXPress and no frame") }
    emit(hitJSON(h))

case "set":
    checkAX()
    guard args.count >= 2 else { fail("usage: qa set <text> <value>") }
    let name = takeOpt("--attr") ?? "AXValue"
    let number = takeFlag("--number")
    let v = args.removeLast()
    let h = bestHit(args[0])
    let value: CFTypeRef = number ? (NSNumber(value: Double(v) ?? 0) as CFTypeRef) : (v as CFString)
    let r = AXUIElementSetAttributeValue(h.el.ref, name as CFString, value)
    if r != .success { fail("cannot set \(name) (\(r.rawValue))") }
    emit(hitJSON(h))

// The source editor through Accessibility alone, for a window that isn't frontmost.
// qa caret <line> [--start]   the caret at the end (or start) of a line, from 1
// qa insert <text>            the text at the caret, as typed (one undo step)
// qa text                     the editor's whole text
case "caret", "insert", "text":
    checkAX()
    var area: AXUIElement?
    walk(pickWindow(nil)) { el, _, _ in
        if area == nil, el.role == "AXTextArea" { area = el.ref }
        return area == nil
    }
    guard let area else { fail("no text area in the window") }
    if cmd == "text" { emit(["value": attrStr(area, "AXValue") ?? ""]); break }
    if cmd == "insert" {
        guard let t = args.first else { fail("usage: qa insert <text>") }
        let r = AXUIElementSetAttributeValue(area, "AXSelectedText" as CFString, t as CFString)
        if r != .success { fail("cannot insert (\(r.rawValue))") }
        emit(["inserted": t]); break
    }
    let start = takeFlag("--start")
    guard let n = args.first.flatMap({ Int($0) }), n >= 1 else { fail("usage: qa caret <line> [--start]") }
    // The file's lines, not the wrapped ones AXRangeForLine counts.
    let text = (attrStr(area, "AXValue") ?? "") as NSString
    var line = NSRange(location: 0, length: 0), at = 0
    for _ in 1...n {
        guard at <= text.length else { fail("no line \(n)") }
        line = text.lineRange(for: NSRange(location: at, length: 0))
        at = line.location + max(line.length, 1)
    }
    var end = line.location + line.length
    if end > line.location, text.character(at: end - 1) == 10 { end -= 1 }
    var caret = CFRange(location: start ? line.location : end, length: 0)
    guard let v = AXValueCreate(.cfRange, &caret),
          AXUIElementSetAttributeValue(area, "AXSelectedTextRange" as CFString, v) == .success else { fail("cannot move the caret") }
    emit(["caret": caret.location])

case "get":
    checkAX()
    guard args.count >= 2 else { fail("usage: qa get <text> <attribute>") }
    let a = args.removeLast()
    let h = bestHit(args[0])
    let name = a.hasPrefix("AX") ? a : "AX" + a.prefix(1).uppercased() + a.dropFirst()
    guard let v = attr(h.el.ref, name) else { fail("attribute \(name) not available") }
    if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .cgRect {
        var r = CGRect.zero; AXValueGetValue(v as! AXValue, .cgRect, &r)
        let wf = frameOf(pickWindow(nil)) ?? .zero
        emit(["frame": rel(r, wf)])
    }
    else if let p = pointOf(v) { emit([p.x, p.y]) }
    else if let s = sizeOf(v) { emit([s.width, s.height]) }
    else if let s = v as? String { emit(["value": s]) }
    else if let n = v as? NSNumber { emit(["value": n]) }
    else { emit(["value": "\(v)"]) }

case "toolbar":
    checkAX(); toolbarJSON()

case "close":
    // close a window by its AX close button (never quits the app via cmd+w by accident)
    checkAX()
    var w: AXUIElement
    if takeFlag("--other") {  // a secondary window (About, Settings): any window that is not the project/main one
        let mid = windowID(mainWindow())
        guard let o = axWindows().first(where: { windowID($0) != mid }) else { fail("no secondary window") }
        w = o
    } else { w = pickWindow(takeOpt("--window")) }
    guard let cb = attr(w, "AXCloseButton") else { fail("window has no close button") }
    AXUIElementPerformAction(cb as! AXUIElement, kAXPressAction as CFString)
    emit(["closed": attrStr(w, "AXTitle") ?? ""])

case "wait":
    guard let s = args.first.flatMap(Double.init) else { fail("usage: qa wait <seconds>") }
    sleepS(s)

case "wait-for":
    checkAX()
    let timeout = Double(takeOpt("--timeout") ?? "20") ?? 20
    let all = takeFlag("--all-windows")
    let title = takeOpt("--window")
    guard let t = args.first else { fail("usage: qa wait-for <text> [--timeout s]") }
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if targetApp() != nil {
            let hits = search(t, roots: allRoots(all, title))
            if let h = hits.first { emit(hitJSON(h)); exit(0) }
        }
        sleepS(0.3)
    }
    fail("timeout waiting for '\(t)'")

default:
    fail("unknown subcommand '\(cmd)'")
}
