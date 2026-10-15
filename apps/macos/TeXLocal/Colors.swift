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
    static func ground(_ name: NSAppearance.Name) -> [String: Any]? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        return ["dark": name == .darkAqua || name == .accessibilityHighContrastDarkAqua,
                "increaseContrast": name != .aqua && name != .darkAqua,
                "background": NSColor.textBackgroundColor.rgba(in: appearance),
                "fill": NSColor.secondarySystemFill.rgba(in: appearance)]
    }

    /// In each appearance raised by the core to the HIG's 4.5:1 for text under 18 points on the editor's background and
    /// its current line, and to WCAG's enhanced 7:1 with Increase Contrast.
    var legibleAsText: NSColor {
        let resolved = Dictionary(uniqueKeysWithValues: Self.textAppearances.map { ($0, legibleAsText(in: $0)) })
        return .adapting(resolved, fallback: self)
    }

    /// `ratio` in place of the text's 4.5:1 (7:1 with Increase Contrast), as for a non-text mark's 3:1.
    func legibleAsText(in name: NSAppearance.Name, ratio: Double? = nil) -> NSColor {
        guard var args = Self.ground(name), let appearance = NSAppearance(named: name) else { return self }
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
    static let untintedTextBackground = NSColor(name: nil) { NSColor.textBackgroundColor.resolved(in: $0) }
}
