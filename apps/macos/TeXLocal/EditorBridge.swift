import AppKit
import UniformTypeIdentifiers
import WebKit

/// The CodeMirror editor (web/embed/editor.html) inside a WKWebView: content
/// in native chrome. Host → page calls go through `window.texlocal`; the page
/// posts `changed` / `cursor` / `command` messages back.
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate {
    static let scheme = "texlocal-app"

    let webView: WKWebView
    var onChanged: () -> Void = {}
    var onCursor: (Int) -> Void = { _ in }
    var onCommand: (String) -> Void = { _ in }
    /// The page is back, empty, after its web process died.
    var onRestart: () -> Void = {}

    private var ready = false
    private var restarting = false
    private var whenReady: [CheckedContinuation<Void, Never>] = []
    /// The latest host keys, symbols and appearance, sent again to a page
    /// reloaded after its web process died.
    private var kept: [String: (body: String, args: [String: Any])] = [:]
    private let root = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        controller.add(self, name: "texlocal")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://app/embed/editor.html")!))
    }

    // ---------- host → page ----------

    private func untilReady() async {
        if ready { return }
        await withCheckedContinuation { whenReady.append($0) }
    }

    @discardableResult
    private func js(_ body: String, _ args: [String: Any] = [:]) async -> Any? {
        await untilReady()
        return try? await webView.callAsyncJavaScript(body, arguments: args, contentWorld: .page)
    }

    func open(path: String, text: String) async {
        await js("return texlocal.open(path, text)", ["path": path, "text": text])
    }

    func text() async -> String? {
        await js("return texlocal.getText()") as? String
    }

    func currentLine() async -> Int {
        (await js("return texlocal.currentLine()") as? Int) ?? 1
    }

    func reveal(line: Int) async {
        await js("texlocal.reveal(line)", ["line": line])
    }

    func command(_ name: String, _ arg: String? = nil) async {
        await js("return texlocal.command(name, arg)", ["name": name, "arg": arg as Any? ?? NSNull()])
    }

    func forget(path: String) async {
        await js("texlocal.forget(path)", ["path": path])
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

    func setAppearance(theme: String, palette: String, font: String, fontSize: Int) async {
        let appearance: [String: Any] = ["theme": theme, "palette": palette, "font": font, "fontSize": fontSize]
        await keep("appearance", "texlocal.setAppearance(a)", ["a": appearance])
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    // ---------- page → host ----------

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            if restarting {
                restarting = false
                // Submitted before any waiting call resumes, so they run first.
                for (script, args) in kept.values {
                    webView.callAsyncJavaScript(script, arguments: args, in: nil, in: .page, completionHandler: nil)
                }
                onRestart()
            }
            ready = true
            whenReady.forEach { $0.resume() }
            whenReady.removeAll()
        case "changed":
            onChanged()
        case "cursor":
            if let line = body["line"] as? Int { onCursor(line) }
        case "command":
            if let id = body["id"] as? String { onCommand(id) }
        default:
            break
        }
    }

    // The page's web process died: load the page again, and let `ready`
    // restore what it held.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        restarting = true
        _ = webView.reload()
    }

    // Links in the editor never navigate the editor page itself.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.request.url?.scheme == Self.scheme { return .allow }
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme) {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    // ---------- the texlocal-app: scheme, serving the bundled web/ ----------

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let path = task.request.url?.path ?? ""
        let file = root.appendingPathComponent(path).standardizedFileURL
        // Only files inside web/; the request path is untrusted.
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: task.request.url!, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
