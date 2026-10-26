import AppKit
import SwiftUI

struct IssueBox: View, Equatable {
    nonisolated enum Metrics {
        static let segment: CGFloat = 2, padding: CGFloat = 5, trailing: CGFloat = 20, count: CGFloat = 12, divider: CGFloat = 1

        static func small(_ size: CGFloat) -> CGFloat { size * 0.95 }

        static func segment(_ font: NSFont, issues: Int) -> CGFloat { (segment * font.pointSize).rounded() + (issues > 1 ? count : 0) }

        static func width(ofText text: CGFloat?, font: NSFont, issues: Int) -> CGFloat {
            segment(font, issues: issues) + (text.map { divider + (padding + $0 + trailing).rounded(.up) } ?? 0)
        }
    }

    let isError: Bool
    let issues: Int
    let text: String?
    let cutAtTail: Bool
    let font: NSFont
    let fill: Color
    let baseline: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        let separator = Color(nsColor: .separatorColor)
        HStack(spacing: 0) {
            if issues > 1 {
                onBaseline(Text(verbatim: "\(issues)"))
                    .frame(width: Metrics.count, alignment: .trailing)
                    .offset(x: 1)
            }
            Image(systemName: isError ? "exclamationmark.octagon" : "exclamationmark.triangle")
                .font(.system(size: Metrics.small(font.pointSize)))
                .imageScale(.small)
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
        .overlay(shape.strokeBorder(separator, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func onBaseline(_ text: Text, cut: Bool = false) -> some View {
        text.lineLimit(1).truncationMode(.tail)
            .fixedSize(horizontal: !cut, vertical: true)
            .alignmentGuide(.top) { $0[.firstTextBaseline] - baseline }
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

func typeset(_ string: String, in font: NSFont) -> (line: CTLine, width: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
    return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}
