import AppKit
import SwiftUI
import WebKit

/// The maths at the caret, typeset, in the system's popover over where it
/// starts: KaTeX (Resources/KaTeX) in a web view that never takes a click or
/// the keyboard.
final class MathPopover {
    private let popover = NSPopover()
    private let page = WebPage()
    private let content: NSHostingController<MathView>
    private var loaded = false
    /// The maths asked for, where, and what the popover shows.
    private var wanted: (maths: MathPreview, size: CGFloat, rect: NSRect, view: NSView)?
    private var rendered: (maths: MathPreview, size: CGFloat)?
    private var rendering = false

    init() {
        content = NSHostingController(rootView: MathView(page: page))
        popover.behavior = .applicationDefined
        popover.contentViewController = content
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
        guard loaded, !rendering, let asked = wanted else { return }
        rendered = nil
        rendering = true
        Task {
            let box = try? await page.callJavaScript("return render(tex, display, size)",
                arguments: ["tex": asked.maths.tex, "display": asked.maths.display, "size": asked.size]) as? [Double]
            rendering = false
            guard let wanted else { return }
            // Skip intermediate requests.
            guard wanted.maths == asked.maths, wanted.size == asked.size else { update(); return }
            guard let box, box.count == 2 else { return }
            rendered = (asked.maths, asked.size)
            content.rootView.size = CGSize(width: box[0], height: box[1])
            popover.contentSize = content.view.fittingSize
            present()
        }
    }

    /// The typeset maths in the label colour, as wide as it is (560 pt at
    /// most), with no margin of its own.
    private static let html = """
        <!doctype html><meta charset="utf-8">
        <link rel="stylesheet" href="katex.min.css"><script src="katex.min.js"></script>
        <style>
          :root { color-scheme: light dark; }
          html, body { margin: 0; background: transparent; color: -apple-system-label; }
          #m { width: max-content; max-width: 560px; }
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

/// The maths in the system's margins, at least as wide as it's tall: a single
/// letter is a rounded square, not an egg. The popover's material shows
/// through; not focusable, or it takes the source's keyboard as it shows.
struct MathView: View {
    let page: WebPage
    var size = CGSize.zero

    var body: some View {
        WebView(page).webViewContentBackground(.hidden).allowsHitTesting(false).focusable(false)
            .frame(width: size.width, height: size.height)
            .frame(minWidth: size.height)
            .padding()
    }
}
