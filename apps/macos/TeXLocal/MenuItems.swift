import SwiftUI

/// The section levels; choosing one makes the caret's line that heading. The
/// Format menu's and the toolbar's (`NSHostingMenu`).
struct SectionLevelItems: View {
    let project: ProjectModel?

    var body: some View {
        ForEach(HeadingLevel.all, id: \.self) { level in
            Button(level.title) { project?.format(.heading, level.command) }
        }
    }
}

/// The symbols by kind, each kind a submenu.
struct SymbolItems: View {
    let project: ProjectModel?

    var body: some View {
        Group {
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
        Menu("Symbols") { SymbolItems(project: project) }
        Menu("Reference") { items(referenceTemplates) }
        Divider()
        items(insertTemplates)
        Menu("List") { items(listTemplates) }
    }

    private func items(_ templates: [Template]) -> some View {
        ForEach(templates, id: \.title) { template in
            Button(template.title) { project?.insert(template) }
        }
    }
}
