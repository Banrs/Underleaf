import AppKit

extension SyntaxTheme {
    func color(_ kind: HighlightKind) -> NSColor {
        if let shown = Self.made[self] { return shown[kind] ?? .textColor }
        let shown = palette.mapValues { color in
            NSColor.adapting(Dictionary(uniqueKeysWithValues: NSColor.textAppearances.map { ($0, color.legibleAsText(in: $0)) }),
                             fallback: .textColor)
        }
        Self.made[self] = shown
        return shown[kind] ?? .textColor
    }

    private static var made: [SyntaxTheme: [HighlightKind: NSColor]] = [:]

    private var palette: [HighlightKind: NSColor] {
        func rgb(_ light: UInt32, _ dark: UInt32) -> NSColor {
            NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .hex(dark) : .hex(light) }
        }
        return switch self {
        case .overleaf: [.command: rgb(0x0000FF, 0x8BE9FD), .argument: rgb(0x318495, 0xFFB86C), .maths: rgb(0x036A07, 0xF1FA8C),
                         .comment: rgb(0x4C886B, 0x6272A4), .invalid: rgb(0xFF0000, 0xFF79C6)]
        case .texstudio: [.command: rgb(0x800000, 0x60CDF2), .argument: rgb(0x008000, 0x60F260), .maths: rgb(0x509600, 0x85F218),
                          .comment: rgb(0x808080, 0x667299), .invalid: rgb(0xC00000, 0xF2F218)]
        case .system: [.command: .systemPink, .argument: .systemTeal, .maths: .systemPurple, .comment: .secondaryLabelColor,
                       .invalid: .systemRed]
        }
    }
}

private extension NSColor {
    static func hex(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255,
                alpha: 1)
    }
}
