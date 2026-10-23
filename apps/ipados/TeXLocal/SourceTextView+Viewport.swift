import UIKit

/// What of the text shows and where it scrolls to, from the fragments TextKit 2 last laid out in the viewport.
extension SourceTextView {
    /// The bounds less the insets for the bars over the text and the keyboard under it.
    var shownRect: CGRect { bounds.inset(by: adjustedContentInset) }

    var scrollY: CGFloat? { contentOffset.y }

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
