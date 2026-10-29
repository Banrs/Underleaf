import AppKit
import SwiftUI

enum MathGlyphs {
    private static var images: [String: NSImage] = [:]

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

    static func spokenName(_ glyph: String, _ command: String) -> String {
        let letter = String(command.dropFirst())
        let name = glyph.first?.isLetter == true
            ? (glyph.first?.isUppercase == true ? "capital " + letter.lowercased() : letter)
            : glyph.unicodeScalars.first?.properties.name?.lowercased() ?? letter
        return "\(name), \(command)"
    }
}
