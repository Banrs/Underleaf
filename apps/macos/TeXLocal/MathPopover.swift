import AppKit
import SwiftUI

/// The maths at the caret, as the core draws it (RaTeX's SVG, `math_svg`), drawn off the main actor as the caret moves.
final class MathPopover {
    private let popover = NSPopover()
    private let content = NSHostingController(rootView: MathView())
    private var wanted: (maths: MathPreview, size: CGFloat, rect: NSRect, view: NSView, edge: NSRectEdge)?
    private var rendered: (maths: MathPreview, size: CGFloat)?
    /// One drawing at a time, until it's what's wanted.
    private var rendering: Task<Void, Never>?

    init() {
        popover.behavior = .applicationDefined
        // It follows the caret in and out of maths as the person types.
        popover.animates = false
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
    }

    func show(_ maths: MathPreview, size: CGFloat, at rect: NSRect, of view: NSView, edge: NSRectEdge) {
        wanted = (maths, size, rect, view, edge)
        if isRendered {
            present()
        } else if rendering == nil {
            rendering = Task { await render() }
        }
    }

    private var isRendered: Bool { rendered?.maths == wanted?.maths && rendered?.size == wanted?.size }

    /// Unconditionally: `isShown` stays true while a closed popover animates out, and a show then brings it back.
    private func present() { if let wanted { popover.show(relativeTo: wanted.rect, of: wanted.view, preferredEdge: wanted.edge) } }

    var isWanted: Bool { wanted != nil }

    func close() {
        wanted = nil
        if popover.isShown { popover.close() }
    }

    private func render() async {
        defer { rendering = nil }
        while let asked = wanted, !isRendered {
            let em = asked.size * 1.21
            let drawing = await Self.draw(asked.maths.tex, display: asked.maths.display, size: Double(em))
            guard wanted?.maths == asked.maths, wanted?.size == asked.size else { continue }
            rendered = (asked.maths, asked.size)
            // Only a change of size between two drawings is eased, so it isn't taken for a new popover (HIG, Popovers).
            popover.animates = popover.isShown
            content.rootView = MathView(tex: asked.maths.tex, em: em, image: drawing.flatMap { NSImage(drawing: $0) })
            popover.animates = false
            present()
        }
    }

    @concurrent private nonisolated static func draw(_ tex: String, display: Bool, size: Double) async -> Syntax.Drawing? {
        Syntax.call("math_svg", ["tex": tex, "display": display, "size": size])
    }
}

extension NSImage {
    /// The core's SVG at its size in points, drawn sharp at the screen's scale.
    convenience init?(drawing: Syntax.Drawing) {
        guard let svg = drawing.svg, let width = drawing.width, let height = drawing.height else { return nil }
        self.init(data: Data(svg.utf8))
        size = NSSize(width: width, height: height)
    }
}
