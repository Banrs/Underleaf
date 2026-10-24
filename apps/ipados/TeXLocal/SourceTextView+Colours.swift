import UIKit

/// The core's highlights as TextKit's rendering attributes, and the marks of the bracket partner and what `reveal` found.
extension SourceTextView {
    /// New rendering attributes don't redraw the fragments' own views.
    func redrawFragments(in rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        func redraw(_ view: UIView) {
            let frame = view.convert(view.bounds, to: self)
            guard rects.contains(where: { $0.intersects(frame) }) else { return }
            view.setNeedsDisplay()
            view.subviews.forEach(redraw)
        }
        subviews.filter { !($0 is Underlay || $0 is IssueMessageView || $0 is GutterControl) }.forEach(redraw)
    }

    /// The partner in sight, marked (`mark`).
    func showPartner(of at: Int) {
        guard at >= 0, at < length, let i = document.partner(of: at) else { return }
        let range = NSRange(location: i, length: 1)
        guard let rect = segments(range), shownRect.intersects(rect) else { return }
        mark(range)
    }

    /// UIKit has no find indicator, and shows no selection without the keyboard: the range is filled until the selection
    /// next changes, as the Mac's partner is with Reduce Motion, by the view, since TextKit drops a rendering attribute as it
    /// lays the fragment out again.
    func mark(_ range: NSRange?, found: Bool = false) {
        marked = range.map { ($0, found) }
        underlay.setNeedsDisplay()
    }

    func drawMark(in rect: CGRect) {
        guard let marked, let drawn = segments(marked.range), drawn.intersects(rect) else { return }
        (marked.found ? UIColor.systemYellow.withAlphaComponent(0.4) : .systemFill).setFill()
        UIBezierPath(roundedRect: drawn, cornerRadius: 2).fill()
    }
}
