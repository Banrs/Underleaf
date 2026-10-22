import SwiftUI
import UIKit

/// The maths at the caret, as the core draws it (RaTeX's SVG, `math_svg`), drawn off the main actor as the caret moves.
/// Glass over the caret's line, as the Mac's popover is, but a view in the window: a presented popover would come and go
/// with an animation at each step of the caret, and turn into a sheet in a narrow window. It takes no touch, and keeps
/// within what shows of the editor at any width.
final class MathCallout {
    private unowned let editor: SourceTextView
    private lazy var hosting: UIHostingController<Callout> = {
        let hosting = UIHostingController(rootView: Callout())
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        return hosting
    }()
    private var wanted: (maths: MathPreview, size: CGFloat, caret: CGRect, below: Bool)?
    private var rendered: (maths: MathPreview, size: CGFloat)?
    /// One drawing at a time, until it's what's wanted.
    private var rendering: Task<Void, Never>?

    init(for editor: SourceTextView) { self.editor = editor }

    /// Over the caret's line, or under it where the completion list is over it.
    func show(_ maths: MathPreview, size: CGFloat, at caret: CGRect, avoiding listAbove: Bool) {
        wanted = (maths, size, caret, listAbove)
        if isRendered {
            present()
        } else if rendering == nil {
            rendering = Task { await render() }
        }
    }

    private var isRendered: Bool { rendered?.maths == wanted?.maths && rendered?.size == wanted?.size }

    var isWanted: Bool { wanted != nil }

    func close() {
        wanted = nil
        if hosting.isViewLoaded { hosting.view.removeFromSuperview() }
    }

    private func render() async {
        defer { rendering = nil }
        while let asked = wanted, !isRendered {
            let em = asked.size * 1.21
            let drawing = await Self.draw(asked.maths.tex, display: asked.maths.display, size: Double(em))
            guard wanted?.maths == asked.maths, wanted?.size == asked.size else { continue }
            rendered = (asked.maths, asked.size)
            hosting.rootView.maths = MathView(tex: asked.maths.tex, em: em, image: drawing.flatMap { UIImage(drawing: $0) })
            present()
        }
    }

    @concurrent private nonisolated static func draw(_ tex: String, display: Bool, size: Double) async -> Syntax.Drawing? {
        Syntax.call("math_svg", ["tex": tex, "display": display, "size": size])
    }

    private static let margin: CGFloat = 8

    private func present() {
        guard let wanted, let host = editor.superview else { return }
        let shown = host.convert(editor.shownRect, from: editor).insetBy(dx: Self.margin, dy: Self.margin)
        let caret = host.convert(wanted.caret, from: editor)
        // MathView's own padding is inside the room.
        hosting.rootView.maths.widest = min(560, shown.width - 32)
        let fitted = hosting.sizeThatFits(in: CGSize(width: shown.width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(fitted.width, shown.width), height: fitted.height)
        let over = caret.minY - Self.margin - size.height, under = caret.maxY + Self.margin
        let roomOver = over >= shown.minY, roomUnder = under + size.height <= shown.maxY
        let y = (wanted.below ? !roomUnder && roomOver : roomOver || !roomUnder) ? over : under
        let x = max(shown.minX, min(caret.minX - size.width / 2, shown.maxX - size.width))
        hosting.view.frame = CGRect(origin: CGPoint(x: x, y: max(shown.minY, min(y, shown.maxY - size.height))), size: size)
        if hosting.view.superview !== host { host.addSubview(hosting.view) }
    }

    /// The preview on glass with a popover's corners.
    struct Callout: View {
        var maths = MathView()

        var body: some View { maths.glassEffect(.regular, in: .rect(cornerRadius: 22)) }
    }
}
