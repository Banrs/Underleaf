import UIKit
import SwiftUI

/// The Math menu's symbols, each its glyph centred in a square, as the Mac's menu shows the core's drawing of it.
enum MathGlyphs {
    private static var images: [String: UIImage] = [:]
    private static let glyphs = Dictionary(Menus.shared.symbolGroups.flatMap(\.symbols).map { ($0.command, $0.glyph) }) { first, _ in first }

    static func icon(_ command: String) -> Image { Image(uiImage: image(command)) }

    /// A template, so the menu tints it.
    private static func image(_ command: String) -> UIImage {
        if let image = images[command] { return image }
        let glyph = (glyphs[command] ?? "?") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont(name: "TimesNewRomanPS-ItalicMT", size: 20) ?? .systemFont(ofSize: 20)]
        let size = glyph.size(withAttributes: attributes)
        let side = max(24, size.width, size.height)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            glyph.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
        }.withRenderingMode(.alwaysTemplate)
        images[command] = image
        return image
    }
}
