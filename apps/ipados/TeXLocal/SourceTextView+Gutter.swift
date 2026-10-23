import UIKit

extension EditorGutter {
    /// Xcode's numbers: SF at the issue symbol's size, 74 on its width axis, tabular, with the open 4, 6 and 9, at least 10 pt.
    static func font(forText size: CGFloat) -> UIFont {
        let numbers = UIFont.systemFont(ofSize: max(10, IssueBox.Metrics.small(size)), weight: .regular, width: UIFont.Width(rawValue: -0.1))
        var axes = CTFontCopyVariation(numbers as CTFont) as? [NSNumber: NSNumber] ?? [:]
        axes[0x7764_7468 as NSNumber] = 74 // 'wdth'
        return UIFont(descriptor: numbers.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes,
            .featureSettings: [
                [UIFontDescriptor.FeatureKey.type: kNumberSpacingType, .selector: kMonospacedNumbersSelector],
                [UIFontDescriptor.FeatureKey.type: kStylisticAlternativesType, .selector: kStylisticAltOneOnSelector],
                [UIFontDescriptor.FeatureKey.type: kStylisticAlternativesType, .selector: kStylisticAltTwoOnSelector]]]),
            size: 0)
    }

    /// Raised with Increase Contrast, as the syntax colours are.
    static let numberColor: UIColor = {
        let raised = TextAppearance.all.filter(\.increaseContrast)
        return .adapting(Dictionary(uniqueKeysWithValues: raised.map { ($0, UIColor.tertiaryLabel.legibleAsText(in: $0)) }),
                         fallback: .tertiaryLabel)
    }()
}

/// Under the text, the size of what shows: what it draws moves with a scroll, not the view.
final class Underlay: UIView {
    override func draw(_ rect: CGRect) {
        guard let view = superview as? SourceTextView, let context = UIGraphicsGetCurrentContext() else { return }
        context.translateBy(x: -frame.minX, y: -frame.minY)
        view.drawUnderText(in: rect.offsetBy(dx: frame.minX, dy: frame.minY))
    }
}

/// The line numbers' column: a tap selects the line, as a click in Xcode's does, and a swipe scrolls.
final class GutterControl: UIControl {
    var tapped: (_ y: CGFloat, _ extending: Bool) -> Void = { _, _ in }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        guard let touch, bounds.contains(touch.location(in: self)), let view = superview else { return }
        tapped(touch.location(in: view).y, event?.modifierFlags.contains(.shift) == true)
    }
}

/// The gutter's numbers and the current line's band, drawn under the text from the fragments last laid out.
extension SourceTextView {
    func installGutter() {
        // The first line's band 8 pt under the text's top, as Xcode's.
        textContainerInset = UIEdgeInsets(top: 7, left: 0, bottom: 7, right: EditorGutter.trailingMargin)
        underlay.isUserInteractionEnabled = false
        underlay.backgroundColor = .clear
        underlay.contentMode = .redraw
        insertSubview(underlay, at: 0)
        gutterControl.isAccessibilityElement = false
        gutterControl.tapped = { [unowned self] y, extending in selectLine(at: y, extending: extending) }
        addSubview(gutterControl)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: Self, _) in
            view.applyFont()
            view.underlay.setNeedsDisplay()
        }
    }

    var textContainerOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }

    func updateGutterWidth() {
        guard gutter.fit(lineCount: document.lineCount, numbered: showsLineNumbers, padding: textContainer.lineFragmentPadding)
        else { return }
        textContainerInset.left = gutter.width
        setNeedsLayout()
        underlay.setNeedsDisplay()
    }

    /// The underlay and the gutter's column keep to what shows; the underlay stays under the text views UIKit adds.
    override func layoutSubviews() {
        super.layoutSubviews()
        if subviews.first !== underlay { sendSubviewToBack(underlay) }
        if underlay.frame != bounds {
            underlay.frame = bounds
            underlay.setNeedsDisplay()
        }
        gutterControl.frame = CGRect(x: bounds.minX, y: bounds.minY, width: textContainerOrigin.x, height: bounds.height)
    }

    /// A swipe that starts on the gutter or an issue's box scrolls, as one on the text does.
    override func touchesShouldCancel(in view: UIView) -> Bool { view is GutterControl || view is IssueMessageView || super.touchesShouldCancel(in: view) }

    var currentLine: (number: Int, rect: CGRect)? {
        let selection = selectedRange, length = length
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

    func onPixels(_ y: CGFloat) -> CGFloat {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        return (y * scale).rounded() / scale
    }

    func redrawLineAndGutter() { underlay.setNeedsDisplay() }

    func drawUnderText(in rect: CGRect) {
        let current = selectedRange.length == 0 ? currentLine : nil
        if let current, current.rect.intersects(rect) {
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: current.rect, cornerRadius: 4).fill()
        }
        issues.draw(in: rect, currentLine: current?.number)
        drawMark(in: rect)
        drawMisspelt(in: rect)
        drawNumbers(in: rect, current: current?.number)
    }

    private func drawNumbers(in rect: CGRect, current: Int?) {
        guard showsLineNumbers, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (offset, fragment) in fragments {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerOrigin.y)
            guard frame.maxY >= rect.minY, frame.minY <= rect.maxY, let line = fragment.textLineFragments.first else { continue }
            let lineNumber = document.line(at: offset)
            func draw(_ lineNumber: Int, on line: NSTextLineFragment) {
                context.setFillColor((lineNumber == current ? UIColor.label : EditorGutter.numberColor).resolvedColor(with: traitCollection).cgColor)
                let number = gutter.number(lineNumber)
                context.textPosition = CGPoint(x: gutter.numbersEnd - number.width, y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                CTLineDraw(number.line, context)
            }
            draw(lineNumber, on: line)
            if let extra = fragment.extraLine { draw(lineNumber + 1, on: extra) }
        }
    }

    /// The line under `y`, or from the selection to it; a line with an issue opens it in the build panel.
    private func selectLine(at y: CGFloat, extending: Bool) {
        guard let position = closestPosition(to: CGPoint(x: textContainerOrigin.x + 1, y: y)) else { return }
        let line = source.lineRange(for: .caret(offset(from: beginningOfDocument, to: position)))
        if !isFirstResponder { _ = becomeFirstResponder() }
        selectedRange = extending ? NSUnionRange(selectedRange, line) : line
        let number = document.line(at: line.location)
        if selectedRange == line, issues.issue(on: number) != nil { issueClicked(number) }
    }
}
