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

    /// This colour as text on the text's background, and on the editor's current line, which is
    /// greyer: in each appearance raised, by `contrasting`, to the HIG's 4.5:1 for text under
    /// 18 points, and to WCAG's enhanced 7:1 with Increase Contrast.
    var legibleAsText: NSColor {
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        let resolved = Dictionary(uniqueKeysWithValues: names.map { ($0, legibleAsText(in: $0)) })
        return NSColor(name: nil) { [resolved] in $0.bestMatch(from: names).flatMap { resolved[$0] } ?? self }
    }

    /// `legibleAsText` in one appearance. An Increase Contrast appearance asked for by name is the
    /// plain one's unless the setting is on, so its ratio goes by the name.
    func legibleAsText(in name: NSAppearance.Name) -> NSColor {
        guard let appearance = NSAppearance(named: name) else { return self }
        let background = NSColor.textBackground(in: appearance)
        var color = self, fill = NSColor.secondarySystemFill
        appearance.performAsCurrentDrawingAppearance {
            color = usingColorSpace(.sRGB) ?? self
            fill = fill.usingColorSpace(.sRGB) ?? fill
        }
        // A translucent colour (a label's, the fill's) as it shows on the background, mixed by sRGB's
        // components as the window server does: `blended` gives its answer in the calibrated space,
        // where the fill on white comes out at 239 for the 235 on screen.
        func shown(_ color: NSColor) -> NSColor {
            let alpha = color.alphaComponent
            guard alpha < 1 else { return color }
            func mixed(_ component: KeyPath<NSColor, CGFloat>) -> CGFloat {
                background[keyPath: component] * (1 - alpha) + color[keyPath: component] * alpha
            }
            return NSColor(srgbRed: mixed(\.redComponent), green: mixed(\.greenComponent), blue: mixed(\.blueComponent), alpha: 1)
        }
        // The current line is the fill over the background (`SourceTextView.drawBackground`), nearer
        // the text's colours than the background is: a comment at 4.8:1 on white was 4.0:1 on it.
        let ratio: CGFloat = [.aqua, .darkAqua].contains(name) ? 4.5 : 7
        return shown(color).contrasting(with: background, by: ratio).contrasting(with: shown(fill), by: ratio)
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

    /// The under-page background likewise: the completion list's ground over the editor's.
    static let untintedUnderPageBackground = NSColor(name: nil) { appearance in
        var color = NSColor.underPageBackgroundColor
        appearance.performAsCurrentDrawingAppearance { color = color.usingColorSpace(.sRGB) ?? color }
        return color
    }
}
