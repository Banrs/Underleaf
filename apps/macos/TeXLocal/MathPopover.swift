import AppKit
import WebKit

/// The maths at the caret, typeset, in the system's popover over where it
/// starts, as the web's editor shows it: KaTeX (Resources/KaTeX, the web's
/// build) in a web view that never takes a click or the keyboard.
final class MathPopover: NSObject, WKNavigationDelegate {
    private let popover = NSPopover()
    private let webView = PassiveWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    private var loaded = false
    /// The maths asked for, where, and what the popover shows.
    private var wanted: (maths: MathPreview, size: CGFloat, rect: NSRect, view: NSView)?
    private var rendered: (maths: MathPreview, size: CGFloat)?

    override init() {
        super.init()
        // The popover's material shows through: WebKit has no public switch for it.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        popover.behavior = .applicationDefined
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = webView
        if let folder = Bundle.main.url(forResource: "KaTeX", withExtension: nil) {
            webView.loadHTMLString(Self.page, baseURL: folder)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        update()
    }

    /// Shows `maths` at `size` points, pointing at `rect` of `view`.
    func show(_ maths: MathPreview, size: CGFloat, at rect: NSRect, of view: NSView) {
        wanted = (maths, size, rect, view)
        // Moved only while it shows (AppKit raises otherwise).
        if popover.isShown { popover.positioningRect = rect }
        if rendered?.maths == maths, rendered?.size == size {
            if !popover.isShown { popover.show(relativeTo: rect, of: view, preferredEdge: .minY) }
        } else {
            update()
        }
    }

    func close() {
        wanted = nil
        if popover.isShown { popover.close() }
    }

    private func update() {
        guard loaded, let asked = wanted else { return }
        Task {
            let box = try? await webView.callAsyncJavaScript("return render(tex, display, size)",
                arguments: ["tex": asked.maths.tex, "display": asked.maths.display, "size": asked.size],
                contentWorld: .page) as? [Double]
            // Superseded meanwhile, or closed.
            guard let box, box.count == 2, let wanted, wanted.maths == asked.maths, wanted.size == asked.size else { return }
            rendered = (asked.maths, asked.size)
            popover.contentSize = NSSize(width: box[0], height: box[1])
            if !popover.isShown { popover.show(relativeTo: wanted.rect, of: wanted.view, preferredEdge: .minY) }
        }
    }

    /// The typeset maths in the label colour, as wide as it is (560 pt at
    /// most, the web's), with the web tooltip's padding.
    private static let page = """
        <!doctype html><meta charset="utf-8">
        <link rel="stylesheet" href="katex.min.css"><script src="katex.min.js"></script>
        <style>
          :root { color-scheme: light dark; }
          html, body { margin: 0; background: transparent; color: -apple-system-label; }
          #m { width: max-content; max-width: 560px; padding: 8px 16px; }
          .katex-display { margin: 0; }
        </style>
        <div id="m"></div>
        <script>
          async function render(tex, display, size) {
            const m = document.getElementById('m');
            m.style.fontSize = size + 'px';
            katex.render(tex, m, { displayMode: display, throwOnError: false, strict: false });
            // Measured in KaTeX's fonts, which a layout starts loading.
            m.getBoundingClientRect();
            await document.fonts.ready;
            const box = m.getBoundingClientRect();
            return [Math.ceil(box.width), Math.ceil(box.height)];
          }
        </script>
        """
}

/// A web view to look at only: clicks go through it and it never has the keyboard.
private final class PassiveWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
