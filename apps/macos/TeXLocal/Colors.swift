import AppKit
import SwiftUI

extension ShapeStyle where Self == Color {
    /// The editor's background, for the panes and bars that are one surface with it: the
    /// system's text background, untinted by the wallpaper as the window's would be.
    static var textSurface: Color { Color(nsColor: .textBackgroundColor) }
}

extension NSColor {
    /// WCAG's relative luminance.
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    /// WCAG's contrast ratio, 1 to 21.
    func contrast(with other: NSColor) -> CGFloat {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Mixed towards black on a light background or white on a dark one, as little as gives
    /// `ratio` on it, so it keeps its hue; as it is when it has that already.
    func contrasting(with background: NSColor, by ratio: CGFloat) -> NSColor {
        // Where black and white contrast equally with a colour.
        let ink: NSColor = background.luminance > 0.179 ? .black : .white
        var mixed = self
        for step in 1...20 where mixed.contrast(with: background) < ratio {
            mixed = blended(withFraction: CGFloat(step) / 20, of: ink) ?? ink
        }
        return mixed
    }

    /// `contrasting(with:by:)` on the text's background in that appearance.
    func contrasting(in appearance: NSAppearance.Name, by ratio: CGFloat) -> NSColor {
        contrasting(with: NSAppearance(named: appearance).map(NSColor.textBackground(in:)) ?? .white, by: ratio)
    }

    /// The system's text background as it is in an appearance.
    nonisolated static func textBackground(in appearance: NSAppearance) -> NSColor {
        var color = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        return color
    }

    /// The text background, resolved for each appearance: PDFKit tints a system colour it's
    /// given with the wallpaper, as Preview's canvas, which would set it a shade apart from the editor's.
    static let untintedTextBackground = NSColor(name: nil, dynamicProvider: textBackground(in:))
}

extension NSAppearance {
    /// Increase Contrast is on: its appearances answer only `bestMatch(from:)`.
    var increasesContrast: Bool {
        let all: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        return bestMatch(from: all).map([.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua].contains) == true
    }
}
