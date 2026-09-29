import SwiftUI

/// The section levels, the caret line's ticked; choosing one makes the line that
/// heading. The Format menu's and the toolbar's (`NSHostingMenu`).
struct SectionLevelItems: View {
    let project: ProjectModel?

    var body: some View {
        ForEach(HeadingLevel.all, id: \.self) { level in
            Toggle(level.title, isOn: Binding(get: { project?.headingLevel == level },
                                              set: { _ in project?.format(.heading, level.command) }))
            if level == .normalText { Divider() }
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
                    Button { project?.format(.symbol, command) } label: {
                        Text(glyph)
                        Text(command)
                    }
                }
            }
        }
    }
}

/// The Insert menu's items, the menu bar's and the toolbar's (`NSHostingMenu`); the
/// section level is Format's, a style.
struct InsertMenuItems<InlineMath: View>: View {
    let project: ProjectModel?
    /// Inline Math: the menu bar's own item carries its shortcut.
    let inlineMath: InlineMath

    var body: some View {
        inlineMath
        Button("Display Math") { project?.format(.displayMath) }
        items(mathTemplates)
        // A section, so a symbol is one submenu down (HIG, Menus); it brings its own separators.
        Section("Symbols") { SymbolItems(project: project) }
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
