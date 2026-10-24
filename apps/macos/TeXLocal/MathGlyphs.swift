import AppKit
import SwiftUI

/// The symbols as the system font draws them, as the Character Viewer does: each glyph centred in a square.
enum MathGlyphs {
    private static var images: [String: NSImage] = [:]

    /// A template, so the menu tints it.
    static func icon(_ glyph: String, _ command: String) -> Image {
        if let image = images[command] { return Image(nsImage: image) }
        let text = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 17)])
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let size = text.size()
            text.draw(at: NSPoint(x: (24 - size.width) / 2, y: (24 - size.height) / 2))
            return true
        }
        image.isTemplate = true
        images[command] = image
        return Image(nsImage: image)
    }
}
