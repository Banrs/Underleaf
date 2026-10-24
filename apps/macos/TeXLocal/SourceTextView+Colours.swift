import AppKit

/// The fragments coloured anew, and the bracket partner's mark.
extension SourceTextView {
    /// New rendering attributes don't redraw the fragments' own views, nor does the text view's display.
    /// No test sees it: an offscreen window's own display pass clears what is marked, and `cacheDisplay` draws all anew.
    func redrawFragments(in rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        func redraw(_ view: NSView) {
            let frame = view.convert(view.bounds, to: self)
            guard rects.contains(where: { $0.intersects(frame) }) else { return }
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        subviews.filter { !($0 is IssueMessageView) }.forEach(redraw)
    }

    /// The find indicator bounces: with Reduce Motion the partner in sight is filled in place until the selection next
    /// changes, by the view, since TextKit drops a rendering attribute as it lays the fragment out again.
    func showPartner(of at: Int) {
        guard at >= 0, at < length, let i = document.partner(of: at) else { return }
        let range = NSRange(location: i, length: 1)
        guard let rect = segments(range), visibleRect.intersects(rect) else { return }
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return showFindIndicator(for: range) }
        mark(range)
    }

    func mark(_ range: NSRange?) {
        for rect in [partnerDrawn, range.flatMap(segments)] { if let rect { setNeedsDisplay(rect) } }
        (partnerMark, partnerDrawn) = (range, nil)
    }

    func drawPartner(in rect: NSRect) {
        partnerDrawn = partnerMark.flatMap(segments)
        guard let partnerDrawn, partnerDrawn.intersects(rect) else { return }
        NSColor.unemphasizedSelectedTextBackgroundColor.setFill()
        partnerDrawn.fill()
    }
}
