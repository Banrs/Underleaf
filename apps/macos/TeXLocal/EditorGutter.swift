import AppKit

/// The gutter's measures, as Xcode sets its numbers out, and the numbers themselves, each typeset once.
struct EditorGutter {
    /// Where the current line's and an issue's band start, and where the numbers would end without them.
    static let bandStart: CGFloat = 14
    /// The room after the text and the bands.
    static let trailingMargin: CGFloat = 8
    /// Xcode's: four-digit numbers end 39.7 pt in at 13 pt, and the text starts on a whole point, 51 pt in.
    private static let firstDigitEnd: CGFloat = 19.8, numbersToText: CGFloat = 11

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

    /// From the view's edge to the text container, less its line fragment padding.
    private(set) var width: CGFloat = 0
    private(set) var digits = 0
    private(set) var numbersEnd: CGFloat = 0
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize) {
        didSet {
            numbers.removeAll()
            width = 0
        }
    }
    private var numbers: [Int: (line: CTLine, width: CGFloat)] = [:]
    /// The current line's band where it was last drawn, to be drawn over once it moves.
    var drawnLine: CGRect?

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
}

extension NSTextLayoutFragment {
    /// The document's last line when it's empty: TextKit lays it out as an extra line of the paragraph before.
    var extraLine: NSTextLineFragment? {
        let lines = textLineFragments
        guard lines.count > 1, let last = lines.last, last.characterRange.length == 0 else { return nil }
        return last
    }

    /// The paragraph's own lines, or with `extra` the document's empty last line laid out with it.
    func lines(extra: Bool) -> ArraySlice<NSTextLineFragment> {
        let lines = textLineFragments[...]
        guard extraLine != nil else { return lines }
        return extra ? lines.suffix(1) : lines.dropLast()
    }
}
