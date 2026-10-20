import AppKit

/// What of the text shows and where it scrolls to, from the fragments TextKit 2 last laid out in the viewport.
extension SourceTextView {
    /// 27.2: TextKit 2 re-estimates the heights above for a new width, so the top paragraph is put back; and scrolled
    /// down, AppKit's width tracking waits for a live resize's end, so the width follows as it goes.
    override func setFrameSize(_ size: NSSize) {
        guard size.width != frame.width else { return super.setFrameSize(size) }
        let top = shownTop
        super.setFrameSize(size)
        textContainer?.size.width = max(0, size.width - gutter.width - EditorGutter.trailingMargin)
        top.map(scroll(toShownTop:))
        layOutViewportOnceSettled()
    }

    /// 27.2: widths changing faster than a frame can leave the viewport's text gone until it next scrolls.
    func layOutViewportOnceSettled() {
        guard !viewportPending else { return }
        viewportPending = true
        Task { [weak self] in
            self?.viewportPending = false
            self?.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
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

    /// From the fragments last laid out: asked by point, TextKit answers from its new estimates.
    var shownTop: (offset: Int, below: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView, let top = fragment(under: shownRect.minY) else { return nil }
        return (offset(top.rangeInElement.location), top.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.minY)
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

    /// 27.2: AppKit's Jump to Selection lands lines off where TextKit 2 has only estimated the heights above.
    override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let clip = enclosingScrollView?.contentView, let manager = textLayoutManager,
              let location = textRange(.caret(selectedRange().location))?.location
        else { return super.centerSelectionInVisibleArea(sender) }
        let middle = shownRect.midY - clip.bounds.minY
        scroll(location) { [unowned self] paragraph in
            guard let fragment = manager.textLayoutFragment(for: location) else { return paragraph.midY - middle }
            let inParagraph = offset(location) - offset(fragment.rangeInElement.location)
            let line = fragment.textLineFragments.last { $0.characterRange.location <= inParagraph } ?? fragment.textLineFragments.first
            return paragraph.minY + (line?.typographicBounds.midY ?? paragraph.height / 2) - middle
        }
    }

    /// Laid out first: far from the viewport the range has no rect yet, and the estimates above it settle as it's shown.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let manager = textLayoutManager, enclosingScrollView != nil, let target = textRange(range)
        else { return super.scrollRangeToVisible(range) }
        for _ in 0..<2 {
            manager.ensureLayout(for: target)
            guard let rect = segments(range), scrollToVisible(rect) else { return }
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    func scroll(toShownTop top: (offset: Int, below: CGFloat)) {
        guard let location = textRange(.caret(min(top.offset, text.length)))?.location else { return }
        scroll(location) { $0.minY - top.below }
    }

    /// The paragraph at `offset` at the shown text's top.
    func scroll(toTop offset: Int) {
        guard let clip = enclosingScrollView?.contentView else { return }
        scroll(toShownTop: (offset, shownRect.minY - clip.bounds.minY))
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
        // 27.2: until a scroll prepares content, the lines laid out under the status bar's inset aren't drawn.
        if !visibleRect.isEmpty, !preparedContentRect.contains(visibleRect) { prepareContent(in: visibleRect) }
        fragments.sort { $0.offset < $1.offset }
        if let from = staleColours { colour(from: from) }
        completions.follow()
        issues.place()
        redrawLineAndGutter()
        laidOut()
    }
}
