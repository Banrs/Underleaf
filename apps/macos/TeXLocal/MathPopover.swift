import AppKit
import SwiftUI

/// The maths at the caret, as the core draws it (RaTeX's SVG, `math_svg`), drawn off the main actor as the caret moves.
final class MathPopover {
    private let popover = NSPopover()
    private let content = NSHostingController(rootView: MathView())
    private var wanted: (maths: MathPreview, size: CGFloat, rect: NSRect, view: NSView, edge: NSRectEdge)?
    private var rendered: (maths: MathPreview, size: CGFloat)?
    private var rendering = false

    init() {
        popover.behavior = .applicationDefined
        // It follows the caret in and out of maths as the person types: no motion each time.
        popover.animates = false
        popover.contentViewController = content
    }

    func show(_ maths: MathPreview, size: CGFloat, at rect: NSRect, of view: NSView, edge: NSRectEdge) {
        wanted = (maths, size, rect, view, edge)
        if rendered?.maths == maths, rendered?.size == size {
            present()
        } else {
            update()
        }
    }

    /// Unconditionally: `isShown` stays true while a closed popover animates out, and a show then brings it back.
    private func present() {
        guard let wanted else { return }
        popover.show(relativeTo: wanted.rect, of: wanted.view, preferredEdge: wanted.edge)
    }

    var isShown: Bool { wanted != nil }

    func close() {
        wanted = nil
        if popover.isShown { popover.close() }
    }

    private func update() {
        guard !rendering, let asked = wanted else { return }
        rendered = nil
        rendering = true
        // The maths a little larger than the text, at 1.21 times its size.
        let em = asked.size * 1.21
        Task {
            let drawing = await Self.draw(asked.maths.tex, display: asked.maths.display, size: Double(em))
            rendering = false
            guard let wanted else { return }
            // Skip intermediate requests.
            guard wanted.maths == asked.maths, wanted.size == asked.size else { update(); return }
            rendered = (asked.maths, asked.size)
            content.rootView = MathView(tex: asked.maths.tex, em: em, image: drawing.flatMap { NSImage(drawing: $0) })
            popover.contentSize = content.view.fittingSize
            present()
        }
    }

    @concurrent private nonisolated static func draw(_ tex: String, display: Bool, size: Double) async -> Syntax.Drawing? {
        Syntax.call("math_svg", ["tex": tex, "display": display, "size": size])
    }
}

extension NSImage {
    /// The core's SVG at its size in points: its paths are drawn at the screen's scale, so they stay sharp.
    convenience init?(drawing: Syntax.Drawing) {
        guard let svg = drawing.svg, let width = drawing.width, let height = drawing.height else { return nil }
        self.init(data: Data(svg.utf8))
        size = NSSize(width: width, height: height)
    }
}

/// Not focusable, or it takes the source's keyboard as it shows. Maths the core can't draw shows as its TeX, in red.
struct MathView: View {
    var tex = ""
    var em: CGFloat = 0
    var image: NSImage?

    /// The widest a preview goes: longer maths is shown smaller.
    private static let widest: CGFloat = 560

    var body: some View {
        // At least a line of text high.
        let line = (em * 1.2).rounded(.up)
        Group {
            if let image {
                let scale = min(1, Self.widest / max(image.size.width, 1))
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(.primary)
                    .frame(width: (image.size.width * scale).rounded(.up), height: (image.size.height * scale).rounded(.up))
            } else {
                Text(verbatim: tex).font(.system(size: em)).foregroundStyle(.red).lineLimit(1).frame(maxWidth: Self.widest)
            }
        }
        .frame(minWidth: line, minHeight: line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Math Preview")
        .accessibilityValue(tex)
        .focusable(false)
        .allowsHitTesting(false)
        .padding()
    }
}
