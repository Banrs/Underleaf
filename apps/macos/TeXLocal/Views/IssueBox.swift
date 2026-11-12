import AppKit
import SwiftUI

struct IssueBox: View, Equatable {
    let isError: Bool
    let isLive: Bool
    let issues: Int
    let text: String?
    /// Whether the message is truncated to fit the box. Otherwise it stays whole, since a box measured off screen came out
    /// half a point too narrow for its text at 2x.
    let truncates: Bool
    let font: NSFont

    static func tint(error: Bool) -> NSColor { error ? .systemRed : .systemYellow }

    static func line(error: Bool, live: Bool) -> NSColor { live ? .quaternarySystemFill : tint(error: error).withAlphaComponent(0.1) }

    static let underlines = [false: tint(error: false).legible(ratio: 3), true: tint(error: true).legible(ratio: 3)]

    var body: some View {
        // The corners of the row's highlight beneath it.
        let shape = RoundedRectangle(cornerRadius: 4, style: .circular)
        HStack {
            if issues > 1 { Text(verbatim: "\(issues)").monospacedDigit() }
            Image(systemName: isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
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
