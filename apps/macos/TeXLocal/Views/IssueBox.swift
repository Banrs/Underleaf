import AppKit
import SwiftUI

/// An issue's box at the end of its line, as Xcode 27's SourceEditorLineAnnotationContentView lays out its inline state on
/// macOS 26 and later: a count and icon, a divider, then the message, all spaced from the reference font's size.
struct IssueBox: View, Equatable {
    /// Xcode's spacings, in the point size p of the editor's font (SourceEditorLineAnnotationContentView and
    /// SourceEditorLineAnnotationCategoryControl, disassembled from SourceEditor.framework).
    nonisolated enum Metrics {
        static let reserve: CGFloat = 12, divider: CGFloat = 1, fieldPadding: CGFloat = 2

        static func small(_ size: CGFloat) -> CGFloat { size * 0.95 }

        /// The count and icon start a quarter of p in; a third of p separates count, icon, divider and message.
        static func inset(_ font: NSFont) -> CGFloat { (font.pointSize / 4).rounded() }
        static func gap(_ font: NSFont) -> CGFloat { (font.pointSize * 0.33).rounded() }
        static func tail(_ font: NSFont) -> CGFloat { (font.pointSize * 0.1666).rounded() }
        static func radius(_ font: NSFont) -> CGFloat { (font.pointSize / 3).rounded() }

        /// An NSTextField label's width: its text and 2 pt either side, rounded up.
        static func field(_ text: CGFloat) -> CGFloat { (text + 2 * fieldPadding).rounded(.up) }

        static func count(_ font: NSFont, issues: Int) -> CGFloat { issues > 1 ? field(typeset("\(issues)", in: font).width) : 0 }

        /// The width up to the divider: the inset, then the count, a gap, the icon's p-wide slot, a gap and a sixth of p.
        static func segment(_ font: NSFont, issues: Int) -> CGFloat {
            inset(font) + count(font, issues: issues) + gap(font) + font.pointSize.rounded() + gap(font) + tail(font)
        }

        /// The box's width around a message of this text width, or around the icon alone, ending a sixth of p and 12 pt after it.
        static func width(ofText text: CGFloat?, font: NSFont, issues: Int) -> CGFloat {
            segment(font, issues: issues) + (text.map { gap(font) + field($0) + gap(font) } ?? 0) + tail(font) + reserve
        }
    }

    /// Xcode's annotation colours for its Default (Light) and Default (Dark) themes, resolved from IDEKit's
    /// DVTMessageBubbleAnnotation.annotationColors(colorStyle:colorStyleVariant:isStale:isPredictive:colorTheme:):
    /// a build issue fills its box and tints its line, while a live one is outlined on a neutral line, as Xcode's predicted issues.
    struct Palette {
        let fill: NSColor?
        let text: NSColor
        let icon: NSColor
        let line: NSColor
        let range: NSColor
        let border: NSColor?

        static func of(error: Bool, live: Bool) -> Palette { palettes[error ? (live ? 2 : 0) : (live ? 3 : 1)] }

        private static let palettes = [
            Palette(fill: hex(0xF8D1CC, 0x723A35), text: hex(0x332624, 0xF9F1F0), icon: hex(0xCC2623, 0xFF8C7F),
                    line: hex(0xFDF2F0, 0x4E2825), range: hex(0xCC2623, 0xFF8C7F), border: nil),
            Palette(fill: hex(0xEFDA9F, 0x554E33), text: hex(0x2C2A24, 0xF8F3E1), icon: hex(0x886E1A, 0xD7B300),
                    line: hex(0xFCF4DE, 0x3A3523), range: hex(0x886E1A, 0xD7B300), border: nil),
            Palette(fill: nil, text: hex(0x322529, 0xF9F1F3), icon: hex(0xCC2623, 0xFF8C7F),
                    line: hex(0xF5F5F5, 0x313131), range: hex(0xAA0000, 0xF55B4F), border: hex(0xD7D7D7, 0x484848)),
            Palette(fill: nil, text: hex(0x322529, 0xF9F1F3), icon: hex(0x886E1A, 0xD7B300),
                    line: hex(0xF5F5F5, 0x313131), range: hex(0x6C5200, 0xAB953B), border: hex(0xD7D7D7, 0x484848)),
        ]

        private static func hex(_ light: UInt32, _ dark: UInt32) -> NSColor {
            NSColor(name: nil) {
                let rgb = $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255,
                               alpha: 1)
            }
        }
    }

    let isError: Bool
    let isLive: Bool
    let issues: Int
    let text: String?
    let cutAtTail: Bool
    let font: NSFont
    let background: Color
    let height: CGFloat

    var body: some View {
        let palette = Palette.of(error: isError, live: isLive)
        let shape = RoundedRectangle(cornerRadius: Metrics.radius(font), style: .circular)
        HStack(spacing: 0) {
            if issues > 1 { field(Text(verbatim: "\(issues)"), cut: false) }
            icon(palette)
                .padding(.leading, Metrics.gap(font))
                .padding(.trailing, Metrics.gap(font) + Metrics.tail(font))
            HStack(spacing: 0) {
                if let text { field(Text(verbatim: text), cut: cutAtTail).padding(.horizontal, Metrics.gap(font)) }
                Color.clear.frame(minWidth: Metrics.tail(font) + Metrics.reserve, maxWidth: .infinity)
            }
            .overlay(alignment: .leading) {
                Color(nsColor: palette.border ?? .clear).background(background).frame(width: Metrics.divider)
            }
        }
        .padding(.leading, Metrics.inset(font))
        .font(Font(font as CTFont))
        .foregroundStyle(Color(nsColor: palette.text))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(palette.fill.map { Color(nsColor: $0) } ?? background, in: shape)
        .overlay { if let border = palette.border { shape.strokeBorder(Color(nsColor: border), lineWidth: 1) } }
        .accessibilityHidden(true)
    }

    /// An icon in a p-wide slot, a point short of the line's height when that is smaller, as Xcode sizes its image views:
    /// a build issue shows the issue navigator's badge 12 pt across with its white rim, a live one the outlined symbol image,
    /// scaled whole to fit as Xcode's image view does, in the issue's colour.
    private func icon(_ palette: Palette) -> some View {
        let side = min(height - 1, font.pointSize.rounded())
        return Group {
            if isLive {
                Image(nsImage: NSImage(systemSymbolName: isError ? "exclamationmark.octagon" : "exclamationmark.triangle",
                                       accessibilityDescription: nil) ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(nsColor: palette.icon))
                    .frame(width: side, height: side)
            } else {
                ZStack {
                    Image(systemName: isError ? "circle.fill" : "triangle.fill").resizable().scaledToFit().foregroundStyle(.white)
                    Image(systemName: isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .resizable()
                        .scaledToFit()
                        .symbolRenderingMode(.multicolor)
                        .padding(0.5)
                }
                .frame(width: 12, height: 12)
                .frame(width: side, height: side)
            }
        }
        .frame(width: font.pointSize.rounded(), alignment: .leading)
    }

    /// A label as NSTextField draws one, 2 pt in, its line as tall as the font's and centred in the box, a point lower
    /// at 10, 15 and 16 pt, as Xcode places its labels.
    private func field(_ text: Text, cut: Bool) -> some View {
        let line = NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
        let top = ((height - line) / 2).rounded(.down) + ([10, 15, 16].contains(font.pointSize) ? 1 : 0)
        return text.lineLimit(1).truncationMode(.tail)
            .fixedSize(horizontal: !cut, vertical: true)
            .padding(.horizontal, Metrics.fieldPadding)
            .frame(height: line)
            .padding(.top, top)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct IssueLabel {
    private let whole: String
    private let short: (text: String, width: CGFloat)?
    private let leastWidth: CGFloat
    let width: CGFloat
    static let least = 10

    init(_ message: String, compact: String?, font: NSFont) {
        whole = message
        width = typeset(message, in: font).width
        short = compact.map { ($0, typeset($0, in: font).width) }
        let most = (short?.text ?? message) as NSString
        let least = most.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(Self.least, most.length)))
        leastWidth = least.length < Self.least ? .infinity
            : typeset(most.substring(with: least).trimmingCharacters(in: .whitespaces) + "…", in: font).width
    }

    func text(in room: CGFloat) -> (text: String, width: CGFloat?, cut: Bool)? {
        if width <= room { return (whole, width, false) }
        if let short, short.width <= room { return (short.text, short.width, true) }
        return leastWidth <= room ? (short?.text ?? whole, nil, true) : nil
    }
}

nonisolated func typeset(_ string: String, in font: NSFont) -> (line: CTLine, width: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
    return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}
