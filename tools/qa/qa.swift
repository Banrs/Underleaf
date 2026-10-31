import ApplicationServices
import Cocoa

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let env = ProcessInfo.processInfo.environment
let SCR = env["QA_SCRATCH"] ?? NSTemporaryDirectory() + "texlocal-qa"
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("qa: \(msg)\n".utf8))
    exit(code)
}
func emit(_ obj: Any) {
    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let d = try! JSONSerialization.data(withJSONObject: obj, options: options)
    print(String(decoding: d, as: UTF8.self))
}
func sleepS(_ s: Double) { Thread.sleep(forTimeInterval: s) }

var args = Array(CommandLine.arguments.dropFirst())

func takeOpt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let bundleID = takeOpt("--bundle") ?? env["QA_BUNDLE"] ?? "com.texlocal.mac.qa"
let appPath = takeOpt("--app") ?? env["QA_APP"] ?? "\(SCR)/dd-frontend/Build/Products/Debug/TeXLocal.app"

guard !args.isEmpty else {
    fail("usage: qa <check|launch|quit|front|window|resize|move|shot|screen|menu|menus|key|type|click|move-mouse|"
        + "drag|scroll|tree|find|press|set|get|caret|insert|text|toolbar|close|wait|wait-for> …")
}
let cmd = args.removeFirst()

let lock = open("\(SCR)/qa/lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
if lock < 0 { fail("cannot open lock file") }
if flock(lock, LOCK_EX | LOCK_NB) != 0 {
    FileHandle.standardError.write(Data("qa: waiting for lock…\n".utf8))
    if flock(lock, LOCK_EX) != 0 { fail("flock failed") }
}

@discardableResult
func run(_ path: String, _ a: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = a
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}
func checkAX() {
    if !AXIsProcessTrusted() {
        fail("MISSING PERMISSION: Accessibility is not granted to the hosting process "
            + "(System Settings > Privacy & Security > Accessibility)", 2)
    }
}
func checkScreen() {
    if CGPreflightScreenCaptureAccess() { return }
    let t = "\(NSTemporaryDirectory())qa-perm-\(getpid()).png"
    defer { try? FileManager.default.removeItem(atPath: t) }
    if run("/usr/sbin/screencapture", ["-x", "-R0,0,8,8", t]) != 0 || !FileManager.default.fileExists(atPath: t) {
        fail("MISSING PERMISSION: Screen Recording is not granted to the hosting process", 2)
    }
}

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
func title(_ e: AXUIElement) -> String { attrStr(e, "AXTitle") ?? "" }
func axValue<T: BitwiseCopyable>(_ v: CFTypeRef?, _ type: AXValueType, _ empty: T) -> T? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var out = empty
    return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
}
func pointOf(_ v: CFTypeRef?) -> CGPoint? { axValue(v, .cgPoint, CGPoint.zero) }
func sizeOf(_ v: CFTypeRef?) -> CGSize? { axValue(v, .cgSize, CGSize.zero) }
func frameOf(_ e: AXUIElement) -> CGRect? {
    guard let p = pointOf(attr(e, "AXPosition")), let s = sizeOf(attr(e, "AXSize")) else { return nil }
    return CGRect(origin: p, size: s)
}
func setAX<T: BitwiseCopyable>(_ e: AXUIElement, _ name: String, _ type: AXValueType, _ value: T) {
    var value = value
    if let v = AXValueCreate(type, &value) { AXUIElementSetAttributeValue(e, name as CFString, v) }
}
func enabled(_ e: AXUIElement) -> Bool? { (attr(e, "AXEnabled") as? NSNumber)?.boolValue }

struct El {
    let ref: AXUIElement
    var role = "", sub = "", title = "", desc = "", value = "", ident = "", help = ""
    var frame: CGRect?
    var enabled: Bool?
    var focused: Bool?
    var children: [AXUIElement] = []
    var label: String { [title, desc, value].first { !$0.isEmpty } ?? "" }
    var name: String { ident.isEmpty ? label : ident }
}
let loadNames = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier",
                 "AXPosition", "AXSize", "AXEnabled", "AXFocused", "AXChildren", "AXHelp"] as CFArray
func load(_ e: AXUIElement) -> El {
    var el = El(ref: e)
    var out: CFArray?
    let options = AXCopyMultipleAttributeOptions(rawValue: 0)
    guard AXUIElementCopyMultipleAttributeValues(e, loadNames, options, &out) == .success,
          let arr = out as? [Any] else { return el }
    func ok(_ i: Int) -> CFTypeRef? {
        let v = arr[i] as CFTypeRef
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
        return v
    }
    func s(_ i: Int) -> String { (ok(i) as? String) ?? (ok(i) as? NSNumber)?.stringValue ?? "" }
    el.role = s(0); el.sub = s(1); el.title = s(2); el.desc = s(3); el.value = s(4); el.ident = s(5); el.help = s(11)
    if let p = pointOf(ok(6)), let sz = sizeOf(ok(7)) { el.frame = CGRect(origin: p, size: sz) }
    el.enabled = (ok(8) as? NSNumber)?.boolValue
    el.focused = (ok(9) as? NSNumber)?.boolValue
    el.children = (ok(10) as? [AXUIElement]) ?? []
    return el
}

func walk(_ root: AXUIElement, maxDepth: Int = 40, _ visit: (El, [Int], Int) -> Bool) {
    var count = 0
    func rec(_ e: AXUIElement, _ path: [Int], _ depth: Int) {
        count += 1
        if count > 20000 { return }
        let el = load(e)
        guard visit(el, path, depth), depth < maxDepth else { return }
        for (i, c) in el.children.enumerated() { rec(c, path + [i], depth + 1) }
    }
    rec(root, [], 0)
}
func first(in root: AXUIElement, maxDepth: Int = 40, _ match: (El) -> Bool) -> El? {
    var found: El?
    walk(root, maxDepth: maxDepth) { el, _, _ in
        if found == nil, match(el) { found = el }
        return found == nil
    }
    return found
}

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
        if let w = attr(a, n), CFGetTypeID(w) == AXUIElementGetTypeID(), frameOf(w as! AXUIElement) != nil {
            return w as! AXUIElement
        }
    }
    if let w = attrEls(a, "AXWindows").first { return w }
    fail("\(bundleID) has no window")
}
func windowList(_ options: CGWindowListOption) -> [[String: Any]] {
    CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
}
func bounds(_ w: [String: Any]) -> CGRect {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
}
func windowID(_ w: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    if _AXUIElementGetWindow(w, &id) == .success && id != 0 { return id }
    let pid = needApp().processIdentifier
    let mine = windowList([.optionAll]).filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    let largest = mine.max { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height }
    return (largest?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
}
func pickWindow(_ named: String?) -> AXUIElement {
    guard let t = named else { return mainWindow() }
    guard let w = axWindows().first(where: { title($0).localizedCaseInsensitiveContains(t) }) else {
        fail("no window with title containing '\(t)'")
    }
    return w
}
func takeRoots() -> [AXUIElement] {
    let all = takeFlag("--all-windows")
    let title = takeOpt("--window")
    return all ? axWindows() : [pickWindow(title)]
}
func rel(_ r: CGRect, _ win: CGRect) -> [Double] {
    [r.minX - win.minX, r.minY - win.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 }
}
func frameJSON(_ f: CGRect) -> [CGFloat] { [f.origin.x, f.origin.y, f.width, f.height] }

func front() {
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
    var d: [String: Any] = ["main": main, "title": title(w), "role": attrStr(w, "AXRole") ?? "",
                            "subrole": attrStr(w, "AXSubrole") ?? ""]
    if let id = windowID(w) { d["id"] = id }
    if let f = frameOf(w) { d["frame"] = frameJSON(f) }
    if let s = sizeOf(attr(w, "AXMinSize")) { d["minSize"] = [s.width, s.height] }
    return d
}
func windows() -> [[String: Any]] {
    let m = mainWindow()
    let mid = windowID(m)
    return [windowInfo(m, main: true)] + axWindows().filter { windowID($0) != mid }.map { windowInfo($0, main: false) }
}

func post(_ e: CGEvent?, key: Bool = false) {
    if key { e?.postToPid(needApp().processIdentifier) } else { e?.post(tap: .cghidEventTap) }
}

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
let fnKeys: Set = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown", "forwarddelete"]
let keySource = CGEventSource(stateID: .privateState)

func modifiers(_ names: [String]) -> CGEventFlags {
    var flags: CGEventFlags = []
    for p in names {
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
    return flags
}
func pressKey(_ chord: String) {
    var parts = chord.lowercased().components(separatedBy: "+")
    var key = parts.removeLast()
    var flags = modifiers(parts)
    if key.isEmpty { key = "="; flags.insert(.maskShift) }
    guard let code = keyCodes[key] else { fail("unknown key '\(key)'") }
    if fnKeys.contains(key) { flags.insert(.maskSecondaryFn) }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: down)
        e?.flags = flags
        post(e, key: true)
        sleepS(0.02)
    }
}
func typeText(_ t: String) {
    for ch in t {
        if ch == "\n" { pressKey("return"); sleepS(0.2); continue }
        let u = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: keySource, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            e?.flags = []
            post(e, key: true)
        }
        sleepS(0.012)
    }
}

func guardPoint(_ p: CGPoint) {
    let pid = needApp().processIdentifier
    for w in windowList([.optionOnScreenOnly]) where bounds(w).contains(p) {
        if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        if (w[kCGWindowOwnerPID as String] as? Int32 ?? 0) == pid { return }
        if owner == "Window Server" || owner == "Dock" || (w[kCGWindowLayer as String] as? Int ?? 0) < 0 { continue }
        fail("refusing to click at \(Int(p.x)),\(Int(p.y)): the topmost window there belongs to '\(owner)', "
            + "not the target app")
    }
}
func guardFrontmost() {
    let frontmost = NSWorkspace.shared.frontmostApplication
    if frontmost?.processIdentifier != needApp().processIdentifier {
        fail("refusing to send keys: the target app is not frontmost (\(frontmost?.localizedName ?? "?"))")
    }
}
func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left) -> CGEvent? {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
}
func clickAt(_ p: CGPoint, right: Bool = false, count: Int = 1, flags: CGEventFlags = []) {
    guardPoint(p)
    post(mouse(.mouseMoved, p))
    sleepS(0.05)
    for n in 1...count {
        for t in right ? [CGEventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            let e = mouse(t, p, right ? .right : .left)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            e?.flags = flags
            post(e)
            sleepS(0.03)
        }
    }
}

func nums(_ n: Int, _ usage: String) -> [Double] {
    guard args.count >= n else { fail("usage: \(usage)") }
    return args.prefix(n).map { a -> Double in
        guard let v = Double(a) else { fail("not a number: \(a)") }
        return v
    }
}
func point(_ x: Double, _ y: Double, screen: Bool) -> CGPoint {
    let origin = screen ? .zero : (frameOf(mainWindow()) ?? .zero).origin
    return CGPoint(x: origin.x + x, y: origin.y + y)
}

func menuBarItems() -> [AXUIElement] {
    guard let m = attr(appEl(), "AXMenuBar") else { fail("no menu bar (is the app frontmost?)") }
    return attrEls(m as! AXUIElement, "AXChildren")
}
func topMenu(_ name: String) -> AXUIElement {
    guard let item = menuBarItems().first(where: { title($0).lowercased() == name.lowercased() }) else {
        fail("no menu '\(name)'")
    }
    return item
}
func menuItemInfo(_ e: AXUIElement, depth: Int) -> [String: Any] {
    var d: [String: Any] = ["title": title(e), "enabled": enabled(e) ?? true]
    if let m = attrStr(e, "AXMenuItemMarkChar"), !m.isEmpty { d["checked"] = m }
    if let c = attrStr(e, "AXMenuItemCmdChar"), !c.isEmpty {
        let mods = (attr(e, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0
        let names = [(4, "ctrl+"), (2, "opt+"), (1, "shift+")].filter { mods & $0.0 != 0 }.map(\.1)
        d["shortcut"] = names.joined() + (mods & 8 == 0 ? "cmd+" : "") + c.lowercased()
    }
    let role = attrStr(e, "AXRole") ?? ""
    if role == "AXMenuBarItem" || role == "AXMenuItem", depth < 3, let menu = attrEls(e, "AXChildren").first {
        d["items"] = attrEls(menu, "AXChildren").map { c in
            title(c).isEmpty && attrStr(c, "AXRole") == "AXMenuItem"
                ? ["title": "-", "separator": true] : menuItemInfo(c, depth: depth + 1)
        }
    }
    return d
}
func findMenuItem(in menu: AXUIElement, _ name: String) -> AXUIElement? {
    let items = attrEls(menu, "AXChildren")
    func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    let t = name.lowercased()
    return items.first { title($0).lowercased() == t }
        ?? items.first { norm(title($0)) == norm(name) }
        ?? items.first { title($0).lowercased().hasPrefix(t) }
}
func closeMenus() { pressKey("escape"); sleepS(0.1); pressKey("escape"); sleepS(0.2) }
func pressAsync(_ e: AXUIElement, timeout: Double = 3) {
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { AXUIElementPerformAction(e, kAXPressAction as CFString); sem.signal() }
    _ = sem.wait(timeout: .now() + timeout)
}

struct Hit { let el: El; let path: [Int]; let rank: Int; let win: CGRect }
func search(_ text: String, roots: [AXUIElement], role: String? = nil) -> [Hit] {
    var hits: [Hit] = []
    let t = text.lowercased()
    for root in roots {
        let wf = frameOf(root) ?? .zero
        walk(root) { el, path, _ in
            if let role, el.role != role { return true }
            let fields = [el.title, el.desc, el.value, el.ident].map { $0.lowercased() }
            let rank = el.ident.lowercased() == t ? 4
                : fields.contains(t) ? 3
                : fields.contains { $0.contains(t) } ? 2 : 0
            if rank > 0 { hits.append(Hit(el: el, path: path, rank: rank, win: wf)) }
            return true
        }
    }
    return hits
}
func hitJSON(_ h: Hit, _ i: Int? = nil) -> [String: Any] {
    var d: [String: Any] = ["role": h.el.role, "path": h.path.map(String.init).joined(separator: "."), "rank": h.rank]
    let fields = ["subrole": h.el.sub, "title": h.el.title, "description": h.el.desc,
                  "value": String(h.el.value.prefix(200)), "identifier": h.el.ident]
    for (k, v) in fields where !v.isEmpty { d[k] = v }
    if let i { d["index"] = i }
    if let f = h.el.frame { d["frame"] = rel(f, h.win) }
    if let e = h.el.enabled { d["enabled"] = e }
    return d
}
func bestHit(_ text: String, roots: [AXUIElement], role: String?, index: Int?) -> Hit {
    let hits = search(text, roots: roots, role: role)
    guard let top = hits.map(\.rank).max() else { fail("no element matches '\(text)'") }
    let best = hits.filter { $0.rank == top }
    if let index {
        guard index < best.count else { fail("--index \(index) out of range (\(best.count) matches)") }
        return best[index]
    }
    if best.count > 1 {
        let list = best.enumerated().map {
            "  [\($0.offset)] \($0.element.el.role) '\($0.element.el.label)' id=\($0.element.el.ident) "
                + "@\($0.element.path.map(String.init).joined(separator: "."))"
        }
        fail("'\(text)' is ambiguous (\(best.count) matches); use --index n or --role:\n"
            + list.joined(separator: "\n"))
    }
    return best[0]
}

func launch() {
    let dataDir = takeOpt("--data") ?? "\(SCR)/qa-library"
    let stateDir = (dataDir as NSString).standardizingPath + "-state"
    let dark = takeFlag("--dark"), light = takeFlag("--light")
    var extra: [String] = []
    if let i = args.firstIndex(of: "--") { extra = Array(args[(i + 1)...]) }
    if targetApp() == nil {
        var envs = ["TEXLOCAL_DATA=\(dataDir)", "TEXLOCAL_STATE=\(stateDir)"]
        let dylib = "\(SCR)/qa/appearance.dylib"
        if dark || light, FileManager.default.fileExists(atPath: dylib) {
            envs = ["QA_APPEARANCE=\(dark ? "dark" : "light")", "DYLD_INSERT_LIBRARIES=\(dylib)"] + envs
        }
        envs += (env["QA_ENV"] ?? "").split(separator: ";").filter { $0.contains("=") }.map(String.init)
        var oa = ["-n"] + envs.flatMap { ["--env", $0] } + [appPath, "--args"]
        if light { oa += ["-NSRequiresAquaSystemAppearance", "YES"] }
        if dark { oa += ["-AppleInterfaceStyle", "Dark"] }
        if run("/usr/bin/open", oa + extra) != 0 { fail("open failed for \(appPath)") }
    }
    for _ in 0..<150 {
        if let a = targetApp(), !attrEls(axApp(a.processIdentifier), "AXWindows").isEmpty { break }
        sleepS(0.2)
    }
    guard targetApp() != nil else { fail("app did not start") }
    sleepS(0.5)
    front()
    emit(["pid": Int(needApp().processIdentifier), "windows": windows()])
}

func printTree() {
    let depthMax = takeOpt("--depth").flatMap { Int($0) } ?? 40
    let roots = takeRoots()
    let role = takeOpt("--role")
    let help = takeFlag("--help-tags")
    for root in roots {
        let wf = frameOf(root) ?? .zero
        walk(root, maxDepth: depthMax) { el, _, depth in
            guard role == nil || el.role == role else { return true }
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
            return true
        }
    }
}

func toolbarJSON() {
    let w = mainWindow()
    let wf = frameOf(w) ?? .zero
    guard let tb = first(in: w, maxDepth: 6, { $0.role == "AXToolbar" }) else {
        fail("no AXToolbar in the main window")
    }
    func item(_ el: El) -> [String: Any] {
        var d: [String: Any] = ["role": el.role, "name": el.name, "description": el.desc, "title": el.title]
        if let f = el.frame { d["frame"] = rel(f, wf) }
        if let e = el.enabled { d["enabled"] = e }
        return d
    }
    var items: [[String: Any]] = []
    var overflow: [String: Any]?
    for el in tb.children.map(load) {
        if el.role == "AXGroup" || el.role == "AXToolbar" {
            var g: [String: Any] = ["role": el.role, "name": el.name, "group": true]
            g["children"] = el.children.map { item(load($0)) }
            if let f = el.frame { g["frame"] = rel(f, wf) }
            items.append(g)
            continue
        }
        var d = item(el)
        d["identifier"] = el.ident
        let low = (el.ident + el.desc + el.title).lowercased()
        let isOverflow = low.contains("overflow") || low.contains("more") || el.ident == "NSToolbarOverflowItem"
        d["overflowButton"] = isOverflow
        if let f = el.frame, let tf = tb.frame {
            d["inOverflow"] = f.width == 0 || f.height == 0 || !tf.insetBy(dx: -2, dy: -2).intersects(f)
        } else { d["inOverflow"] = false }
        if isOverflow { overflow = d } else { items.append(d) }
    }
    var out: [String: Any] = ["items": items, "window": [wf.width, wf.height], "hasOverflow": overflow != nil]
    if let tf = tb.frame { out["toolbarFrame"] = rel(tf, wf) }
    if let overflow { out["overflow"] = overflow }
    emit(out)
}

func shotWindow(_ out: String, title: String?, noFront: Bool) {
    checkScreen()
    if !noFront { front(); sleepS(0.4) }
    let w = pickWindow(title)
    if let f = frameOf(w), let screen = NSScreen.screens.first {
        let visible = screen.visibleFrame
        let top = screen.frame.maxY - visible.maxY, foot = screen.frame.maxY - visible.minY
        if f.maxY > foot || f.minY < top || f.maxX > visible.maxX || f.minX < visible.minX {
            setAX(w, "AXPosition", .cgPoint, CGPoint(x: max(visible.minX, min(f.minX, visible.maxX - f.width)),
                                                     y: max(top, min(f.minY, foot - f.height))))
            sleepS(0.4)
            if let g = frameOf(w), g.maxY > screen.frame.maxY {
                FileHandle.standardError.write(Data("qa: window taller than the screen, captured short\n".utf8))
            }
        }
    }
    guard let id = windowID(w) else { fail("cannot get CGWindowID") }
    let status = run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), out])
    if status != 0 || !FileManager.default.fileExists(atPath: out) {
        fail("screencapture failed for window \(id)")
    }
    emit(["file": out, "windowID": id])
}

func editor() {
    guard let area = first(in: pickWindow(nil), { $0.role == "AXTextArea" })?.ref else {
        fail("no text area in the window")
    }
    switch cmd {
    case "text":
        emit(["value": attrStr(area, "AXValue") ?? ""])
    case "insert":
        guard let t = args.first else { fail("usage: qa insert <text>") }
        let r = AXUIElementSetAttributeValue(area, "AXSelectedText" as CFString, t as CFString)
        if r != .success { fail("cannot insert (\(r.rawValue))") }
        emit(["inserted": t])
    default:
        let start = takeFlag("--start")
        guard let n = args.first.flatMap({ Int($0) }), n >= 1 else { fail("usage: qa caret <line> [--start]") }
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
              AXUIElementSetAttributeValue(area, "AXSelectedTextRange" as CFString, v) == .success else {
            fail("cannot move the caret")
        }
        emit(["caret": caret.location])
    }
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
    var pressed = false
    if let bar = attr(axApp(app.processIdentifier), "AXMenuBar") {
        let tops = attrEls(bar as! AXUIElement, "AXChildren")
        if tops.count > 1, let menu = attrEls(tops[1], "AXChildren").first,
           let q = attrEls(menu, "AXChildren").first(where: { title($0).hasPrefix("Quit") }) {
            pressAsync(q); pressed = true
        }
    }
    for _ in 0..<50 where targetApp() != nil { sleepS(0.1) }
    guard let a = targetApp() else { emit(["running": false]); break }
    if !pressed { a.terminate() }
    for _ in 0..<30 where targetApp() != nil { sleepS(0.1) }
    if let a = targetApp() { a.forceTerminate(); sleepS(0.3) }
    emit(["running": false, "forced": true])

case "front":
    checkAX(); front(); emit(["frontmost": true])

case "window":
    checkAX(); emit(windows())

case "resize", "move":
    checkAX()
    let wt = takeOpt("--window")
    let n = nums(2, cmd == "resize" ? "qa resize <w> <h> [--window t]" : "qa move <x> <y> [--window t]")
    let w = pickWindow(wt)
    if cmd == "move" {
        setAX(w, "AXPosition", .cgPoint, CGPoint(x: n[0], y: n[1]))
        sleepS(0.3)
        emit(["frame": frameJSON(frameOf(w)!)])
        break
    }
    setAX(w, "AXSize", .cgSize, CGSize(width: n[0], height: n[1]))
    sleepS(0.4)
    let f = frameOf(w)!
    let clamped = abs(f.width - n[0]) > 1 || abs(f.height - n[1]) > 1
    emit(["frame": frameJSON(f), "requested": [n[0], n[1]], "clamped": clamped])

case "shot":
    checkAX()
    let noFront = takeFlag("--no-front")
    let title = takeOpt("--window")
    guard let out = args.first else { fail("usage: qa shot <out.png> [--window t] [--no-front]") }
    shotWindow(out, title: title, noFront: noFront)

case "screen":
    checkScreen()
    let around = takeFlag("--around")
    guard let out = args.first else { fail("usage: qa screen <out.png> [--around]") }
    var sa = ["-x"]
    if around, let f = frameOf(mainWindow()) {
        let r = f.insetBy(dx: -60, dy: -60).intersection(CGRect(origin: .zero, size: NSScreen.main!.frame.size))
        sa.append("-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))")
    }
    if run("/usr/sbin/screencapture", sa + [out]) != 0 { fail("screencapture failed") }
    emit(["file": out])

case "menus":
    checkAX(); front()
    if let t = args.first {
        emit(menuItemInfo(topMenu(t), depth: 0))
    } else {
        emit(menuBarItems().map { menuItemInfo($0, depth: 0) })
    }

case "menu":
    checkAX()
    guard !args.isEmpty else { fail("usage: qa menu <Top> [<Item> [<Subitem>]]") }
    front(); sleepS(0.2)
    var cur = topMenu(args[0])
    pressAsync(cur, timeout: 1.5)
    for name in args.dropFirst() {
        sleepS(0.25)
        guard let menu = attrEls(cur, "AXChildren").first else { closeMenus(); fail("'\(title(cur))' has no menu") }
        guard let item = findMenuItem(in: menu, name) else { closeMenus(); fail("no menu item '\(name)'") }
        if enabled(item) == false { closeMenus(); fail("menu item '\(name)' is disabled") }
        pressAsync(item, timeout: 1.5)
        cur = item
    }
    emit(["menu": args])

case "key", "type":
    checkAX()
    let noRaise = takeFlag("--no-raise")
    guard let a = args.first else { fail("usage: qa \(cmd) <\(cmd == "key" ? "chord" : "text")> [--no-raise]") }
    if !noRaise { front(); sleepS(0.1) }
    guardFrontmost()
    if cmd == "key" { pressKey(a) } else { typeText(a) }

case "click":
    checkAX()
    let right = takeFlag("--right"), double = takeFlag("--double"), screen = takeFlag("--screen")
    let mods = modifiers((takeOpt("--mod") ?? "").lowercased().split(separator: ",").map(String.init))
    let noRaise = takeFlag("--no-raise")
    let n = nums(2, "qa click <x> <y>")
    if !noRaise { front(); sleepS(0.1) }
    clickAt(point(n[0], n[1], screen: screen), right: right, count: double ? 2 : 1, flags: mods)

case "move-mouse":
    checkAX()
    let screen = takeFlag("--screen"), noRaise = takeFlag("--no-raise")
    let n = nums(2, "qa move-mouse <x> <y>")
    if !noRaise { front() }
    post(mouse(.mouseMoved, point(n[0], n[1], screen: screen)))

case "drag":
    checkAX()
    let screen = takeFlag("--screen")
    let duration = Double(takeOpt("--duration") ?? "0.5") ?? 0.5
    let steps = Int(takeOpt("--steps") ?? "30") ?? 30
    let n = nums(4, "qa drag <x1> <y1> <x2> <y2>")
    front(); sleepS(0.1)
    let a = point(n[0], n[1], screen: screen), b = point(n[2], n[3], screen: screen)
    guardPoint(a); guardPoint(b)
    post(mouse(.mouseMoved, a)); sleepS(0.05)
    post(mouse(.leftMouseDown, a))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
        sleepS(duration / Double(steps))
    }
    post(mouse(.leftMouseUp, b))

case "scroll":
    checkAX()
    let screen = takeFlag("--screen")
    let n = nums(4, "qa scroll <x> <y> <dx> <dy>")
    front(); sleepS(0.1)
    post(mouse(.mouseMoved, point(n[0], n[1], screen: screen))); sleepS(0.05)
    post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                 wheel1: Int32(n[3]), wheel2: Int32(n[2]), wheel3: 0))

case "tree":
    checkAX(); printTree()

case "find":
    checkAX()
    let roots = takeRoots()
    let role = takeOpt("--role")
    guard let t = args.first else { fail("usage: qa find <text>") }
    emit(search(t, roots: roots, role: role).enumerated().map { hitJSON($0.element, $0.offset) })

case "press":
    checkAX()
    let roots = takeRoots(), role = takeOpt("--role"), index = takeOpt("--index").flatMap { Int($0) }
    let double = takeFlag("--double"), rowRole = takeOpt("--row-control")
    guard let t = args.first else { fail("usage: qa press <text> [--index n]") }
    if let rowRole {
        let labels = roots.flatMap { root in search(t, roots: [root], role: "AXStaticText").map { (root, $0) } }
        guard let found = labels.max(by: { $0.1.rank < $1.1.rank }), let label = found.1.el.frame else { fail("no label '\(t)'") }
        let root = found.0
        var best: (AXUIElement, CGFloat)?
        walk(root) { el, _, _ in
            if el.role == rowRole, let f = el.frame, abs(f.midY - label.midY) < (best?.1 ?? 12) {
                best = (el.ref, abs(f.midY - label.midY))
            }
            return true
        }
        guard let control = best?.0 else { fail("no \(rowRole) on the row of '\(t)'") }
        pressAsync(control, timeout: 2)
        emit(["pressed": t, "value": attrStr(control, "AXValue") ?? "\(attr(control, "AXValue") ?? "" as CFString)"])
        break
    }
    let h = bestHit(t, roots: roots, role: role, index: index)
    front(); sleepS(0.3)
    var actions: CFArray?
    AXUIElementCopyActionNames(h.el.ref, &actions)
    if !double, ((actions as? [String]) ?? []).contains("AXPress") {
        pressAsync(h.el.ref, timeout: 2)
    } else if let f = h.el.frame {
        front(); clickAt(CGPoint(x: f.midX, y: f.midY), count: double ? 2 : 1)
    } else { fail(double ? "element has no frame" : "element has no AXPress and no frame") }
    emit(hitJSON(h))

case "set":
    checkAX()
    let roots = takeRoots(), role = takeOpt("--role"), index = takeOpt("--index").flatMap { Int($0) }
    let name = takeOpt("--attr") ?? "AXValue", number = takeFlag("--number")
    guard args.count >= 2 else { fail("usage: qa set <text> <value>") }
    let v = args.removeLast()
    let h = bestHit(args[0], roots: roots, role: role, index: index)
    let value: CFTypeRef = number ? NSNumber(value: Double(v) ?? 0) as CFTypeRef : v as CFString
    let r = AXUIElementSetAttributeValue(h.el.ref, name as CFString, value)
    if r != .success { fail("cannot set \(name) (\(r.rawValue))") }
    emit(hitJSON(h))

case "caret", "insert", "text":
    checkAX(); editor()

case "get":
    checkAX()
    let roots = takeRoots(), role = takeOpt("--role"), index = takeOpt("--index").flatMap { Int($0) }
    guard args.count >= 2 else { fail("usage: qa get <text> <attribute>") }
    let a = args.removeLast()
    let h = bestHit(args[0], roots: roots, role: role, index: index)
    let name = a.hasPrefix("AX") ? a : "AX" + a.prefix(1).uppercased() + a.dropFirst()
    guard let v = attr(h.el.ref, name) else { fail("attribute \(name) not available") }
    if let r = axValue(v, .cgRect, CGRect.zero) { emit(["frame": rel(r, frameOf(pickWindow(nil)) ?? .zero)]) }
    else if let p = pointOf(v) { emit([p.x, p.y]) }
    else if let s = sizeOf(v) { emit([s.width, s.height]) }
    else if let s = v as? String { emit(["value": s]) }
    else if let n = v as? NSNumber { emit(["value": n]) }
    else { emit(["value": "\(v)"]) }

case "toolbar":
    checkAX(); toolbarJSON()

case "close":
    checkAX()
    let w: AXUIElement
    if takeFlag("--other") {
        let mid = windowID(mainWindow())
        guard let o = axWindows().first(where: { windowID($0) != mid }) else { fail("no secondary window") }
        w = o
    } else { w = pickWindow(takeOpt("--window")) }
    guard let button = attr(w, "AXCloseButton") else { fail("window has no close button") }
    AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    emit(["closed": title(w)])

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
        if targetApp() != nil, let h = search(t, roots: all ? axWindows() : [pickWindow(title)]).first {
            emit(hitJSON(h)); exit(0)
        }
        sleepS(0.3)
    }
    fail("timeout waiting for '\(t)'")

default:
    fail("unknown subcommand '\(cmd)'")
}
