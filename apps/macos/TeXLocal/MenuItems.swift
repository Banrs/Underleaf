import SwiftUI

/// Shared Format and toolbar choices; the caret's level is checked.
struct SectionLevelItems: View {
    let project: ProjectModel?

    var body: some View {
        ForEach(HeadingLevel.all, id: \.self) { level in
            Toggle(level.title, isOn: Binding(get: { project?.headingLevel == level },
                                              set: { _ in project?.editor.perform(.heading, level.command) }))
        }
    }
}

struct SymbolItems: View {
    let project: ProjectModel?

    var body: some View {
        ForEach(symbolGroups, id: \.0) { title, symbols in
            Menu(title) {
                // The glyph over its command: the menu item's title and subtitle.
                ForEach(symbols, id: \.1) { glyph, command in
                    Button { project?.editor.perform(.symbol, command) } label: {
                        Text(glyph)
                        Text(command)
                    }
                }
            }
        }
    }
}

struct MathMenuItems<InlineMath: View>: View {
    let project: ProjectModel?
    /// Inline Math: the menu bar's own item carries its shortcut.
    let inlineMath: InlineMath

    var body: some View {
        inlineMath
        Button("Display Math") { project?.editor.perform(.displayMath) }
        ForEach(mathTemplates, id: \.title) { template in
            Button(template.title) { project?.insert(template) }
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
