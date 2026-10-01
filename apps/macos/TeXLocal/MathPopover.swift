import AppKit
import SwiftUI
import WebKit

/// The maths at the caret, typeset, in the system's popover over where it
/// starts, as the web's editor shows it: KaTeX (Resources/KaTeX, the web's
/// build) in a web view that never takes a click or the keyboard.
@MainActor final class MathPopover {
    private let popover = NSPopover()
    private let page = WebPage()
    private let content: NSHostingController<MathView>
    private var loadTask: Task<Void, Never>?
    private var loaded = false
    private var closing = false
    /// The maths asked for, where, and what the popover shows.
    private var wanted: (maths: MathPreview, size: CGFloat, rect: NSRect)?
    private weak var anchorView: NSView?
    private var rendered: (maths: MathPreview, size: CGFloat)?
    private var renderRevision = 0
    private var renderTask: Task<Void, Never>?

    private struct RenderRequest {
        let maths: MathPreview
        let size: CGFloat
        let revision: Int
    }

    init() {
        content = NSHostingController(rootView: MathView(page: page))
        popover.behavior = .applicationDefined
        popover.contentViewController = content
        if let folder = Bundle.main.url(forResource: "KaTeX", withExtension: nil) {
            // A failed load leaves it unloaded: no preview.
            let page = page
            loadTask = Task { [weak self, page] in
                defer { self?.loadTask = nil }
                do {
                    for try await _ in page.load(html: Self.html, baseURL: folder) {}
                    guard !Task.isCancelled else { return }
                    self?.pageDidLoad()
                } catch {}
            }
        }
    }

    isolated deinit {
        loadTask?.cancel()
        renderTask?.cancel()
        if popover.isShown, !closing { popover.close() }
    }

    private func pageDidLoad() {
        loaded = true
        update()
    }

    /// Shows `maths` at `size` points, pointing at `rect` of `view`.
    func show(_ maths: MathPreview, size: CGFloat, at rect: NSRect, of view: NSView) {
        if wanted?.maths != maths || wanted?.size != size {
            renderRevision += 1
            rendered = nil
        }
        wanted = (maths, size, rect)
        anchorView = view
        if rendered?.maths == maths, rendered?.size == size {
            present()
        } else {
            update()
        }
    }

    /// Shown, or moved while it shows. Unconditionally: `isShown` stays true
    /// while a closed popover animates out, and a show then brings it back.
    private func present() {
        guard let wanted, let anchorView else {
            close()
            return
        }
        closing = false
        popover.show(relativeTo: wanted.rect, of: anchorView, preferredEdge: .minY)
    }

    func close() {
        guard wanted != nil else { return }
        wanted = nil
        anchorView = nil
        renderRevision += 1
        rendered = nil
        guard popover.isShown, !closing else { return }
        closing = true
        popover.close()
    }

    private func update() {
        guard loaded, wanted != nil, renderTask == nil else { return }
        let page = page
        renderTask = Task { [weak self, page] in
            defer { self?.renderTask = nil }
            while let request = self?.nextRender() {
                let box = try? await page.callJavaScript("return render(tex, display, size)",
                    arguments: ["tex": request.maths.tex, "display": request.maths.display, "size": request.size]) as? [Double]
                guard self?.finishRender(request, box: box) == true else { break }
            }
        }
    }

    private func nextRender() -> RenderRequest? {
        guard loaded, let wanted else { return nil }
        return RenderRequest(maths: wanted.maths, size: wanted.size, revision: renderRevision)
    }

    /// Returns true only when a newer request must use this same serial worker.
    private func finishRender(_ request: RenderRequest, box: [Double]?) -> Bool {
        guard request.revision == renderRevision, let wanted,
              wanted.maths == request.maths, wanted.size == request.size else {
            rendered = nil
            return true
        }
        guard let box, box.count == 2 else { return false }
        rendered = (request.maths, request.size)
        content.rootView.size = CGSize(width: box[0], height: box[1])
        popover.contentSize = content.view.fittingSize
        present()
        return false
    }

    /// The typeset maths in the label colour, as wide as it is (560 pt at
    /// most, the web's), with no margin of its own.
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

/// The maths in the system's margins, without taking the source's keyboard.
struct MathView: View {
    let page: WebPage
    var size = CGSize.zero

    var body: some View {
        WebView(page).webViewContentBackground(.hidden).allowsHitTesting(false).focusable(false)
            .frame(width: size.width, height: size.height)
            .padding()
    }
}
