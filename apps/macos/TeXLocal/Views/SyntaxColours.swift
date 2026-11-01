import AppKit

extension HighlightKind {
    var color: NSColor { Self.colors[self] ?? .textColor }

    private static let colors: [HighlightKind: NSColor] = {
        let system: [HighlightKind: NSColor] = [.command: .systemPink, .argument: .systemTeal, .maths: .systemPurple,
                                                .comment: .secondaryLabelColor, .invalid: .systemRed]
        return system.mapValues { color in
            .adapting(Dictionary(uniqueKeysWithValues: NSColor.textAppearances.map { ($0, color.legibleAsText(in: $0)) }),
                      fallback: .textColor)
        }
    }()
}
