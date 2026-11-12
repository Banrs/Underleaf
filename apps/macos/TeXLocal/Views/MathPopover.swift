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

    @concurrent private nonisolated static func draw(_ tex: String, display: Bool, size: Double) async -> MathSvg? {
        Syntax.call(RenderMath(tex: tex, display: display, size: size)) ?? nil
    }
}

extension NSImage {
    convenience init?(drawing: MathSvg) {
        self.init(data: Data(drawing.svg.utf8))
        size = NSSize(width: drawing.width, height: drawing.height)
    }
}

struct MathView: View {
    var tex = ""
    var em: CGFloat = 0
    var image: NSImage?

    private static let widest: CGFloat = 560

    var body: some View {
        let line = (em * 1.2).rounded(.up)
        Group {
            if let image {
                let scale = min(1, Self.widest / max(image.size.width, 1))
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    // Rounding the frame up to whole points mustn't stretch a small formula one way more than the other.
                    .aspectRatio(contentMode: .fit)
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
