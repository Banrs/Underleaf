import AppKit
import SwiftUI

final class MathPopover {
    private let popover = NSPopover()
    private let content = NSHostingController(rootView: MathView())
    private var wanted: (maths: MathPreview, size: CGFloat, rect: NSRect, view: NSView, edge: NSRectEdge)?
    private var rendered: (maths: MathPreview, size: CGFloat)?
    private var rendering: Task<Void, Never>?

    init() {
        popover.behavior = .applicationDefined
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
    convenience init?(drawing: Syntax.Drawing) {
        guard let svg = drawing.svg, let width = drawing.width, let height = drawing.height else { return nil }
        self.init(data: Data(svg.utf8))
        size = NSSize(width: width, height: height)
    }
}
