import AppKit
import Observation
import UniformTypeIdentifiers
import WebKit

/// The CodeMirror editor (web/embed/editor.html) in a SwiftUI `WebPage`:
/// content in native chrome. Host → page calls go through
/// `window.texlocal`; the page posts `changed` / `cursor` / `command`
/// messages back.
@MainActor
@Observable
final class EditorBridge: NSObject, WKScriptMessageHandler {
    static let scheme = "texlocal-app"

    /// The page, shown by `EditorView`'s `WebView`; it outlives any one
    /// view, moving between projects.
    let page: WebPage
    /// Bumped to ask the editor's view to take keyboard focus.
    private(set) var focusRequest = 0
    @ObservationIgnored var onChanged: () -> Void = {}
    @ObservationIgnored var onCursor: (Int) -> Void = { _ in }
    /// The line at the top of the view, as it scrolls.
    @ObservationIgnored var onScroll: (Int) -> Void = { _ in }
    @ObservationIgnored var onCommand: (String) -> Void = { _ in }
    /// The page opened its search (⌘F, or Find Next with nothing to find),
    /// with the query it starts from: the find bar is the host's.
    @ObservationIgnored var onFind: (FindQuery) -> Void = { _ in }
    /// The page closed its search (Escape in the text).
    @ObservationIgnored var onFindClosed: () -> Void = {}
    /// Where the selection is among the search's matches, as it changes.
    @ObservationIgnored var onFindMatches: (FindMatches) -> Void = { _ in }
    /// The page's web process died, taking the editor's text with it.
    @ObservationIgnored var onCrash: () -> Void = {}
    /// The page is back, empty, after its web process died.
    @ObservationIgnored var onRestart: () -> Void = {}
    /// How many times the web process has died.
    @ObservationIgnored private(set) var crashes = 0

    @ObservationIgnored private var ready = false
    @ObservationIgnored private var restarting = false
    @ObservationIgnored private var whenReady: [CheckedContinuation<Void, Never>] = []
    /// The latest host keys, symbols and appearance, sent again to a page
    /// reloaded after its web process died.
    @ObservationIgnored private var kept: [String: (body: String, args: [String: Any])] = [:]
    /// The last appearance from Settings, sent again with fresh system
    /// colours when the user changes the accent or highlight colour.
    @ObservationIgnored private var appearance: (theme: String, palette: String, font: String, fontSize: Int)?

    override init() {
        var config = WebPage.Configuration()
        config.urlSchemeHandlers[URLScheme(Self.scheme)!] = WebFiles()
        let controller = WKUserContentController()
        config.userContentController = controller
        page = WebPage(configuration: config, navigationDecider: Links())
        super.init()
        controller.add(self, name: "texlocal")
        #if DEBUG
        // Safari's Web Inspector, for the embed's styling.
        page.isInspectable = true
        #endif
        NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let a = self.appearance else { return }
                Task { await self.setAppearance(theme: a.theme, palette: a.palette, font: a.font, fontSize: a.fontSize) }
            }
        }
        page.load(URL(string: "\(Self.scheme)://app/embed/editor.html")!)
        Task { await watchForCrashes() }
    }

    /// The page's web process died: load the page again, and let `ready`
    /// restore what it held.
    private func watchForCrashes() async {
        while true {
            do {
                for try await _ in page.navigations {}
            } catch WebPage.NavigationError.webContentProcessTerminated {
                ready = false
                restarting = true
                crashes += 1
                onCrash()
                page.reload()
            } catch {}
        }
    }

    // ---------- host → page ----------

    private func untilReady() async {
        if ready { return }
        await withCheckedContinuation { whenReady.append($0) }
    }

    @discardableResult
    private func js(_ body: String, _ args: [String: Any] = [:]) async -> Any? {
        await untilReady()
        return try? await page.callJavaScript(body, arguments: args, contentWorld: .page)
    }

    /// `focus` false leaves keyboard focus where it is, as choosing a file
    /// in the sidebar should.
    func open(path: String, text: String, focus: Bool = true) async {
        await js("return texlocal.open(path, text, 0, focus)", ["path": path, "text": text, "focus": focus])
    }

    func text() async -> String? {
        await js("return texlocal.getText()") as? String
    }

    func currentLine() async -> Int {
        (await js("return texlocal.currentLine()") as? Int) ?? 1
    }

    /// `atTop` puts the line at the top of the view, as an outline's jump
    /// does; otherwise it is centred. `focus` false leaves keyboard focus
    /// where it is.
    func reveal(line: Int, atTop: Bool = false, focus: Bool = true) async {
        await js("texlocal.reveal(line, atTop, focus)", ["line": line, "atTop": atTop, "focus": focus])
    }

    /// False when the page did not run the command.
    @discardableResult
    func command(_ name: String, _ arg: String? = nil) async -> Bool {
        (await js("return texlocal.command(name, arg)", ["name": name, "arg": arg as Any? ?? NSNull()]) as? Bool) ?? false
    }

    func forget(path: String) async {
        await js("texlocal.forget(path)", ["path": path])
    }

    func rename(from: String, to: String) async {
        await js("texlocal.rename(from, to)", ["from": from, "to": to])
    }

    /// A call whose effect the page holds on to, kept to be made again.
    private func keep(_ key: String, _ body: String, _ args: [String: Any]) async {
        kept[key] = (body, args)
        await js(body, args)
    }

    func setSymbols(_ symbols: Symbols) async {
        await keep("symbols", "texlocal.setSymbols(labels, citations)", ["labels": symbols.labels, "citations": symbols.citations])
    }

    func setHostKeys(_ keys: [(id: String, accel: String)]) async {
        let list = keys.map { ["id": $0.id, "accel": $0.accel] }
        await keep("hostKeys", "texlocal.setHostKeys(list)", ["list": list])
    }

    /// The find bar is native: the page's search runs from it, and
    /// CodeMirror's own panel stays hidden.
    func useHostFind() async {
        await keep("hostFind", "texlocal.setHostFind(true)", [:])
    }

    /// The find bar's query, which the page searches for as it changes.
    func setFind(_ query: FindQuery) async {
        await js("texlocal.setFind(q)", ["q": query.dictionary])
    }

    func closeFind() async {
        await js("texlocal.closeFind()")
    }

    /// Settings' theme and font, with the user's accent and highlight
    /// colours for the caret and the selection, as native text views take
    /// them, and the system's colours for the text's surface, the gutter,
    /// find matches and completion lists, so the editor sits on the same
    /// surface as the native chrome around it. The colours are resolved in
    /// the theme's appearance.
    func setAppearance(theme: String, palette: String, font: String, fontSize: Int) async {
        appearance = (theme, palette, font, fontSize)
        var colors: [String: String] = [:]
        var host: [String: String] = [:]
        let drawing = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
        drawing.performAsCurrentDrawingAppearance {
            colors = [
                "accent": Self.css(.controlAccentColor),
                "selection": Self.css(.selectedTextBackgroundColor),
                "inactiveSelection": Self.css(.unemphasizedSelectedTextBackgroundColor),
            ]
            host = [
                "text-background": Self.css(.textBackgroundColor),
                "text": Self.css(.textColor),
                "secondary-label": Self.css(.secondaryLabelColor),
                "find-highlight": Self.css(.findHighlightColor),
                "selected-content": Self.css(.selectedContentBackgroundColor),
                "selected-text": Self.css(.alternateSelectedControlTextColor),
                // The current line and other occurrences of the selection,
                // a faint neutral fill as Xcode draws them (editor.html's
                // :root[data-host] rules use them once the web side does).
                "current-line": Self.css(.quaternarySystemFill),
                "selection-match": Self.css(.unemphasizedSelectedTextBackgroundColor),
            ]
        }
        let settings: [String: Any] = ["theme": theme, "palette": palette, "font": font, "fontSize": fontSize, "host": host]
        await keep("appearance", "texlocal.setAppearance(a)", ["a": settings.merging(colors) { $1 }])
    }

    /// A colour as CSS, resolved in the current drawing appearance.
    private static func css(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { String(Int(($0 * 255).rounded())) }
        return "rgb(\(rgb.joined(separator: " ")) / \(c.alphaComponent))"
    }

    func focus() {
        focusRequest += 1
    }

    // ---------- page → host ----------

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            guard restarting else {
                becomeReady()
                return
            }
            restarting = false
            // Made again, in order, before any waiting call resumes.
            let calls = Array(kept.values)
            Task {
                for (script, args) in calls {
                    _ = try? await page.callJavaScript(script, arguments: args, contentWorld: .page)
                }
                onRestart()
                becomeReady()
            }
        case "changed":
            onChanged()
        case "cursor":
            if let line = body["line"] as? Int { onCursor(line) }
        case "scroll":
            if let line = body["line"] as? Int { onScroll(line) }
        case "command":
            if let id = body["id"] as? String { onCommand(id) }
        case "findOpen":
            onFind(FindQuery(body["query"] as? [String: Any] ?? [:]))
        case "findClosed":
            onFindClosed()
        case "findMatches":
            onFindMatches(FindMatches(index: body["index"] as? Int ?? 0, total: body["total"] as? Int ?? 0,
                                      limited: body["limited"] as? Bool ?? false))
        default:
            break
        }
    }

    private func becomeReady() {
        ready = true
        whenReady.forEach { $0.resume() }
        whenReady.removeAll()
    }
}

/// Links in the editor never navigate the editor page itself: web and
/// mail links open in their apps.
private struct Links: WebPage.NavigationDeciding {
    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        if action.request.url?.scheme == EditorBridge.scheme { return .allow }
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme) {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
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

/// How many matches the search has, and which one is selected (from 1; 0
/// when the selection is not a match). `limited`: there are more than the
/// page counts.
struct FindMatches: Equatable {
    var index = 0
    var total = 0
    var limited = false

    /// "3 of 12", "12 matches" when none is selected, "Not found", or
    /// nothing before a search.
    func label(for query: String) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return "Not found" }
        let count = "\(total)\(limited ? "+" : "")"
        if index > 0 { return "\(index) of \(count)" }
        return total == 1 && !limited ? "1 match" : "\(count) matches"
    }
}

/// The texlocal-app: scheme, serving the bundled web/.
private struct WebFiles: URLSchemeHandler {
    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let root = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
            let file = root.appendingPathComponent(request.url?.path ?? "").standardizedFileURL
            // Only files inside web/; the request path is untrusted.
            guard let url = request.url, file.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  let data = try? Data(contentsOf: file) else {
                continuation.finish(throwing: URLError(.fileDoesNotExist))
                return
            }
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            continuation.yield(.response(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)))
            continuation.yield(.data(data))
            continuation.finish()
        }
    }
}
