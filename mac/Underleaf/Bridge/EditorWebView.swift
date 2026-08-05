import SwiftUI
import WebKit

// Owns the WKWebView, drives the web editor (Swift → JS), and receives editor
// events (JS → Swift). One instance lives in AppModel so the native toolbar can
// call into it.
final class EditorController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    weak var model: AppModel?

    // WKUserContentController retains its handlers; registering a weak proxy
    // instead of `self` avoids a permanent retain cycle through the web view.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
            target?.userContentController(ucc, didReceive: msg)
        }
    }

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: SchemeHandler.scheme)
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        for name in ["save", "state", "syncClick"] {
            webView.configuration.userContentController.add(WeakHandler(self), name: name)
        }
        webView.underPageBackgroundColor = .clear // transparent, so vibrancy shows
        webView.load(URLRequest(url: URL(string: "\(SchemeHandler.scheme)://app/embed.html")!))
    }

    // MARK: Swift → web
    private func js(_ code: String) { webView.evaluateJavaScript(code, completionHandler: nil) }
    private func json(_ v: some Encodable) -> String {
        (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null"
    }

    func open(projectId: String, path: String, content: String, dark: Bool) {
        js("window.TeXLocal && TeXLocal.open(\(json(projectId)), \(json(path)), \(json(content)), \(dark))")
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
    // WebKit delivers these on the main thread; AppModel is @MainActor.
    func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            switch msg.name {
            case "save":
                if let project = body["project"] as? String,
                   let path = body["path"] as? String, let content = body["content"] as? String {
                    model?.saveFile(project: project, path: path, content: content)
                }
            case "state":
                model?.setDirty((body["dirty"] as? Bool) ?? false, project: body["project"] as? String)
            case "syncClick":
                if let page = body["page"] as? Int, let x = body["x"] as? Double, let y = body["y"] as? Double {
                    model?.inverseSync(page: page, x: x, y: y)
                }
            default: break
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { model?.webViewReady() }
    }
}

struct EditorWebView: NSViewRepresentable {
    let controller: EditorController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
