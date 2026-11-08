import AppKit

struct EditorGutter {
    static let numberColor: NSColor = {
        let raised: [NSAppearance.Name] = [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        return .adapting(Dictionary(uniqueKeysWithValues: raised.map { ($0, NSColor.tertiaryLabelColor.legibleAsText(in: $0)) }),
                         fallback: .tertiaryLabelColor)
    }()

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
    var drawnLine: CGRect?

    static func digits(_ lineCount: Int) -> Int { max(4, String(lineCount).count) }

    mutating func fit(lineCount: Int, numbered: Bool, padding: CGFloat) -> Bool {
        digits = Self.digits(lineCount)
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        numbersEnd = padding + (numbered ? padding + CGFloat(digits) * digit : 0)
        let fitted = (numbersEnd + digit).rounded(.up)
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
    var extraLine: NSTextLineFragment? {
        let lines = textLineFragments
        guard lines.count > 1, let last = lines.last, last.characterRange.length == 0 else { return nil }
        return last
    }

    func lines(extra: Bool) -> ArraySlice<NSTextLineFragment> {
        let lines = textLineFragments[...]
        guard extraLine != nil else { return lines }
        return extra ? lines.suffix(1) : lines.dropLast()
    }
}

nonisolated func typeset(_ string: String, in font: NSFont) -> (line: CTLine, width: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
    return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}
