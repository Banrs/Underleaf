import AppKit

/// The core's highlights as TextKit's rendering attributes, and the bracket partner's mark.
extension SourceTextView {
    /// TextKit validates colours when it lays a fragment out anew, without editing the document's attributes.
    func installColouring() {
        textLayoutManager?.renderingAttributesValidator = { [weak self] manager, fragment in
            guard let self else { return }
            let range = fragment.rangeInElement
            let start = offset(range.location), end = offset(range.endLocation)
            manager.setRenderingAttributes([.foregroundColor: NSColor.textColor], for: range)
            var runs: [Int] = []
            for run in document.highlights(in: NSRange(location: start, length: end - start)) {
                let clipped = NSIntersectionRange(run.range, NSRange(location: start, length: end - start))
                if clipped.length > 0, let range = textRange(clipped) {
                    manager.setRenderingAttributes([.foregroundColor: syntaxTheme.color(run.kind)], for: range)
                    runs += [clipped.location - start, clipped.length, Int(run.kind.rawValue)]
                }
            }
            fragmentColours.setObject(runs as NSArray, forKey: fragment)
        }
    }

    /// The fragments already shown keep their colours until validated here, from the line `start` is on down. Only the
    /// fragments whose runs changed are drawn again, so typing redraws the lines it recoloured, not every line on screen.
    func colour(from start: Int) {
        guard let manager = textLayoutManager else { return }
        staleColours = nil
        let line = document.lineStart(document.line(at: start))
        let stale = textRange(.caret(line)).flatMap { NSTextRange(location: $0.location, end: manager.documentRange.endLocation) }
        manager.invalidateRenderingAttributes(for: stale ?? manager.documentRange)
        let first = fragments.lastIndex { $0.offset <= line } ?? 0
        var changed: [CGRect] = []
        for (index, (_, fragment)) in fragments.enumerated().dropFirst(first) {
            let before = fragmentColours.object(forKey: fragment)
            manager.renderingAttributesValidator?(manager, fragment)
            // The edited fragment always: TextKit may have coloured it anew while laying it out.
            if index == first || before == nil || before != fragmentColours.object(forKey: fragment) {
                changed.append(fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            }
        }
        redrawFragments(in: changed)
    }

    /// 27.2: each shown fragment draws in a view of its own, which new rendering attributes don't redraw, nor does the
    /// text view's own display: the views over `rects`. The issues' boxes draw no text of the document's.
    private func redrawFragments(in rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        func redraw(_ view: NSView) {
            let frame = view.convert(view.bounds, to: self)
            guard rects.contains(where: { $0.intersects(frame) }) else { return }
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        subviews.filter { !($0 is IssueMessageView) }.forEach(redraw)
    }

    /// The find indicator bounces: with Reduce Motion the partner is filled where it is, under the text, until the
    /// selection next changes. A fill of the view's own, as the current line's: TextKit drops a rendering attribute's
    /// once the fragment is laid out again, as the edit that typed the bracket does. Only a partner in sight: the indicator
    /// would scroll to one out of it. Asked of TextKit, not of `fragments`, which an edit empties until the next layout.
    func showPartner(of at: Int) {
        guard at >= 0, at < text.length, let i = document.partner(of: at) else { return }
        let range = NSRange(location: i, length: 1)
        guard let rect = segments(range), visibleRect.intersects(rect) else { return }
        guard reducesMotion() else { return showFindIndicator(for: range) }
        markPartner(range)
    }

    func markPartner(_ range: NSRange?) {
        if let partnerDrawn { setNeedsDisplay(partnerDrawn) }
        partnerDrawn = nil
        partnerMark = range
        if let rect = partnerRect { setNeedsDisplay(rect) }
    }

    private var partnerRect: NSRect? { partnerMark.flatMap(segments) }

    private func segments(_ marked: NSRange) -> NSRect? {
        guard NSMaxRange(marked) <= text.length, let manager = textLayoutManager, let range = textRange(marked) else { return nil }
        var rect = NSRect.null
        manager.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
            rect = rect.union(frame)
            return true
        }
        return rect.isNull ? nil : rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    func drawPartner(in rect: NSRect) {
        partnerDrawn = partnerRect
        guard let partnerDrawn, partnerDrawn.intersects(rect) else { return }
        NSColor.unemphasizedSelectedTextBackgroundColor.setFill()
        partnerDrawn.fill()
    }
}
