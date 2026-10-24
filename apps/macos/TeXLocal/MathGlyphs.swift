import AppKit
import SwiftUI

/// The symbols as the core draws them (`glyph_svg`): each one's ink centred in a square, as TeX sets it in text.
enum MathGlyphs {
    private static var images: [String: NSImage] = [:]
    static func icon(_ command: String) -> Image { Image(nsImage: image(command)) }

    /// A template, so the menu tints it.
    static func image(_ command: String) -> NSImage {
        if let image = images[command] { return image }
        let drawn: Syntax.Drawing? = Syntax.call("glyph_svg", ["command": command])
        let image = drawn.flatMap { NSImage(drawing: $0) } ?? NSImage(size: NSSize(width: 24, height: 24))
        image.isTemplate = true
        images[command] = image
        return image
    }
}
