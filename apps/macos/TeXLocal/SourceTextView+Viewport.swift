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
