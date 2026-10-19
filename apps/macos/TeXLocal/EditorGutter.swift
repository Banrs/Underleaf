import AppKit

/// The gutter's measures, as Xcode sets its numbers out, and the numbers themselves, each typeset once.
struct EditorGutter {
    /// Where the current line's and an issue's band start, and where the numbers would end without them.
    static let bandStart: CGFloat = 14
    /// The room after the text and the bands.
    static let trailingMargin: CGFloat = 8
    /// Where a number's first digit ends: Xcode's four-digit numbers end 39.7 pt in at 13 pt (fitted to its gutter as drawn).
    private static let firstDigitEnd: CGFloat = 19.8
    /// From the numbers to the text, which starts on a whole point, as Xcode's does (51 at 13 pt).
    private static let numbersToText: CGFloat = 11

    /// From the view's edge to the text container, less its line fragment padding.
    private(set) var width: CGFloat = 0
    /// The digits the gutter has room for: four at least.
    private(set) var digits = 0
    /// Where the numbers end.
    private(set) var numbersEnd: CGFloat = 0
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize) {
        didSet {
            numbers.removeAll()
            width = 0
        }
    }
    private var numbers: [Int: (line: CTLine, width: CGFloat)] = [:]
    /// The current line's band where it was last drawn, to be drawn over once it moves.
    var drawnLine: NSRect?

    static func digits(_ lineCount: Int) -> Int { max(4, String(lineCount).count) }

    /// Whether the width changed, for `lineCount` lines.
    mutating func fit(lineCount: Int, numbered: Bool, padding: CGFloat) -> Bool {
        digits = Self.digits(lineCount)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        numbersEnd = numbered ? Self.firstDigitEnd + CGFloat(digits - 1) * digitWidth : Self.bandStart
        let fitted = (numbersEnd + Self.numbersToText).rounded(.up) - padding
        guard fitted != width else { return false }
        width = fitted
        return true
    }

    mutating func number(_ number: Int) -> (line: CTLine, width: CGFloat) {
        if let cached = numbers[number] { return cached }
        if numbers.count > 4096 { numbers.removeAll(keepingCapacity: true) }
        let line = typeset(String(number), in: font)
        numbers[number] = line
        return line
    }

    /// Xcode's numbers: SF at the issue symbol's size, a little narrower than semi-condensed (74 on SF's width axis to its
    /// 80), tabular, with the open 4, 6 and 9 (SF's first two stylistic sets), never under the HIG's 10 points.
    static func font(forText size: CGFloat) -> NSFont {
        let numbers = NSFont.systemFont(ofSize: max(10, IssueBox.Metrics.small(size)), weight: .regular, width: NSFont.Width(rawValue: -0.1))
        var axes = CTFontCopyVariation(numbers) as? [NSNumber: NSNumber] ?? [:]
        axes[0x7764_7468 as NSNumber] = 74 // 'wdth'
        return NSFont(descriptor: numbers.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): axes,
            .featureSettings: [
                [NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector],
                [NSFontDescriptor.FeatureKey.typeIdentifier: kStylisticAlternativesType, .selectorIdentifier: kStylisticAltOneOnSelector],
                [NSFontDescriptor.FeatureKey.typeIdentifier: kStylisticAlternativesType, .selectorIdentifier: kStylisticAltTwoOnSelector]]]),
            size: 0) ?? numbers
    }

    /// The numbers' grey, raised with Increase Contrast as the syntax colours are (`displayOptionsWatch` redraws them).
    static let numberColor: NSColor = {
        let raised: [NSAppearance.Name] = [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        return .adapting(Dictionary(uniqueKeysWithValues: raised.map { ($0, NSColor.tertiaryLabelColor.legibleAsText(in: $0)) }),
                         fallback: .tertiaryLabelColor)
    }()
}

/// The gutter's numbers and the current line's band, drawn under the text from the fragments last laid out.
extension SourceTextView {
    func updateGutterWidth() {
        guard gutter.fit(lineCount: document.lineCount, numbered: showsLineNumbers, padding: textContainer?.lineFragmentPadding ?? 0)
        else { return }
        // The container tracks the view's width less twice this: the gutter and the margin after the text.
        textContainerInset.width = (gutter.width + EditorGutter.trailingMargin) / 2
        needsDisplay = true
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: gutter.width, y: textContainerInset.height) }

    /// The document's last line when it's empty: TextKit lays it out as an extra line of the paragraph before.
    func extraLine(of fragment: NSTextLayoutFragment) -> NSTextLineFragment? {
        let lines = fragment.textLineFragments
        guard lines.count > 1, let last = lines.last, last.characterRange.length == 0 else { return nil }
        return last
    }

    var currentLine: (number: Int, rect: NSRect)? {
        let selection = selectedRange(), length = text.length
        guard let entry = fragments.last(where: { $0.offset <= selection.location }) else { return nil }
        let end = offset(entry.fragment.rangeInElement.endLocation)
        guard selection.location < end || end == length else { return nil }
        var lines = entry.fragment.textLineFragments[...]
        if extraLine(of: entry.fragment) != nil { lines = selection.location == length ? lines.suffix(1) : lines.dropLast() }
        return (document.line(at: selection.location), band(lines, of: entry.fragment))
    }

    /// The band of the current line or an issue over these lines. `rowShift` can leave its edges between two of the
    /// display's pixels, so they are snapped to one.
    func band(_ lines: ArraySlice<NSTextLineFragment>, of fragment: NSTextLayoutFragment) -> NSRect {
        let frame = fragment.layoutFragmentFrame
        let top = onPixels(textContainerOrigin.y + frame.minY + (lines.first?.typographicBounds.minY ?? 0) + rowShift)
        let bottom = onPixels(textContainerOrigin.y + frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height) + rowShift)
        return NSRect(x: EditorGutter.bandStart, y: top, width: bounds.width - EditorGutter.bandStart - EditorGutter.trailingMargin,
                      height: bottom - top)
    }

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
        NSColor.secondarySystemFill.setFill()
        NSBezierPath(roundedRect: current.rect, xRadius: 4, yRadius: 4).fill()
    }

    func drawNumbers(in rect: NSRect, current: Int?) {
        guard rect.minX < gutter.numbersEnd + 4, showsLineNumbers, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let origin = textContainerOrigin
        for (offset, fragment) in fragments {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: origin.y)
            guard frame.maxY >= rect.minY, frame.minY <= rect.maxY, let line = fragment.textLineFragments.first else { continue }
            let lineNumber = document.line(at: offset)
            func draw(_ lineNumber: Int, on line: NSTextLineFragment) {
                (lineNumber == current ? .labelColor : EditorGutter.numberColor).setFill()
                let number = gutter.number(lineNumber)
                context.textPosition = CGPoint(x: gutter.numbersEnd - number.width, y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                CTLineDraw(number.line, context)
            }
            draw(lineNumber, on: line)
            if let extra = extraLine(of: fragment) { draw(lineNumber + 1, on: extra) }
        }
    }
}
