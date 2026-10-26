import AppKit

/// The editor's syntax colours, by `HighlightKind`, each raised to a legible contrast in every appearance.
enum SyntaxTheme: String, CaseIterable, Identifiable {
    /// Overleaf's source editor themes ("textmate", "overleaf_dark"), by the lezer tags it gives LaTeX's nodes; its
    /// `.tok-keyword` has no kind here.
    case overleaf
    /// TeXstudio's formats (defaultFormats.qxf, defaultFormatsDark.qxf); invalid is "braceMismatch", whose fill Light
    /// takes and whose text Dark takes, the fill not being drawn.
    case texstudio
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overleaf: "Overleaf"
        case .texstudio: "TeXstudio"
        case .system: "System"
        }
    }

    func color(_ kind: HighlightKind) -> NSColor {
        let shown = Self.made[self] ?? palette.map { color in
            NSColor.adapting(Dictionary(uniqueKeysWithValues: NSColor.textAppearances.map { ($0, color.legibleAsText(in: $0)) }),
                             fallback: .textColor)
        }
        Self.made[self] = shown
        return shown[Int(kind.rawValue)]
    }

    private static var made: [SyntaxTheme: [NSColor]] = [:]

    private var palette: [NSColor] {
        func rgb(_ light: UInt32, _ dark: UInt32) -> NSColor {
            NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .hex(dark) : .hex(light) }
        }
        return switch self {
        case .overleaf: [rgb(0x0000FF, 0x8BE9FD), rgb(0x318495, 0xFFB86C), rgb(0x036A07, 0xF1FA8C), rgb(0x4C886B, 0x6272A4),
                         rgb(0xFF0000, 0xFF79C6)]
        case .texstudio: [rgb(0x800000, 0x60CDF2), rgb(0x008000, 0x60F260), rgb(0x509600, 0x85F218), rgb(0x808080, 0x667299),
                          rgb(0xC00000, 0xF2F218)]
        case .system: [.systemPink, .systemTeal, .systemPurple, .secondaryLabelColor, .systemRed]
        }
    }
}

private extension NSColor {
    static func hex(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255,
                alpha: 1)
    }
}
