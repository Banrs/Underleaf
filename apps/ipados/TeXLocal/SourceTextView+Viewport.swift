import UIKit

/// What of the text shows and where it scrolls to, from the fragments TextKit 2 last laid out in the viewport.
extension SourceTextView {
    /// The bounds less the insets for the bars over the text and the keyboard under it.
    var shownRect: CGRect { bounds.inset(by: adjustedContentInset) }

    var scrollY: CGFloat? { contentOffset.y }

    func centerSelection() {
        if let location = textRange(.caret(selectedRange.location))?.location { center(location) }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard let target = textRange(range) else { return super.scrollRangeToVisible(range) }
        settle(target) {
            super.scrollRangeToVisible(range)
            return true
        }
    }

    /// Only in a window, where TextKit lays a viewport out; `y` is the offset for the paragraph's frame.
    func scroll(_ location: any NSTextLocation, to y: (CGRect) -> CGFloat) {
        guard let manager = textLayoutManager, window != nil else { return }
        settle(NSTextRange(location: location)) {
            guard let fragment = manager.textLayoutFragment(for: location) else { return false }
            let wanted = y(fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerInset.top))
            let least = -adjustedContentInset.top
            let most = max(least, contentSize.height + adjustedContentInset.bottom - bounds.height)
            contentOffset.y = min(max(wanted, least), most)
            return true
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
