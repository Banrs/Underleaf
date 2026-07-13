import Foundation
import WebKit

// Serves texlocal://app/… to the WKWebView, mirroring the Electron protocol so the
// web frontend's URLs (pdf.js worker, __pdf, __raw images) work unchanged:
//   texlocal://app/embed.html           → bundled web asset
//   texlocal://app/dist/bundle-embed.js → bundled web asset
//   texlocal://app/__pdf/<id>           → the project's compiled PDF
//   texlocal://app/__raw/<id>/<relpath> → a raw project file (e.g. an image)
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "texlocal"

    // web/ is bundled as a folder reference (see project.yml).
    private let webDir = Bundle.main.resourceURL!.appendingPathComponent("web")

    private static let mime: [String: String] = [
        "html": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "map": "application/json", "json": "application/json", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "pdf": "application/pdf", "woff2": "font/woff2", "ico": "image/x-icon",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app" else { return fail(task, 404) }
        let segs = url.path.split(separator: "/").map(String.init)
        do {
            let fileURL: URL
            if segs.first == "__pdf", segs.count >= 2 {
                fileURL = ProjectStore.compiledPdfPath(try ProjectStore.projectRoot(segs[1]))
            } else if segs.first == "__raw", segs.count >= 3 {
                let root = try ProjectStore.projectRoot(segs[1])
                fileURL = try ProjectStore.safePath(root, segs.dropFirst(2).joined(separator: "/"))
            } else {
                let rel = segs.isEmpty ? "index.html" : segs.joined(separator: "/")
                fileURL = webDir.appendingPathComponent(rel)
                guard fileURL.standardizedFileURL.path.hasPrefix(webDir.path) else { return fail(task, 400) }
            }
            guard let data = try? Data(contentsOf: fileURL) else { return fail(task, 404) }
            let type = Self.mime[fileURL.pathExtension.lowercased()] ?? "application/octet-stream"
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Cache-Control": "no-store",
                                                      "Access-Control-Allow-Origin": "*"])!
            task.didReceive(resp)
            task.didReceive(data)
            task.didFinish()
        } catch {
            fail(task, 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, _ status: Int) {
        let resp = HTTPURLResponse(url: task.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        task.didReceive(resp); task.didFinish()
    }
}
