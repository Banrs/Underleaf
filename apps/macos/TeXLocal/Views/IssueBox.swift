import AppKit
import SwiftUI

struct IssueBox: View, Equatable {
    let isError: Bool
    let isLive: Bool
    let issues: Int
    let text: String?
    /// Whether the message is cut at its tail to the room the box is given. One that isn't keeps its text whole, since a box
    /// measured off screen came out half a point narrower than its text needed at 2x ("Reference undefined", 162 against 162.5 pt).
    let truncates: Bool
    let font: NSFont

    static func tint(error: Bool) -> NSColor { error ? .systemRed : .systemYellow }

    static func line(error: Bool, live: Bool) -> NSColor { live ? .quaternarySystemFill : tint(error: error).withAlphaComponent(0.1) }

    static let underlines = [false: tint(error: false).legible(ratio: 3), true: tint(error: true).legible(ratio: 3)]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        HStack {
            if issues > 1 { Text(verbatim: "\(issues)").monospacedDigit() }
            Image(systemName: isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            if let text { Text(verbatim: text).lineLimit(1).fixedSize(horizontal: !truncates, vertical: false) }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .font(Font(font as CTFont))
        .background(Color(nsColor: isLive ? .textBackgroundColor : Self.tint(error: isError).withAlphaComponent(0.25)), in: shape)
        .overlay { if isLive { shape.strokeBorder(.separator) } }
        .accessibilityHidden(true)
    }
}
