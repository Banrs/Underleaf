import AppKit

/// What of the text shows and where it scrolls to, from the fragments TextKit 2 last laid out in the viewport.
extension SourceTextView {
    /// From the fragments last laid out: asked by point, TextKit answers from its new estimates.
    var shownTop: (offset: Int, below: CGFloat)? {
        guard let scrollY, let top = fragment(under: shownRect.minY) else { return nil }
        return (offset(top.rangeInElement.location), top.layoutFragmentFrame.minY + textContainerOrigin.y - scrollY)
    }

    /// The line half a line under the shown text's top; nil until the fragments laid out reach there (`laidOut`).
    var topLine: Int? {
        let y = shownRect.minY + (font?.boundingRectForFont.height ?? 0) / 2
        guard let top = fragment(under: y), top.layoutFragmentFrame.minY + textContainerOrigin.y <= y else { return nil }
        return document.line(at: offset(top.rangeInElement.location))
    }

    /// The first fragment laid out that reaches below `y`.
    private func fragment(under y: CGFloat) -> NSTextLayoutFragment? {
        fragments.first { $0.fragment.layoutFragmentFrame.maxY + textContainerOrigin.y > y }?.fragment
    }

    func scroll(toShownTop top: (offset: Int, below: CGFloat)) {
        guard let location = textRange(.caret(min(top.offset, length)))?.location else { return }
        scroll(location) { $0.minY - top.below }
    }

    /// The paragraph at `offset` at the shown text's top.
    func scroll(toTop offset: Int) {
        guard let scrollY else { return }
        scroll(toShownTop: (offset, shownRect.minY - scrollY))
    }

    /// The line at `location` in the middle of what shows.
    func center(_ location: any NSTextLocation) {
        guard let manager = textLayoutManager, let scrollY else { return }
        let middle = shownRect.midY - scrollY
        scroll(location) { [unowned self] paragraph in
            guard let fragment = manager.textLayoutFragment(for: location) else { return paragraph.midY - middle }
            let inParagraph = offset(location) - offset(fragment.rangeInElement.location)
            let line = fragment.textLineFragments.last { $0.characterRange.location <= inParagraph } ?? fragment.textLineFragments.first
            return paragraph.minY + (line?.typographicBounds.midY ?? paragraph.height / 2) - middle
        }
    }

    /// TextKit 2 only estimates the heights of what it hasn't laid out, so a place far from the viewport is laid out and
    /// scrolled to, then again once the estimates above it settle as it shows. `scroll` says whether it scrolled.
    func settle(_ range: NSTextRange, _ scroll: () -> Bool) {
        guard let manager = textLayoutManager else { return }
        for _ in 0..<2 {
            manager.ensureLayout(for: range)
            guard scroll() else { return }
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

    /// A new width has TextKit 2 estimate the heights above again, so the top paragraph is put back; and scrolled down,
    /// AppKit's width tracking waits for a live resize's end, so the width follows as it goes (`aRevealedLineStaysAtTheTop`).
    override func setFrameSize(_ size: NSSize) {
        guard size.width != frame.width else { return super.setFrameSize(size) }
        let top = shownTop
        super.setFrameSize(size)
        textContainer?.size.width = max(0, size.width - gutter.width - EditorGutter.trailingMargin)
        top.map(scroll(toShownTop:))
    }

    /// The clip view's bounds less the scroll view's insets for the bars over it.
    var shownRect: NSRect {
        guard let scroll = enclosingScrollView else { return visibleRect }
        let insets = scroll.contentInsets
        var shown = convert(scroll.contentView.bounds, from: scroll.contentView)
        shown.origin.y += insets.top
        shown.size.height -= insets.top + insets.bottom
        return shown
    }

    var scrollY: CGFloat? { enclosingScrollView?.contentView.bounds.minY }

    /// AppKit's Jump to Selection lands lines off where TextKit 2 has only estimated the heights above
    /// (`jumpToSelectionCentresIt`).
    override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let location = textRange(.caret(selectedRange().location))?.location else { return super.centerSelectionInVisibleArea(sender) }
        center(location)
    }

    /// Only in a window, where TextKit lays a viewport out.
    func scroll(_ location: any NSTextLocation, to y: (NSRect) -> CGFloat) {
        guard let manager = textLayoutManager, let scroll = enclosingScrollView, window != nil else { return }
        let clip = scroll.contentView
        settle(NSTextRange(location: location)) {
            guard let fragment = manager.textLayoutFragment(for: location) else { return false }
            let origin = NSPoint(x: 0, y: y(fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerOrigin.y)))
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            return true
        }
    }

    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        // Until a scroll prepares content, AppKit leaves the lines under the status bar's inset undrawn
        // (`theShownTextIsPreparedBeforeAnyScroll`).
        if !visibleRect.isEmpty, !preparedContentRect.contains(visibleRect) { prepareContent(in: visibleRect) }
        fragments.sort { $0.offset < $1.offset }
        if let from = staleColours { colour(from: from) }
        completions.follow()
        issues.place()
        redrawLineAndGutter()
        laidOut()
    }
}
