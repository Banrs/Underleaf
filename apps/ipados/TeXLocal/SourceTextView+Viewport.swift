import UIKit

/// What of the text shows and where it scrolls to, from the fragments TextKit 2 last laid out in the viewport.
extension SourceTextView {
    /// The bounds less the insets for the bars over the text and the keyboard under it.
    var shownRect: CGRect { bounds.inset(by: adjustedContentInset) }

    /// From the fragments last laid out: asked by point, TextKit answers from its new estimates.
    var shownTop: (offset: Int, below: CGFloat)? {
        guard let top = fragment(under: shownRect.minY) else { return nil }
        return (offset(top.rangeInElement.location), top.layoutFragmentFrame.minY + textContainerInset.top - contentOffset.y)
    }

    /// The line half a line under the shown text's top; nil until the fragments laid out reach there (`laidOut`).
    var topLine: Int? {
        let y = shownRect.minY + (font?.lineHeight ?? 0) / 2
        guard let top = fragment(under: y), top.layoutFragmentFrame.minY + textContainerInset.top <= y else { return nil }
        return document.line(at: offset(top.rangeInElement.location))
    }

    /// The first fragment laid out that reaches below `y`.
    private func fragment(under y: CGFloat) -> NSTextLayoutFragment? {
        fragments.first { $0.fragment.layoutFragmentFrame.maxY + textContainerInset.top > y }?.fragment
    }

    /// The caret's line in the middle of what shows: far from the viewport TextKit has only estimated the heights above.
    func centerSelection() {
        guard let manager = textLayoutManager, let location = textRange(.caret(selectedRange.location))?.location else { return }
        let middle = shownRect.midY - contentOffset.y
        scroll(location) { [unowned self] paragraph in
            guard let fragment = manager.textLayoutFragment(for: location) else { return paragraph.midY - middle }
            let inParagraph = offset(location) - offset(fragment.rangeInElement.location)
            let line = fragment.textLineFragments.last { $0.characterRange.location <= inParagraph } ?? fragment.textLineFragments.first
            return paragraph.minY + (line?.typographicBounds.midY ?? paragraph.height / 2) - middle
        }
    }

    /// Laid out first: far from the viewport the range has no rect yet, and the estimates above it settle as it's shown.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let manager = textLayoutManager, let target = textRange(range) else { return super.scrollRangeToVisible(range) }
        for _ in 0..<2 {
            manager.ensureLayout(for: target)
            super.scrollRangeToVisible(range)
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    func scroll(toShownTop top: (offset: Int, below: CGFloat)) {
        guard let location = textRange(.caret(min(top.offset, length)))?.location else { return }
        scroll(location) { $0.minY - top.below }
    }

    /// The paragraph at `offset` at the shown text's top.
    func scroll(toTop offset: Int) { scroll(toShownTop: (offset, shownRect.minY - contentOffset.y)) }

    /// Lays out only that paragraph, in two passes, as the estimates above it settle; `y` is the offset for its frame.
    func scroll(_ location: any NSTextLocation, to y: (CGRect) -> CGFloat) {
        guard let manager = textLayoutManager, window != nil else { return }
        for _ in 0..<2 {
            manager.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = manager.textLayoutFragment(for: location) else { return }
            let wanted = y(fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerInset.top))
            let least = -adjustedContentInset.top
            let most = max(least, contentSize.height + adjustedContentInset.bottom - bounds.height)
            contentOffset.y = min(max(wanted, least), most)
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    /// What floats over the text follows a scroll: TextKit lays the viewport out again only past what it had laid out.
    func scrolled() {
        completions.follow()
        previewMath()
    }

    override func textViewportLayoutControllerWillLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerWillLayout(controller)
        fragments.removeAll(keepingCapacity: true)
    }

    override func textViewportLayoutController(_ controller: NSTextViewportLayoutController,
                                               configureRenderingSurfaceFor fragment: NSTextLayoutFragment) {
        super.textViewportLayoutController(controller, configureRenderingSurfaceFor: fragment)
        fragments.append((offset(fragment.rangeInElement.location), fragment))
    }

    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        fragments.sort { $0.offset < $1.offset }
        if let from = staleColours { colour(from: from) }
        completions.follow()
        issues.place()
        redrawLineAndGutter()
        checkSpellingSoon()
        laidOut()
    }
}
