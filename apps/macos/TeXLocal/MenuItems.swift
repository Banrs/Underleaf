import AppKit
import SwiftUI

struct SectionLevelItems: View {
    let project: ProjectModel?

    var body: some View {
        // Numbered as Aa's are (`FormatMenu`), once there's a project's class to number them by.
        ForEach(project?.headingStyles ?? HeadingStyle.styles(of: nil, hasChapters: false), id: \.command) { style in
            Toggle(project == nil ? style.title : style.numberedTitle,
                   isOn: Binding(get: { project?.headingLevel.command == style.command },
                                 set: { _ in project?.editor.perform(.heading, style.command) }))
        }
    }
}

/// A grid per kind: a list of 30 Greek letters runs off a laptop's screen.
struct SymbolItems: View {
    let project: ProjectModel?

    static func columns(_ count: Int) -> Int {
        [6, 5, 7].first { count % $0 == 0 } ?? 6
    }

    var body: some View {
        ForEach(Menus.shared.symbolGroups, id: \.title) { group in
            let symbols = group.symbols, columns = Self.columns(symbols.count)
            Menu(group.title) {
                ForEach(Array(stride(from: 0, to: symbols.count, by: columns)), id: \.self) { start in
                    // A palette row, which shows its items' images: text alone draws blank (27.2).
                    ControlGroup {
                        ForEach(symbols[start..<min(start + columns, symbols.count)], id: \.command) { symbol in
                            Button { project?.editor.perform(.symbol, symbol.command) } label: {
                                Label {
                                    Text(verbatim: MathGlyphs.spokenName(symbol.glyph, symbol.command))
                                } icon: {
                                    Image(nsImage: MathGlyphs.image(symbol.command))
                                }
                            }
                            .help(symbol.command)
                        }
                    }
                    .controlGroupStyle(.palette)
                }
            }
        }
    }
}

struct MathMenuItems: View {
    let project: ProjectModel?
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
        ForEach(Menus.shared.templates.math, id: \.title) { template in
            Button { project?.insert(template) } label: {
                Text(template.title)
                Text(verbatim: "\\begin{\(template.body)}")
            }
        }
        Section("Symbols") { SymbolItems(project: project) }
    }
}

struct InsertMenuItems: View {
    let project: ProjectModel?

    var body: some View {
        let templates = Menus.shared.templates
        items(templates.insert)
        Menu("List") { items(templates.list) }
        Divider()
        Menu("References and Links") { items(templates.references) }
    }

    private func items(_ templates: [Template]) -> some View {
        ForEach(templates, id: \.title) { template in
            Button(template.title) { project?.insert(template) }
        }
    }
}

/// The symbols as the core draws them (`glyph_svg`): each one's ink centred in a square, as TeX sets it in text.
enum MathGlyphs {
    private static var images: [String: NSImage] = [:]
    /// AppKit selects a palette's item as it's chosen (27.2), and these insert, they don't select.
    private static let unmark = NotificationCenter.default.addObserver(
        forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { note in
        // Posted on the main thread, which has the menu.
        nonisolated(unsafe) let item = note.userInfo?["MenuItem"] as? NSMenuItem
        MainActor.assumeIsolated {
            guard let item, let image = item.image, images.values.contains(where: { $0 === image }) else { return }
            item.state = .off
        }
    }

    /// A template, so the menu tints it.
    static func image(_ command: String) -> NSImage {
        _ = unmark
        if let image = images[command] { return image }
        let drawn: Syntax.Drawing? = Syntax.call("glyph_svg", ["command": command])
        let image = drawn.flatMap { NSImage(drawing: $0) } ?? NSImage(size: NSSize(width: 24, height: 24))
        image.isTemplate = true
        images[command] = image
        return image
    }

    static func spokenName(_ glyph: String, _ command: String) -> String {
        let letter = String(command.dropFirst())
        let name = glyph.first?.isLetter == true
            ? (glyph.first?.isUppercase == true ? "capital " + letter.lowercased() : letter)
            : glyph.unicodeScalars.first?.properties.name?.lowercased() ?? letter
        return "\(name), \(command)"
    }
}
