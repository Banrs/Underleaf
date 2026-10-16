import AppKit
import SwiftUI

/// 27.2: TextKit draws a selection in a view above the text view's background (`_NSTextSelectionView`), which would
/// cover a box drawn there; this view sits above the text's views, takes no click, and the text view answers for it.
/// Placed by frame, it sizes nothing itself and has no safe area under the toolbar.
final class IssueMessageView: NSHostingView<IssueBox> {
    convenience init(_ box: IssueBox) {
        self.init(rootView: box)
        sizingOptions = []
        safeAreaRegions = []
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An issue at its line's end, as Xcode sets it: a box in the text's background edged in the separators' colour, the
/// symbol in a segment of its own, a divider and the message on the source line's baseline, or the symbol alone where
/// the line has no room for words. VoiceOver has the issues from the text view's rotor.
struct IssueBox: View {
    /// Every measure of the box. Fractions of the text's size are rounded to whole points, so its edges are the band's pixels.
    nonisolated enum Metrics {
        /// The symbol's segment, as a fraction of the text's size.
        static let segment: CGFloat = 2
        /// The room before the message: Xcode 27's after its divider, at 13 pt.
        static let padding: CGFloat = 5
        /// The room after a message that is all there, as Xcode 27 leaves it at 13 pt.
        static let trailing: CGFloat = 20
        /// What the symbol's segment gains for the count of a line's issues before the symbol, as Xcode's.
        static let count: CGFloat = 12
        /// How far the count reaches into the symbol's segment, as Xcode's.
        static let countOverlap: CGFloat = 1
        static let symbolScale = Image.Scale.small
        static let cornerRadius: CGFloat = 4
        static let border: CGFloat = 1
        static let divider: CGFloat = 1
        /// From the band's end.
        static let endInset: CGFloat = 1

        /// The size of the symbol and of the line numbers: Xcode's 12.35 pt at 13 pt.
        static func small(_ size: CGFloat) -> CGFloat { size * 0.95 }

        static func segment(_ font: NSFont, issues: Int) -> CGFloat {
            (segment * font.pointSize).rounded() + (issues > 1 ? count : 0)
        }

        /// The box's width for a message this wide, or for the symbol alone.
        static func width(ofText text: CGFloat?, font: NSFont, issues: Int) -> CGFloat {
            segment(font, issues: issues) + (text.map { divider + (padding + $0 + trailing).rounded(.up) } ?? 0)
        }
    }

    let isError: Bool
    /// The line's issues, counted before the symbol where there are more than one.
    let issues: Int
    let text: String?
    /// The message cut at its tail, with an ellipsis, to the room the box has.
    let cutAtTail: Bool
    let font: NSFont
    let fill: Color
    /// The source line's baseline under the box's top.
    let baseline: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius)
        let separator = Color(nsColor: .separatorColor)
        HStack(spacing: 0) {
            if issues > 1 {
                onBaseline(Text(verbatim: "\(issues)"))
                    .frame(width: Metrics.count, alignment: .trailing)
                    .offset(x: Metrics.countOverlap)
            }
            Image(systemName: isError ? "exclamationmark.octagon" : "exclamationmark.triangle")
                .font(.system(size: Metrics.small(font.pointSize)))
                .imageScale(Metrics.symbolScale)
                .foregroundStyle(isError ? .red : .yellow)
                .frame(width: Metrics.segment(font, issues: 1))
            if let text {
                separator.frame(width: Metrics.divider)
                onBaseline(Text(verbatim: text), cut: cutAtTail)
                    .padding(.leading, Metrics.padding)
                    .padding(.trailing, cutAtTail ? Metrics.trailing : 0)
            }
        }
        .font(Font(font as CTFont))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(fill, in: shape)
        .overlay(shape.strokeBorder(separator, lineWidth: Metrics.border))
        .accessibilityHidden(true)
    }

    /// On the source line's baseline, and as wide as it is unless it's to be `cut` to the room.
    private func onBaseline(_ text: Text, cut: Bool = false) -> some View {
        text.lineLimit(1).truncationMode(.tail)
            .fixedSize(horizontal: !cut, vertical: true)
            .alignmentGuide(.top) { $0[.firstTextBaseline] - baseline }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// An issue's message for its line's end, from the core's one-line form: whole where there is room for it, then for an
/// undefined command in fewer words that keep its name ("Undefined: \name"), then cut at the tail with an ellipsis, and
/// not at all where fewer than ten of its characters would show. The line's issues are counted in the box's symbol
/// segment, as Xcode counts them.
struct IssueLabel {
    private let whole: String
    private let short: (text: String, width: CGFloat)?
    /// The narrowest room for a message cut at its tail: its first ten characters and the ellipsis.
    private let leastWidth: CGFloat
    /// The whole message's width.
    let width: CGFloat

    /// The fewest of a message's characters worth showing before the ellipsis.
    static let least = 10

    init(_ message: String, command: String?, font: NSFont) {
        whole = message
        width = typeset(message, in: font).width
        short = command.map { String(localized: "Undefined: \($0)") }.map { ($0, typeset($0, in: font).width) }
        let most = (short?.text ?? message) as NSString
        let least = most.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(Self.least, most.length)))
        leastWidth = least.length < Self.least ? .infinity
            : typeset(most.substring(with: least).trimmingCharacters(in: .whitespaces) + "…", in: font).width
    }

    /// The message for a room this wide, or nil where it has none; `cut` where it isn't all there, and with no width
    /// where it is to be cut at its tail to the room.
    func text(in room: CGFloat) -> (text: String, width: CGFloat?, cut: Bool)? {
        if width <= room { return (whole, width, false) }
        if let short, short.width <= room { return (short.text, short.width, true) }
        return leastWidth <= room ? (short?.text ?? whole, nil, true) : nil
    }
}

extension NSString {
    /// Where a line has the command, each time it does: not as the start of a longer name, not after a backslash that is
    /// itself a command's (`\\foo` is a line break and a word), and not in a comment.
    func ranges(ofCommand command: String) -> [NSRange] {
        // TeX's letters, with `@` as in a class's or a package's own source.
        func isLetter(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character == "@") }
        // To the first percent sign that isn't `\%`.
        var end = 0
        while end < length, character(at: end) != 0x25 || isEscaped(at: end) { end += 1 }
        let word = command.dropFirst().first.map(isLetter) ?? false
        var found: [NSRange] = [], from = 0
        while from < end {
            let range = self.range(of: command, options: .literal, range: NSRange(location: from, length: end - from))
            guard range.location != NSNotFound else { break }
            from = NSMaxRange(range)
            let next = from < length ? Unicode.Scalar(character(at: from)).map(Character.init) : nil
            if !isEscaped(at: range.location), !(word && next.map(isLetter) == true) { found.append(range) }
        }
        return found
    }

    /// Whether the character at `at` follows an unescaped backslash, as the bracket of `\[` does.
    private func isEscaped(at: Int) -> Bool {
        var slashes = 0
        while at - slashes > 0, character(at: at - slashes - 1) == 0x5C { slashes += 1 }
        return slashes % 2 == 1
    }
}

/// One line of `string` in `font`, coloured as the context draws, and its width: the issues' messages and the gutter's numbers.
func typeset(_ string: String, in font: NSFont) -> (line: CTLine, width: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
    return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}
