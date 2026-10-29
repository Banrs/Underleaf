import SwiftUI

struct SectionLevelItems: View {
    let project: ProjectModel?

    var body: some View {
        let styles = project?.headingStyles ?? HeadingStyle.standard
        ForEach(styles, id: \.command) { style in
            if style.command == "paragraph" { Divider() }
            Toggle(style.title,
                   isOn: Binding(get: { project?.headingCommand == style.command },
                                 set: { _ in project?.views?.perform(.heading(style.command)) }))
        }
        .disabled(project?.sourceToolsEnabled != true)
    }
}

struct SymbolItems: View {
    let project: ProjectModel?

    static func columns(_ count: Int) -> Int { [6, 5, 7].first { count % $0 == 0 } ?? 6 }

    var body: some View {
        ForEach(Menus.shared.symbolGroups, id: \.title) { group in
            let symbols = group.symbols
            let columns = Self.columns(symbols.count)
            Menu(group.title) {
                ForEach(Array(stride(from: 0, to: symbols.count, by: columns)), id: \.self) { start in
                    ControlGroup {
                        ForEach(symbols[start..<min(start + columns, symbols.count)], id: \.command) { symbol in
                            Button { project?.views?.perform(.symbol(symbol.command)) } label: {
                                Label {
                                    Text(verbatim: MathGlyphs.spokenName(symbol.glyph, symbol.command))
                                } icon: {
                                    MathGlyphs.icon(symbol.glyph, symbol.command)
                                }
                            }
                            .help(symbol.command)
                        }
                        .disabled(project?.sourceToolsEnabled != true)
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
    var inlineMathEnabled = true
    let inlineMath: () -> Void

    var body: some View {
        let off = project?.sourceToolsEnabled != true
        Button(action: inlineMath) {
            Text(MenuCommand.editMath.title)
            Text(verbatim: "$ … $")
        }
        .keyboardShortcut(shortcut)
        .disabled(off || !inlineMathEnabled)
        Group {
            Button { project?.views?.perform(.displayMath) } label: {
                Text("Display Math")
                Text(verbatim: "\\[ … \\]")
            }
            ForEach(Menus.shared.templates.math, id: \.title) { template in
                Button { project?.insert(template) } label: {
                    Text(template.title)
                    Text(verbatim: "\\begin{\(template.body)}")
                }
            }
        }
        .disabled(off)
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
        .disabled(project?.sourceToolsEnabled != true)
    }
}

extension MathGlyphs {
    static func spokenName(_ glyph: String, _ command: String) -> String {
        let letter = String(command.dropFirst())
        let name = glyph.first?.isLetter == true
            ? (glyph.first?.isUppercase == true ? "capital " + letter.lowercased() : letter)
            : glyph.unicodeScalars.first?.properties.name?.lowercased() ?? letter
        return "\(name), \(command)"
    }
}
