import AppKit
import SwiftUI

/// Shared Format and toolbar choices: the levels the class has, the caret's checked.
struct SectionLevelItems: View {
    let project: ProjectModel?

    var body: some View {
        ForEach(project?.headingStyles.levels ?? HeadingLevel.all, id: \.self) { level in
            Toggle(level.title, isOn: Binding(get: { project?.headingLevel == level },
                                              set: { _ in project?.editor.perform(.heading, level.command) }))
        }
    }
}

/// The symbols by kind, each kind a grid of TeX's glyphs: a list of 30 Greek letters runs off a
/// laptop's screen. The glyph's command is its help tag.
struct SymbolItems: View {
    let project: ProjectModel?

    /// About six to a row, in full rows: a palette spreads a short row across the menu's width.
    static func columns(_ count: Int) -> Int {
        [6, 5, 7].first { count % $0 == 0 } ?? 6
    }

    var body: some View {
        ForEach(symbolGroups, id: \.0) { title, symbols in
            let columns = Self.columns(symbols.count)
            Menu(title) {
                ForEach(Array(stride(from: 0, to: symbols.count, by: columns)), id: \.self) { start in
                    // A palette row, which shows its items' images: text alone draws blank (27.2).
                    // The title is what VoiceOver says.
                    ControlGroup {
                        ForEach(symbols[start..<min(start + columns, symbols.count)], id: \.1) { glyph, command in
                            Button { project?.editor.perform(.symbol, command) } label: {
                                Label {
                                    Text(verbatim: MathGlyphs.spokenName(glyph, command))
                                } icon: {
                                    Image(nsImage: MathGlyphs.image(glyph, command))
                                }
                            }
                            .help(command)
                        }
                    }
                    .controlGroupStyle(.palette)
                }
            }
        }
    }
}

/// Each item over what it puts in, as its subtitle.
struct MathMenuItems: View {
    let project: ProjectModel?
    /// The menu bar's Inline Math carries the shortcut; the toolbar's leaves it there.
    var shortcut: KeyboardShortcut?
    let inlineMath: () -> Void

    var body: some View {
        Button(action: inlineMath) {
            Text(MenuCommand.editMath.title)
            Text(verbatim: "$ … $")
        }
        .keyboardShortcut(shortcut)
        Button { project?.editor.perform(.displayMath) } label: {
            Text("Display Math")
            // Verbatim: a string literal is Markdown, where "\\[" is "[".
            Text(verbatim: "\\[ … \\]")
        }
        ForEach(mathTemplates, id: \.title) { template in
            Button { project?.insert(template) } label: {
                Text(template.title)
                Text(verbatim: "\\begin{\(template.body)}")
            }
        }
        // A section, so a symbol is one submenu down (HIG, Menus); it brings its own separators.
        Section("Symbols") { SymbolItems(project: project) }
    }
}

struct InsertMenuItems: View {
    let project: ProjectModel?

    var body: some View {
        items(insertTemplates)
        Menu("List") { items(listTemplates) }
        Divider()
        Menu("References and Links") { items(referenceTemplates) }
    }

    private func items(_ templates: [Template]) -> some View {
        ForEach(templates, id: \.title) { template in
            Button(template.title) { project?.insert(template) }
        }
    }
}

/// The symbols as TeX draws them, in the KaTeX fonts the maths preview has (Resources/KaTeX):
/// lowercase Greek in math italic, the big operators at their text size, the rest upright;
/// what those lack from KaTeX's AMS font, then STIX Two Math.
@MainActor
enum MathGlyphs {
    private static let side: CGFloat = 24
    private static let size: CGFloat = 19
    private static let bigOperators: Set = ["\\sum", "\\prod", "\\int", "\\oint"]
    private static var images: [String: NSImage] = [:]
    /// A chosen symbol isn't marked: AppKit selects a palette's item as it's chosen (27.2),
    /// and these insert, they don't select.
    private static let unmark = NotificationCenter.default.addObserver(
        forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { note in
        // Posted on the main thread, which has the menu.
        nonisolated(unsafe) let item = note.userInfo?["MenuItem"] as? NSMenuItem
        MainActor.assumeIsolated {
            guard let item, let image = item.image, images.values.contains(where: { $0 === image }) else { return }
            item.state = .off
        }
    }

    private static let faces: [String: NSFontDescriptor] = {
        guard let folder = Bundle.main.url(forResource: "KaTeX", withExtension: nil)?.appending(path: "fonts") else { return [:] }
        var faces: [String: NSFontDescriptor] = [:]
        for face in ["Main-Regular", "Math-Italic", "Size1-Regular", "AMS-Regular"] {
            // Unregistered: the app's fonts stay its own.
            guard let data = try? Data(contentsOf: folder.appending(path: "KaTeX_\(face).woff2")),
                  let made = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [NSFontDescriptor],
                  let descriptor = made.first else { continue }
            faces[face] = descriptor
        }
        return faces
    }()

    private static func font(_ glyph: String, _ command: String) -> NSFont {
        let face = bigOperators.contains(command) ? "Size1-Regular"
            : glyph.first?.isLowercase == true ? "Math-Italic" : "Main-Regular"
        let cascade = ["Main-Regular", "AMS-Regular"].filter { $0 != face }.compactMap { faces[$0] }
            + [NSFontDescriptor(name: "STIXTwoMath-Regular", size: size)]
        guard let descriptor = faces[face] else { return .systemFont(ofSize: size) }
        return NSFont(descriptor: descriptor.addingAttributes([.cascadeList: cascade]), size: size) ?? .systemFont(ofSize: size)
    }

    /// The glyph's ink centred in a square, as a template image, so the menu colours it.
    static func image(_ glyph: String, _ command: String) -> NSImage {
        _ = unmark
        if let image = images[command] { return image }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: font(glyph, command)]))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
            CTLineDraw(line, context)
            return true
        }
        image.isTemplate = true
        images[command] = image
        return image
    }

    /// What VoiceOver says: a Greek letter by its command's name, another symbol by its
    /// Unicode name, then the command.
    static func spokenName(_ glyph: String, _ command: String) -> String {
        let letter = String(command.dropFirst())
        let name = glyph.first?.isLetter == true
            ? (glyph.first?.isUppercase == true ? "capital " + letter.lowercased() : letter)
            : glyph.unicodeScalars.first?.properties.name?.lowercased() ?? letter
        return "\(name), \(command)"
    }
}
