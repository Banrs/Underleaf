import AppKit

/// What of the text shows and where it scrolls to, from the fragments TextKit 2 last laid out in the viewport.
extension SourceTextView {
    // 27.2: the top paragraph stays put: TextKit 2 keeps the offset, over heights a new width re-estimates.
    override func setFrameSize(_ size: NSSize) {
        guard size.width != frame.width else { return super.setFrameSize(size) }
        let top = shownTop
        super.setFrameSize(size)
        // 27.2: scrolled down, AppKit's tracking waits for a live resize's end, so the width follows as it goes.
        textContainer?.size.width = max(0, size.width - gutter.width - EditorGutter.trailingMargin)
        top.map(scroll(toShownTop:))
        layOutViewportOnceSettled()
    }

    /// 27.2: widths changing faster than a frame (a divider dragged quickly) can leave the viewport's text gone
    /// until it next scrolls; once they settle, TextKit lays the shown text out for the last.
    func layOutViewportOnceSettled() {
        guard !viewportPending else { return }
        viewportPending = true
        Task { [weak self] in
            self?.viewportPending = false
            self?.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    /// What of the text shows: the clip view's bounds less the scroll view's insets for the bars over it.
    var shownRect: NSRect {
        guard let scroll = enclosingScrollView else { return visibleRect }
        let insets = scroll.contentInsets
        var shown = convert(scroll.contentView.bounds, from: scroll.contentView)
        shown.origin.y += insets.top
        shown.size.height -= insets.top + insets.bottom
        return shown
    }

    /// From the fragments last laid out: asked by point, TextKit answers from its new estimates.
    var shownTop: (offset: Int, below: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView, let top = fragment(under: shownRect.minY) else { return nil }
        return (offset(top.rangeInElement.location), top.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.minY)
    }

    /// The line half a line under the shown text's top, from the fragments last laid out as `shownTop` is; nil while
    /// they don't reach there, which the viewport's next layout does (`laidOut`).
    var topLine: Int? {
        let y = shownRect.minY + (font?.boundingRectForFont.height ?? 0) / 2
        guard let top = fragment(under: y), top.layoutFragmentFrame.minY + textContainerOrigin.y <= y else { return nil }
        return document.line(at: offset(top.rangeInElement.location))
    }

    /// The first fragment laid out that reaches below `y`.
    private func fragment(under y: CGFloat) -> NSTextLayoutFragment? {
        fragments.first { $0.fragment.layoutFragmentFrame.maxY + textContainerOrigin.y > y }?.fragment
    }

    /// 27.2: AppKit's Jump to Selection lands lines off where TextKit 2 has only estimated the heights above.
    override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let clip = enclosingScrollView?.contentView, let manager = textLayoutManager,
              let location = textRange(NSRange(location: selectedRange().location, length: 0))?.location
        else { return super.centerSelectionInVisibleArea(sender) }
        // The shown text's middle, under the clip view's top.
        let middle = shownRect.midY - clip.bounds.minY
        scroll(location) { [unowned self] paragraph in
            guard let fragment = manager.textLayoutFragment(for: location) else { return paragraph.midY - middle }
            let inParagraph = offset(location) - offset(fragment.rangeInElement.location)
            let line = fragment.textLineFragments.last { $0.characterRange.location <= inParagraph } ?? fragment.textLineFragments.first
            return paragraph.minY + (line?.typographicBounds.midY ?? paragraph.height / 2) - middle
        }
    }

    /// Laid out first: far from the viewport the range has no rect yet, and TextKit 2's estimates above it settle as it's shown.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let manager = textLayoutManager, enclosingScrollView != nil, let target = textRange(range)
        else { return super.scrollRangeToVisible(range) }
        for _ in 0..<2 {
            manager.ensureLayout(for: target)
            var rect = NSRect.null
            manager.enumerateTextSegments(in: target, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
                rect = rect.union(frame)
                return true
            }
            guard !rect.isNull else { return }
            guard scrollToVisible(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)) else { return }
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    func scroll(toShownTop top: (offset: Int, below: CGFloat)) {
        guard let location = textRange(NSRange(location: min(top.offset, text.length), length: 0))?.location else { return }
        scroll(location) { $0.minY - top.below }
    }

    /// The paragraph at `offset` at the shown text's top, or its middle at the shown text's middle.
    func scroll(to offset: Int, atTop: Bool) {
        guard let clip = enclosingScrollView?.contentView, let target = textRange(NSRange(location: offset, length: 0)) else { return }
        // Under the clip view's top: the shown text's top and middle.
        let shown = shownRect, clipTop = clip.bounds.minY
        scroll(target.location) { atTop ? $0.minY - (shown.minY - clipTop) : $0.midY - (shown.midY - clipTop) }
    }

    /// 27.2: lays out only that paragraph, in two passes, and only in a window.
    func scroll(_ location: any NSTextLocation, to y: (NSRect) -> CGFloat) {
        guard let manager = textLayoutManager, let scroll = enclosingScrollView, window != nil else { return }
        let clip = scroll.contentView
        for _ in 0..<2 {
            manager.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = manager.textLayoutFragment(for: location) else { return }
            let origin = NSPoint(x: 0, y: y(fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerOrigin.y)))
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    /// The clip view scrolled: what floats over the text follows it, as a layout's end has it follow (below). TextKit
    /// lays the viewport out again only for a scroll past what it had laid out.
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

    /// Each time TextKit lays out the viewport: a scroll past what it had laid out, an edit, a new width.
    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        fragments.sort { $0.offset < $1.offset }
        if let from = staleColours { colour(from: from) }
        completions.follow()
        issues.place()
        redrawLineAndGutter()
        laidOut()
    }
}
