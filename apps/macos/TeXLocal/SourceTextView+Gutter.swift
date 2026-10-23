import AppKit

extension EditorGutter {
    /// Xcode's numbers: SF at the issue symbol's size, 74 on its width axis, tabular, with the open 4, 6 and 9, at least 10 pt.
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

    /// Raised with Increase Contrast, as the syntax colours are.
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
}
