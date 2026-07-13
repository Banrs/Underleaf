import SwiftUI
import WebKit

// Owns the WKWebView, drives the web editor (Swift → JS), and receives editor
// events (JS → Swift). One instance lives in AppModel so the native toolbar can
// call into it.
final class EditorController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    weak var model: AppModel?
    @Published var ready = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: SchemeHandler.scheme)
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // Placeholder — the real handlers/init are attached in configure().
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        for name in ["save", "state", "syncClick"] {
            cfg.userContentController.add(self, name: name)
        }
        webView.setValue(false, forKey: "drawsBackground") // transparent, so vibrancy shows
        webView.load(URLRequest(url: URL(string: "\(SchemeHandler.scheme)://app/embed.html")!))
    }

    // MARK: Swift → web
    private func js(_ code: String) { webView.evaluateJavaScript(code, completionHandler: nil) }
    private func json(_ v: some Encodable) -> String {
        (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null"
    }

    func open(path: String, content: String, dark: Bool) {
        js("window.TeXLocal && TeXLocal.open(\(json(path)), \(json(content)), \(dark))")
    }
    func reloadPDF(projectId: String) {
        js("window.TeXLocal && TeXLocal.reloadPdf(\(json("\(SchemeHandler.scheme)://app/__pdf/\(projectId)")))")
    }
    func format(_ kind: String) { js("window.TeXLocal && TeXLocal.format(\(json(kind)))") }
    func undo() { js("window.TeXLocal && TeXLocal.undo()") }
    func redo() { js("window.TeXLocal && TeXLocal.redo()") }
    func find() { js("window.TeXLocal && TeXLocal.find()") }
    func setDark(_ dark: Bool) { js("window.TeXLocal && TeXLocal.setDark(\(dark))") }
    func gotoLine(_ line: Int) { js("window.TeXLocal && TeXLocal.gotoLine(\(line))") }

    // MARK: web → Swift
    func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any] else { return }
        switch msg.name {
        case "save":
            if let path = body["path"] as? String, let content = body["content"] as? String {
                model?.saveFile(path: path, content: content)
            }
        case "state":
            model?.dirty = (body["dirty"] as? Bool) ?? false
        case "syncClick":
            if let page = body["page"] as? Int, let x = body["x"] as? Double, let y = body["y"] as? Double {
                model?.inverseSync(page: page, x: x, y: y)
            }
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        model?.webViewReady()
    }
}

struct EditorWebView: NSViewRepresentable {
    let controller: EditorController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
