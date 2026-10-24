import AppKit

/// The gutter's numbers and the current line's band, drawn under the text from the fragments last laid out.
extension SourceTextView {
    func updateGutterWidth() {
        guard gutter.fit(lineCount: document.lineCount, numbered: showsLineNumbers, padding: textContainer?.lineFragmentPadding ?? 0)
        else { return }
        textContainerInset.width = (gutter.width + EditorGutter.trailingMargin) / 2
        needsDisplay = true
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: gutter.width, y: textContainerInset.height) }

    func onPixels(_ y: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (y * scale).rounded() / scale
    }

    func redrawLineAndGutter() {
        let shown = visibleRect
        setNeedsDisplay(NSRect(x: shown.minX, y: shown.minY, width: gutter.numbersEnd + 4 - shown.minX, height: shown.height))
        if let drawnLine = gutter.drawnLine { setNeedsDisplay(drawnLine) }
        if let rect = currentLine?.rect { setNeedsDisplay(rect) }
    }

    func drawCurrentLine(_ current: (number: Int, rect: NSRect)?, in rect: NSRect) {
        gutter.drawnLine = current?.rect
        guard let current, current.rect.intersects(rect) else { return }
        NSColor.currentLine.setFill()
        NSBezierPath(roundedRect: current.rect, xRadius: 4, yRadius: 4).fill()
    }

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
}
