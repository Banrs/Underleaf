import AppKit

/// What of the text shows and where, the gutter's numbers and the core's colours, from the fragments TextKit 2 last laid
/// out in the viewport.
extension SourceTextView {
    // MARK: the viewport

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

    // MARK: the gutter's numbers and the current line's band, drawn under the text

    /// Xcode 27's Default (Light) and Default (Dark) themes' `DVTSourceTextCurrentLineHighlightColor`, in sRGB.
    nonisolated static let currentLineRGBA = (light: [0.909804, 0.94902, 1, 1], dark: [0.138526, 0.146864, 0.169283, 1])

    var currentLine: (number: Int, rect: CGRect)? {
        let selection = selection, length = length
        guard let entry = fragments.last(where: { $0.offset <= selection.location }) else { return nil }
        let end = offset(entry.fragment.rangeInElement.endLocation)
        guard selection.location < end || end == length else { return nil }
        let lines = entry.fragment.lines(extra: selection.location == length)
        return (document.line(at: selection.location), band(lines, of: entry.fragment))
    }

    /// The current line's or an issue's band over these lines, on the display's pixels.
    func band(_ lines: ArraySlice<NSTextLineFragment>, of fragment: NSTextLayoutFragment) -> CGRect {
        let frame = fragment.layoutFragmentFrame
        let top = onPixels(textContainerOrigin.y + frame.minY + (lines.first?.typographicBounds.minY ?? 0) + rowShift)
        let bottom = onPixels(textContainerOrigin.y + frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height) + rowShift)
        return CGRect(x: EditorGutter.bandStart, y: top, width: bounds.width - EditorGutter.bandStart - EditorGutter.trailingMargin,
                      height: bottom - top)
    }

    func drawNumbers(in rect: CGRect, current: Int?) {
        let context = NSGraphicsContext.current?.cgContext
        guard rect.minX < gutter.numbersEnd + 4, showsLineNumbers, let context else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (offset, fragment) in fragments {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerOrigin.y)
            guard frame.maxY >= rect.minY, frame.minY <= rect.maxY, let line = fragment.textLineFragments.first else { continue }
            let lineNumber = document.line(at: offset)
            func draw(_ lineNumber: Int, on line: NSTextLineFragment) {
                (lineNumber == current ? .labelColor : EditorGutter.numberColor).setFill()
                let number = gutter.number(lineNumber)
                context.textPosition = CGPoint(x: gutter.numbersEnd - number.width, y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                CTLineDraw(number.line, context)
            }
            draw(lineNumber, on: line)
            if let extra = fragment.extraLine { draw(lineNumber + 1, on: extra) }
        }
    }

    // MARK: the core's highlights as TextKit's rendering attributes

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
}
