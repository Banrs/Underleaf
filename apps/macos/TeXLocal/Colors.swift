import AppKit
import SwiftUI

extension ShapeStyle where Self == Color { static var textSurface: Color { Color(nsColor: .textBackgroundColor) } }

extension NSColor {
    /// An Increase Contrast appearance asked for by name is the plain one unless the setting is on, so its ratio goes by the name.
    static let textAppearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]

    /// Xcode 27's Default (Light) and Default (Dark) themes' `DVTSourceTextCurrentLineHighlightColor`, in sRGB.
    static let currentLine = NSColor(name: nil) {
        srgb($0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? [0.138526, 0.146864, 0.169283, 1] : [0.909804, 0.94902, 1, 1])
    }

    /// Raised to the HIG's 4.5:1 on the editor's background and current line, WCAG's 7:1 with Increase Contrast, or `ratio`:
    /// towards black on a light background or white on a dark one, as little as it takes, so it keeps its hue.
    func legibleAsText(in name: NSAppearance.Name, ratio: Double? = nil) -> NSColor {
        guard let appearance = NSAppearance(named: name) else { return self }
        let ratio = ratio ?? (name == .aqua || name == .darkAqua ? 4.5 : 7)
        let background = NSColor.textBackgroundColor.rgba(in: appearance)
        let line = Self.over(NSColor.currentLine.rgba(in: appearance), background)
        let raised = Self.contrasting(Self.contrasting(Self.over(rgba(in: appearance), background), background, ratio), line, ratio)
        return Self.srgb(raised)
    }

    static func luminance(_ c: [Double]) -> Double {
        let linear = { (v: Double) in v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
    }

    static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        let (a, b) = (luminance(a), luminance(b))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func blend(_ a: [Double], _ b: [Double], _ fraction: Double) -> [Double] {
        zip(a, b).map { $0 * (1 - fraction) + $1 * fraction }
    }

    /// Mixed by sRGB's components, as the window server mixes them.
    private static func over(_ color: [Double], _ background: [Double]) -> [Double] {
        var shown = blend(background, color, color[3])
        shown[3] = 1
        return shown
    }

    private static func contrasting(_ color: [Double], _ background: [Double], _ ratio: Double) -> [Double] {
        // Where black and white contrast equally with a colour.
        let ink: [Double] = luminance(background) > 0.179 ? [0, 0, 0, 1] : [1, 1, 1, 1]
        var mixed = color
        for step in 1...20 where contrast(mixed, background) < ratio { mixed = blend(color, ink, Double(step) / 20) }
        return mixed
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

    nonisolated static func srgb(_ rgba: [Double]) -> NSColor {
        NSColor(srgbRed: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
    }

    /// PDFKit tints a system colour it's given with the wallpaper, which would set it a shade apart from the editor's.
    static let untintedTextBackground = NSColor(name: nil) { srgb(NSColor.textBackgroundColor.rgba(in: $0)) }
}
