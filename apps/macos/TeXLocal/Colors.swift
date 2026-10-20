import AppKit
import SwiftUI

extension ShapeStyle where Self == Color { static var textSurface: Color { Color(nsColor: .textBackgroundColor) } }

extension NSColor {
    /// An Increase Contrast appearance asked for by name is the plain one unless the setting is on, so its ratio goes by the name.
    static let textAppearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]

    /// The core's colour commands' arguments for an appearance: the editor's background and current line's fill.
    static func contrastArguments(in name: NSAppearance.Name) -> [String: Any]? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        return ["dark": name == .darkAqua || name == .accessibilityHighContrastDarkAqua,
                "increaseContrast": name != .aqua && name != .darkAqua,
                "background": NSColor.textBackgroundColor.rgba(in: appearance),
                "fill": NSColor.secondarySystemFill.rgba(in: appearance)]
    }

    /// Raised by the core to the HIG's 4.5:1 on the editor's background and current line, 7:1 with Increase Contrast, or `ratio`.
    func legibleAsText(in name: NSAppearance.Name, ratio: Double? = nil) -> NSColor {
        guard var args = Self.contrastArguments(in: name), let appearance = NSAppearance(named: name) else { return self }
        args["color"] = rgba(in: appearance)
        if let ratio { args["ratio"] = ratio }
        let legible: [Double]? = Syntax.call("legible", args)
        return legible.map { Self.srgb($0) } ?? self
    }

    static func adapting(_ colors: [NSAppearance.Name: NSColor], fallback: NSColor) -> NSColor {
        let names = textAppearances
        // `@Sendable`: a colour resolved off the main thread would trap on the main actor's check.
        return NSColor(name: nil) { @Sendable in $0.bestMatch(from: names).flatMap { colors[$0] } ?? fallback }
    }

    nonisolated func rgba(in appearance: NSAppearance) -> [Double] {
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance { color = usingColorSpace(.sRGB) }
        guard let color else { return [0, 0, 0, 1] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Double($0) }
    }

    static func srgb(_ rgba: [Double]) -> NSColor {
        NSColor(srgbRed: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
    }

    nonisolated func resolved(in appearance: NSAppearance) -> NSColor {
        var color = self
        appearance.performAsCurrentDrawingAppearance { color = usingColorSpace(.sRGB) ?? self }
        return color
    }

    /// PDFKit tints a system colour it's given with the wallpaper, which would set it a shade apart from the editor's.
    static let untintedTextBackground = NSColor(name: nil) { NSColor.textBackgroundColor.resolved(in: $0) }
}

/// A theme of the core's by its id, its colours made legible in each appearance; an id the core no longer has reads as none.
struct SyntaxTheme: RawRepresentable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    init?(rawValue: String) {
        guard Self.listed.contains(where: { $0.id == rawValue }) else { return nil }
        self.rawValue = rawValue
    }

    private init(_ id: String) { rawValue = id }

    static let overleaf = SyntaxTheme("overleaf")
    static let all = listed.map { SyntaxTheme($0.id) }

    var title: String { Self.listed.first { $0.id == rawValue }?.title ?? rawValue }

    private nonisolated struct Listed: Decodable { let id, title: String }

    private static let listed: [Listed] = Syntax.call("themes", [:]) ?? []

    func color(_ kind: HighlightKind) -> NSColor {
        let shown = Self.made[self] ?? colors()
        Self.made[self] = shown
        return shown[Int(kind.rawValue)]
    }

    private static var made: [SyntaxTheme: [NSColor]] = [:]

    private static let systemColors: [String: NSColor] = [
        "systemPink": .systemPink, "systemTeal": .systemTeal, "systemPurple": .systemPurple,
        "secondaryLabelColor": .secondaryLabelColor, "systemRed": .systemRed,
    ]

    /// Kinds the theme colours alike share one colour.
    private func colors() -> [NSColor] {
        var shades: [NSAppearance.Name: [[Double]]] = [:]
        for name in NSColor.textAppearances {
            guard var args = NSColor.contrastArguments(in: name), let appearance = NSAppearance(named: name) else { continue }
            args["theme"] = rawValue
            args["system"] = Self.systemColors.mapValues { $0.rgba(in: appearance) }
            shades[name] = Syntax.call("theme_colors", args) as [[Double]]?
        }
        var shared: [[[Double]?]: NSColor] = [:]
        return HighlightKind.allCases.map { kind -> NSColor in
            let index = Int(kind.rawValue)
            let byName = shades.compactMapValues { index < $0.count ? $0[index] : nil }
            let key = NSColor.textAppearances.map { byName[$0] }
            if let color = shared[key] { return color }
            let color = NSColor.adapting(byName.mapValues { NSColor.srgb($0) }, fallback: .textColor)
            shared[key] = color
            return color
        }
    }
}
