import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A project's CodeMirror editor page; the protocol is web/src/embed/editor.js.
/// A plain `WKWebView`, not SwiftUI's `WebView`: that one's adapter answers Edit ›
/// Find with WebKit's own find bar, which sees only the lines CodeMirror has drawn,
/// where a plain web view passes the menu's find items on to the window.
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let scheme = "texlocal-app"

    /// Made once per project and moved between hosts as SwiftUI rebuilds them.
    let webView: WKWebView
    var onChanged: () -> Void = {}
    var onCursor: (Int) -> Void = { _ in }
    /// The line at the top of the view.
    var onScroll: (Int) -> Void = { _ in }
    var onCommand: (String) -> Void = { _ in }
    /// The page opened its search, with the query it starts from; the find bar is the host's.
    var onFind: (FindQuery) -> Void = { _ in }
    var onFindClosed: () -> Void = {}
    var onFindMatches: (FindMatches) -> Void = { _ in }
    /// The web process died, taking the editor's text with it.
    var onCrash: () -> Void = {}
    /// The page is back, empty, after its web process died.
    var onRestart: () -> Void = {}
    private(set) var crashes = 0
    /// The page never loaded; every call answers nil.
    private(set) var failed = false

    private var ready = false
    private var restarting = false
    private var whenReady: [CheckedContinuation<Void, Never>] = []
    /// Calls whose effect the page holds, made again after a crash.
    private var kept: [PageMethod: KeyValuePairs<String, Any>] = [:]
    /// Re-sent with fresh system colours when the accent or highlight colour changes.
    private var appearance: EditorAppearance?
    /// The file the page shows: messages about another are stale.
    private var openPath: String?
    private let controller = WKUserContentController()
    private var colorToken: NotificationCenter.ObservationToken?
    private var closed = false

    private static let log = Logger(subsystem: "com.texlocal.mac", category: "editor")

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebFiles(), forURLScheme: Self.scheme)
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(self, name: "texlocal")
        webView.navigationDelegate = self
        // A text editor: no page zoom, history swipes or link previews.
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.setAccessibilityLabel("Source")
        // Until the page draws its own surface: a web view paints white before then.
        webView.isHidden = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        colorToken = NotificationCenter.default.addObserver(of: NSColor.self, for: .systemColorsDidChange) { [weak self] _ in
            guard let self, let appearance = self.appearance else { return }
            Task { await self.setAppearance(appearance) }
        }
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://app/embed/editor.html")!))
    }

    /// Lets the page and its web process go: the content controller holds
    /// its message handler (this) strongly.
    func close() {
        closed = true
        if let colorToken { NotificationCenter.default.removeObserver(colorToken) }
        controller.removeScriptMessageHandler(forName: "texlocal")
        webView.navigationDelegate = nil
        // The page won't say it's ready now; release what waits on it.
        becomeReady()
    }

    // ---------- navigation ----------

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        ready = false
        restarting = true
        crashes += 1
        onCrash()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    /// Links never navigate the editor page; web and mail links open in their apps.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.request.url?.scheme == Self.scheme { return .allow }
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme) {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    private func fail(_ error: any Error) {
        failed = true
        Self.log.error("The editor page didn't load: \(error.localizedDescription, privacy: .public)")
        becomeReady()
    }

    // ---------- host → page ----------

    private enum PageMethod: String {
        case open, getDocument, currentLine, reveal, command, forget, rename
        case setSymbols, setHostKeys, setHostFind, setFind, closeFind, setAppearance
    }

    /// `return texlocal.<method>(<names>)`, the names bound to their values.
    private static func script(_ method: PageMethod, _ args: KeyValuePairs<String, Any>)
        -> (body: String, arguments: [String: Any]) {
        let names = args.map(\.key).joined(separator: ", ")
        return ("return texlocal.\(method.rawValue)(\(names))",
                Dictionary(args.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 }))
    }

    private func untilReady() async {
        if ready { return }
        await withCheckedContinuation { whenReady.append($0) }
    }

    @discardableResult
    private func call(_ method: PageMethod, _ args: KeyValuePairs<String, Any> = [:]) async -> Any? {
        await untilReady()
        if closed || failed { return nil }
        return await run(method, args)
    }

    @discardableResult
    private func run(_ method: PageMethod, _ args: KeyValuePairs<String, Any>) async -> Any? {
        let (body, arguments) = Self.script(method, args)
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        } catch {
            #if DEBUG
            Self.log.debug("texlocal.\(method.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
    }

    /// `focus` false leaves keyboard focus where it is (choosing a file in the sidebar).
    func open(path: String, text: String, focus: Bool = true) async {
        openPath = path
        await call(.open, ["path": path, "text": text, "scrollTop": 0, "focus": focus])
    }

    /// The page's text and the file it belongs to: by the time the page
    /// answers, it may show another.
    func document() async -> (path: String, text: String)? {
        guard let document = await call(.getDocument) as? [String: Any],
              let path = document["path"] as? String, let text = document["text"] as? String else { return nil }
        return (path, text)
    }

    func currentLine() async -> Int {
        (await call(.currentLine) as? Int) ?? 1
    }

    /// `atTop` puts the line at the top of the view; otherwise it is centred.
    func reveal(line: Int, atTop: Bool = false, focus: Bool = true) async {
        await call(.reveal, ["line": line, "atTop": atTop, "focus": focus])
    }

    /// False when the page did not run the command.
    @discardableResult
    func command(_ command: EditorCommand, _ arg: String? = nil) async -> Bool {
        (await call(.command, ["name": command.rawValue, "arg": arg ?? NSNull()]) as? Bool) ?? false
    }

    func forget(path: String) async {
        await call(.forget, ["path": path])
    }

    func rename(from: String, to: String) async {
        if let path = openPath, path == from || path.hasPrefix(from + "/") {
            openPath = to + path.dropFirst(from.count)
        }
        await call(.rename, ["from": from, "to": to])
    }

    private func keep(_ method: PageMethod, _ args: KeyValuePairs<String, Any> = [:]) async {
        kept[method] = args
        await call(method, args)
    }

    func setSymbols(_ symbols: Symbols) async {
        await keep(.setSymbols, ["labels": symbols.labels, "citations": symbols.citations])
    }

    func setHostKeys(_ keys: [(id: String, accel: String)]) async {
        await keep(.setHostKeys, ["list": keys.map { ["id": $0.id, "accel": $0.accel] }])
    }

    /// The page's search runs from the native find bar; CodeMirror's panel stays hidden.
    func useHostFind() async {
        await keep(.setHostFind, ["on": true])
    }

    func setFind(_ query: FindQuery) async {
        await call(.setFind, ["q": query.dictionary])
    }

    func closeFind() async {
        await call(.closeFind)
    }

    /// Settings' palette and font, with the system's colours resolved in the
    /// editor's appearance so the text sits on the same surface as the chrome.
    func setAppearance(_ appearance: EditorAppearance) async {
        self.appearance = appearance
        let dark = appearance.colorScheme == .dark
        var settings: [String: Any] = ["theme": dark ? "dark" : "light", "palette": appearance.palette.rawValue,
                                       "font": appearance.font.rawValue, "fontSize": appearance.fontSize]
        let name: NSAppearance.Name = switch (dark, appearance.contrast == .increased) {
        case (true, true): .accessibilityHighContrastDarkAqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (false, false): .aqua
        }
        let drawing = NSAppearance(named: name) ?? NSApp.effectiveAppearance
        drawing.performAsCurrentDrawingAppearance {
            settings["accent"] = Self.css(.controlAccentColor)
            settings["selection"] = Self.css(.selectedTextBackgroundColor)
            settings["inactiveSelection"] = Self.css(.unemphasizedSelectedTextBackgroundColor)
            settings["host"] = [
                "text-background": Self.css(.textBackgroundColor),
                "text": Self.css(.textColor),
                "secondary-label": Self.css(.secondaryLabelColor),
                "find-highlight": Self.css(.findHighlightColor),
                "selected-content": Self.css(.selectedContentBackgroundColor),
                "selected-text": Self.css(.alternateSelectedControlTextColor),
                "current-line": Self.css(.quaternarySystemFill),
                "selection-match": Self.css(.unemphasizedSelectedTextBackgroundColor),
            ]
        }
        await keep(.setAppearance, ["a": settings])
    }

    /// A colour as CSS, resolved in the current drawing appearance.
    private static func css(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { String(Int(($0 * 255).rounded())) }
        return "rgb(\(rgb.joined(separator: " ")) / \(c.alphaComponent))"
    }

    /// Keyboard focus to the text, once the web view is in a window.
    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    // ---------- page → host ----------

    private enum PageMessage: String {
        case ready, changed, cursor, scroll, command, findOpen, findClosed, findMatches
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = (body["type"] as? String).flatMap(PageMessage.init) else { return }
        switch type {
        case .changed, .cursor, .scroll:
            if let path = body["path"] as? String, path != openPath { return }
        default:
            break
        }
        switch type {
        case .ready:
            guard restarting else {
                becomeReady()
                return
            }
            restarting = false
            // Before any waiting call resumes. The kept calls are independent,
            // so their order doesn't matter.
            let calls = kept
            Task {
                for (method, args) in calls { await run(method, args) }
                onRestart()
                becomeReady()
            }
        case .changed:
            onChanged()
        case .cursor:
            if let line = body["line"] as? Int { onCursor(line) }
        case .scroll:
            if let line = body["line"] as? Int { onScroll(line) }
        case .command:
            if let id = body["id"] as? String { onCommand(id) }
        case .findOpen:
            onFind(FindQuery(body["query"] as? [String: Any] ?? [:]))
        case .findClosed:
            onFindClosed()
        case .findMatches:
            onFindMatches(FindMatches(index: body["index"] as? Int ?? 0, total: body["total"] as? Int ?? 0,
                                      limited: body["limited"] as? Bool ?? false))
        }
    }

    private func becomeReady() {
        ready = true
        webView.isHidden = false
        whenReady.forEach { $0.resume() }
        whenReady.removeAll()
    }
}

/// The page's `texlocal.command` names.
enum EditorCommand: String {
    case bold, italic, math, displayMath, comment, heading, symbol
    /// A block from web/src/latex-data.js `BLOCK_TEMPLATES`, by id.
    case block
    /// A template with "$0" where the selection goes.
    case inline
    case find, findNext, findPrevious, replaceNext, replaceAll, undo, redo
}

struct EditorAppearance: Hashable {
    var colorScheme: ColorScheme
    var contrast: ColorSchemeContrast
    var palette: EditorPalette
    var font: EditorFont
    var fontSize: Int
}

/// Values are the page's (web/src/embed/editor.js `setAppearance`).
enum EditorPalette: String, CaseIterable, Identifiable {
    /// The editor's own colours, One Dark in dark mode and CodeMirror's in
    /// light, so it isn't named for either.
    case standard = "onedark"
    case xcode

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Default"
        case .xcode: "Xcode"
        }
    }
}

/// Values are the page's (web/src/embed/editor.js `setAppearance`).
enum EditorFont: String, CaseIterable, Identifiable {
    case system, jetbrains

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System Monospaced"
        case .jetbrains: "JetBrains Mono"
        }
    }
}

/// The keys and defaults Settings and the editor share.
enum EditorPrefs {
    static let paletteKey = "editorPalette", fontKey = "editorFont", fontSizeKey = "editorFontSize"
    static let palette = EditorPalette.standard
    static let font = EditorFont.system
    static let fontSize = Int(NSFont.systemFontSize)
}

/// The source's search, as CodeMirror's `SearchQuery` takes it.
struct FindQuery: Equatable {
    var search = ""
    var replace = ""
    var caseSensitive = false
    var regexp = false
    var wholeWord = false

    var dictionary: [String: Any] {
        ["search": search, "replace": replace, "caseSensitive": caseSensitive, "regexp": regexp, "wholeWord": wholeWord]
    }
}

extension FindQuery {
    init(_ spec: [String: Any]) {
        search = spec["search"] as? String ?? ""
        replace = spec["replace"] as? String ?? ""
        caseSensitive = spec["caseSensitive"] as? Bool ?? false
        regexp = spec["regexp"] as? Bool ?? false
        wholeWord = spec["wholeWord"] as? Bool ?? false
    }
}

/// A search's matches: `index` from 1 (0 when the selection isn't one);
/// `limited` when there are more than were counted.
struct FindMatches: Equatable {
    var index = 0
    var total = 0
    var limited = false

    /// "3 of 12", "12 matches", "1 of 5000+", "Not found", or nothing before a search.
    func label(for query: String) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return String(localized: "Not found") }
        let count = "\(total)\(limited ? "+" : "")"
        if index > 0 { return String(localized: "\(index) of \(count)") }
        if limited { return String(localized: "\(count) matches") }
        return String(AttributedString(localized: "^[\(total) match](inflect: true)").characters)
    }
}

/// The texlocal-app: scheme, serving the bundled web/.
private final class WebFiles: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let resources = Bundle.main.resourceURL, let url = task.request.url else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let root = resources.appending(path: "web", directoryHint: .isDirectory)
        let file = root.appending(path: url.path).standardizedFileURL
        // Only files inside web/: the request path is untrusted.
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    /// Each reply is whole and at once: nothing is left to stop.
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
