import UIKit

/// The editor's appearances, as the Mac's: light and dark, each with Increase Contrast or without.
nonisolated struct TextAppearance: Hashable, Sendable {
    var dark, increaseContrast: Bool

    static let all = [false, true].flatMap { dark in [false, true].map { TextAppearance(dark: dark, increaseContrast: $0) } }

    init(dark: Bool, increaseContrast: Bool) { (self.dark, self.increaseContrast) = (dark, increaseContrast) }

    init(_ traits: UITraitCollection) {
        self.init(dark: traits.userInterfaceStyle == .dark, increaseContrast: traits.accessibilityContrast == .high)
    }

    @MainActor var traits: UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.accessibilityContrast = increaseContrast ? .high : .normal
        }
    }
}

extension UIColor {
    /// The editor's background: the system's, as Notes' and Swift Playgrounds' are.
    static let editorBackground = UIColor.systemBackground

    /// The core's colour commands' arguments for an appearance: the editor's background and current line's fill.
    static func contrastArguments(in appearance: TextAppearance) -> [String: Any] {
        ["dark": appearance.dark, "increaseContrast": appearance.increaseContrast,
         "background": editorBackground.rgba(in: appearance), "fill": currentLine.rgba(in: appearance)]
    }

    static let currentLine = UIColor {
        srgb($0.userInterfaceStyle == .dark ? SourceTextView.currentLineRGBA.dark : SourceTextView.currentLineRGBA.light)
    }

    /// Raised by the core to the HIG's 4.5:1 on the editor's background and current line, 7:1 with Increase Contrast.
    func legibleAsText(in appearance: TextAppearance) -> UIColor {
        var args = Self.contrastArguments(in: appearance)
        args["color"] = rgba(in: appearance)
        let legible: [Double]? = Syntax.call("legible", args)
        return legible.map { Self.srgb($0) } ?? self
    }

    static func adapting(_ colors: [TextAppearance: UIColor], fallback: UIColor) -> UIColor {
        UIColor { @Sendable traits in colors[TextAppearance(traits)] ?? fallback }
    }

    func rgba(in appearance: TextAppearance) -> [Double] {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 1)
        resolvedColor(with: appearance.traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Double($0) }
    }

    nonisolated static func srgb(_ rgba: [Double]) -> UIColor {
        UIColor(red: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
    }
}

/// A theme's colours, made legible in each appearance.
extension SyntaxTheme {
    func color(_ kind: HighlightKind) -> UIColor {
        let shown = Self.made[self] ?? colors()
        Self.made[self] = shown
        return shown[Int(kind.rawValue)]
    }

    private static var made: [SyntaxTheme: [UIColor]] = [:]

    private static let systemColors: [String: UIColor] = [
        "systemPink": .systemPink, "systemTeal": .systemTeal, "systemPurple": .systemPurple,
        "secondaryLabelColor": .secondaryLabel, "systemRed": .systemRed,
    ]

    private func colors() -> [UIColor] {
        var shades: [TextAppearance: [[Double]]] = [:]
        for appearance in TextAppearance.all {
            var args = UIColor.contrastArguments(in: appearance)
            args["theme"] = rawValue
            args["system"] = Self.systemColors.mapValues { $0.rgba(in: appearance) }
            shades[appearance] = Syntax.call("theme_colors", args) as [[Double]]?
        }
        return HighlightKind.allCases.map { kind in
            let index = Int(kind.rawValue)
            let byAppearance = shades.compactMapValues { index < $0.count ? $0[index] : nil }
            return UIColor.adapting(byAppearance.mapValues { UIColor.srgb($0) }, fallback: .label)
        }
    }
}
