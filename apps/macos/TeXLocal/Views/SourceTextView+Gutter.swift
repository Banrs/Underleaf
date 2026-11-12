import AppKit

extension SourceTextView {
    func updateGutterWidth() {
        guard gutter.fit(lineCount: document.lineCount, numbered: showsLineNumbers, padding: linePadding) else { return }
        textContainerInset.width = (gutter.width + linePadding) / 2
        needsDisplay = true
    }

    var linePadding: CGFloat { textContainer?.lineFragmentPadding ?? 0 }

    var sourceTextStart: CGFloat { textContainerOrigin.x + linePadding }

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

    func band(_ lines: ArraySlice<NSTextLineFragment>, of fragment: NSTextLayoutFragment) -> CGRect {
        // The whole row, so the bands of neighbouring lines meet: the line's box with the line spacing below it. TextKit 2
        // puts that spacing above a line, but SF Mono's letters sit low in their box, and below is where they come out
        // centred in the band.
        let frame = fragment.layoutFragmentFrame
        let spacing = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing ?? 0
        let top = onPixels(textContainerOrigin.y + frame.minY + (lines.first?.typographicBounds.minY ?? 0))
        let bottom = onPixels(textContainerOrigin.y + frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height) + spacing)
        // Xcode 27.2's line highlight is inset 14 pt and 8 pt on a 2× display.
        let leading: CGFloat = 14, trailing: CGFloat = 8
        return CGRect(x: leading, y: top, width: max(0, bounds.width - leading - trailing), height: bottom - top)
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
