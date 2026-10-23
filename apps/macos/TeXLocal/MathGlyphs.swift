import AppKit
import SwiftUI

/// The symbols as the core draws them (`glyph_svg`): each one's ink centred in a square, as TeX sets it in text.
enum MathGlyphs {
    private static var images: [String: NSImage] = [:]
    /// 27.2: AppKit selects a palette's item as it's chosen, and these insert, they don't select.
    private static let unmark = NotificationCenter.default.addObserver(
        forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { note in
        nonisolated(unsafe) let item = note.userInfo?["MenuItem"] as? NSMenuItem
        MainActor.assumeIsolated {
            guard let item, let image = item.image, images.values.contains(where: { $0 === image }) else { return }
            item.state = .off
        }
    }
    /// 27.2: AppKit sizes a menu of palettes alone 8 pt short of centring them.
    private static let centre = NotificationCenter.default.addObserver(
        forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { note in
        nonisolated(unsafe) let menu = note.object as? NSMenu
        MainActor.assumeIsolated {
            guard let menu, menu.items.allSatisfy({ $0.submenu?.presentationStyle == .palette }) else { return }
            menu.minimumWidth = 0
            menu.minimumWidth = menu.size.width + 8
        }
    }

    static func icon(_ command: String) -> Image { Image(nsImage: image(command)) }

    /// A template, so the menu tints it.
    static func image(_ command: String) -> NSImage {
        _ = (unmark, centre)
        if let image = images[command] { return image }
        let drawn: Syntax.Drawing? = Syntax.call("glyph_svg", ["command": command])
        let image = drawn.flatMap { NSImage(drawing: $0) } ?? NSImage(size: NSSize(width: 24, height: 24))
        image.isTemplate = true
        images[command] = image
        return image
    }
}
