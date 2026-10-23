import UIKit
import SwiftUI

/// The symbols as the core draws them (`glyph_svg`): each one's ink centred in a square, as TeX sets it in text.
enum MathGlyphs {
    private static var images: [String: UIImage] = [:]

    static func icon(_ command: String) -> Image { Image(uiImage: image(command)) }

    /// A template, so the menu tints it.
    private static func image(_ command: String) -> UIImage {
        if let image = images[command] { return image }
        let drawn: Syntax.Drawing? = Syntax.call("glyph_svg", ["command": command])
        let image = (drawn.flatMap { UIImage(drawing: $0) } ?? UIImage()).withRenderingMode(.alwaysTemplate)
        images[command] = image
        return image
    }
}
