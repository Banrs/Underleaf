import AppKit
import SwiftUI

extension ShapeStyle where Self == Color {
    static var textSurface: Color { Color(nsColor: .textBackgroundColor) }
}

extension NSColor {
    /// The appearances text colours are made legible in. An Increase Contrast appearance asked for by name is the plain
    /// one's unless the setting is on, so its ratio goes by the name.
    static let textAppearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]

    /// What the core's colour commands take for an appearance: the editor's background, the current line's fill over it
    /// (`SourceTextView.drawBackground`), and whether it's dark and asks for Increase Contrast's 7:1 over the HIG's 4.5:1.
    static func contrastArguments(in name: NSAppearance.Name) -> [String: Any]? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        return ["dark": name == .darkAqua || name == .accessibilityHighContrastDarkAqua,
                "increaseContrast": name != .aqua && name != .darkAqua,
                "background": NSColor.textBackgroundColor.rgba(in: appearance),
                "fill": NSColor.secondarySystemFill.rgba(in: appearance)]
    }

    /// Raised by the core to the HIG's 4.5:1 for text under 18 points on the editor's background and its current line, and
    /// to WCAG's enhanced 7:1 with Increase Contrast; `ratio` in place of those, as for a non-text mark's 3:1.
    func legibleAsText(in name: NSAppearance.Name, ratio: Double? = nil) -> NSColor {
        guard var args = Self.contrastArguments(in: name), let appearance = NSAppearance(named: name) else { return self }
        args["color"] = rgba(in: appearance)
        if let ratio { args["ratio"] = ratio }
        let legible: [Double]? = Syntax.call("legible", args)
        return legible.map { Self.srgb($0) } ?? self
    }

    /// One colour per appearance of `textAppearances`, as the drawing appearance is.
    static func adapting(_ colors: [NSAppearance.Name: NSColor], fallback: NSColor) -> NSColor {
        let names = textAppearances
        // `@Sendable`, so a colour resolved off the main thread (NSColor is Sendable) doesn't trap on the
        // main-actor check this context would give the closure.
        return NSColor(name: nil) { @Sendable in $0.bestMatch(from: names).flatMap { colors[$0] } ?? fallback }
    }

    /// sRGB's components and alpha, 0 to 1, as the core takes colours.
    nonisolated func rgba(in appearance: NSAppearance) -> [Double] {
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance { color = usingColorSpace(.sRGB) }
        guard let color else { return [0, 0, 0, 1] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Double($0) }
    }

    static func srgb(_ rgba: [Double]) -> NSColor {
        guard rgba.count == 4 else { return .textColor }
        return NSColor(srgbRed: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
    }

    nonisolated func resolved(in appearance: NSAppearance) -> NSColor {
        var color = self
        appearance.performAsCurrentDrawingAppearance { color = usingColorSpace(.sRGB) ?? self }
        return color
    }

    /// PDFKit tints a system colour it's given with the wallpaper, which would set it a shade apart from the editor's.
    /// `@Sendable`, as `adapting`'s: PDFKit and AppKit may resolve it off the main thread.
    static let untintedTextBackground = NSColor(name: nil) { @Sendable in NSColor.textBackgroundColor.resolved(in: $0) }
}

/// A theme of the core's (texlocal-syntax's theme.rs) by its id, each kind's colour raised to the HIG's 4.5:1 on the
/// editor's background and its current line in each appearance, and to 7:1 with Increase Contrast. Settings stores the
/// id; one the core no longer has reads as none, so the default is used.
struct SyntaxTheme: RawRepresentable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    init?(rawValue: String) {
        guard Self.listed.contains(where: { $0.id == rawValue }) else { return nil }
        self.rawValue = rawValue
    }

    private init(_ id: String) {
        rawValue = id
    }

    /// Settings' default.
    static let overleaf = SyntaxTheme("overleaf")

    /// The core's, in its order, as Settings lists them.
    static let all = listed.map { SyntaxTheme($0.id) }

    var title: String {
        Self.listed.first { $0.id == rawValue }?.title ?? rawValue
    }

    private nonisolated struct Listed: Decodable {
        let id: String
        let title: String
    }

    private static let listed: [Listed] = Syntax.call("themes", [:]) ?? []

    func color(_ kind: HighlightKind) -> NSColor {
        let shown = Self.made[self] ?? colors()
        Self.made[self] = shown
        return shown[Int(kind.rawValue)]
    }

    private static var made: [SyntaxTheme: [NSColor]] = [:]

    /// The colours the System theme names, as AppKit has them.
    private static let systemColors: [String: NSColor] = [
        "systemPink": .systemPink, "systemTeal": .systemTeal, "systemPurple": .systemPurple,
        "secondaryLabelColor": .secondaryLabelColor, "systemRed": .systemRed,
    ]

    /// One colour per kind; kinds the theme colours alike share one.
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
