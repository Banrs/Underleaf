import AppKit

/// The core's highlights as TextKit's rendering attributes, the fragments coloured anew, and the bracket partner's mark.
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

    /// From the line `start` is on down; only the fragments whose runs changed are drawn again.
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

    func segments(_ marked: NSRange) -> CGRect? {
        guard NSMaxRange(marked) <= length, let manager = textLayoutManager, let range = textRange(marked) else { return nil }
        var rect = CGRect.null
        manager.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
            rect = rect.union(frame)
            return true
        }
        return rect.isNull ? nil : rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
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
