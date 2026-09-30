import AppKit
import SwiftUI
import WebKit

/// The maths at the caret, typeset, in the system's popover over where it
/// starts, as the web's editor shows it: KaTeX (Resources/KaTeX, the web's
/// build) in a web view that never takes a click or the keyboard.
final class MathPopover {
    private let popover = NSPopover()
    private let page = WebPage()
    private var loaded = false
    /// The maths asked for, where, and what the popover shows.
    private var wanted: (maths: MathPreview, size: CGFloat, rect: NSRect, view: NSView)?
    private var rendered: (maths: MathPreview, size: CGFloat)?

    init() {
        popover.behavior = .applicationDefined
        // The popover's material shows through; not focusable, or it takes
        // the source's keyboard as it shows.
        popover.contentViewController = NSHostingController(rootView: WebView(page)
            .webViewContentBackground(.hidden).allowsHitTesting(false).focusable(false))
        if let folder = Bundle.main.url(forResource: "KaTeX", withExtension: nil) {
            // A failed load leaves it unloaded: no preview.
            _ = Task {
                for try await _ in page.load(html: Self.html, baseURL: folder) {}
                loaded = true
                update()
            }
        }
    }

    /// Shows `maths` at `size` points, pointing at `rect` of `view`.
    func show(_ maths: MathPreview, size: CGFloat, at rect: NSRect, of view: NSView) {
        wanted = (maths, size, rect, view)
        if rendered?.maths == maths, rendered?.size == size {
            present()
        } else {
            update()
        }
    }

    /// Shown, or moved while it shows. Unconditionally: `isShown` stays true
    /// while a closed popover animates out, and a show then brings it back.
    private func present() {
        guard let wanted else { return }
        popover.show(relativeTo: wanted.rect, of: wanted.view, preferredEdge: .minY)
    }

    func close() {
        wanted = nil
        if popover.isShown { popover.close() }
    }

    private func update() {
        guard loaded, let asked = wanted else { return }
        Task {
            let box = try? await page.callJavaScript("return render(tex, display, size)",
                arguments: ["tex": asked.maths.tex, "display": asked.maths.display, "size": asked.size]) as? [Double]
            // Superseded meanwhile, or closed.
            guard let box, box.count == 2, let wanted, wanted.maths == asked.maths, wanted.size == asked.size else { return }
            rendered = (asked.maths, asked.size)
            popover.contentSize = NSSize(width: box[0], height: box[1])
            present()
        }
    }

    /// The typeset maths in the label colour, as wide as it is (560 pt at
    /// most, the web's), with the web tooltip's padding.
    private static let html = """
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
