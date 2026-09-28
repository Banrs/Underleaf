import SwiftUI

/// The line's section level as a submenu, for the Format menu.
struct SectionLevelItems: View {
    let project: ProjectModel?

    var body: some View {
        Menu("Section Level") {
            ForEach(HeadingLevel.all, id: \.self) { level in
                Button(level.title) { project?.format(.heading, level.command) }
            }
        }
    }
}

/// The symbols as a submenu, for the Insert menu.
struct SymbolMenu: View {
    let project: ProjectModel?

    var body: some View {
        Menu("Symbols") { SymbolItems(project: project) }
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

/// Find and replace in the source; CodeMirror searches, its own panel hidden.
struct SourceFindBar: View {
    @Bindable var project: ProjectModel
    let field: FieldHandle
    @FocusState private var replaceFocused: Bool

    var body: some View {
        FindBar(query: $project.findQuery.search, prompt: "Find", field: field, options: options,
                matches: project.findMatches, searched: project.findQuery.search,
                step: { project.findStep($0) }, close: { project.closeFind() }) {
            if project.replaceShown {
                GridRow {
                    TextField("Replace", text: $project.findQuery.replace, prompt: Text("Replace"))
                        .labelsHidden()
                        // UI kit: a capsule, as the search field over it.
                        .textFieldStyle(.bordered)
                        .textInputBorderShape(.capsule)
                        .onSubmit { project.replace(all: false) }
                        .onExitCommand { project.closeFind() }
                        .focused($replaceFocused)
                        // Find and Replace…, whether or not the bar already shows.
                        .task(id: project.replaceFocus) {
                            if project.replaceFocus > 0 { replaceFocused = true }
                        }
                    HStack(spacing: BarMetrics.groupSpacing) {
                        Button("Replace") { project.replace(all: false) }
                        Button("Replace All") { project.replace(all: true) }
                    }
                    .fixedSize()
                    .disabled(project.findMatches.total == 0)
                    .gridColumnAlignment(.trailing)
                }
            }
        }
    }

    private var options: [SearchOption] {
        [
            SearchOption(title: "Match Case", isOn: $project.findQuery.caseSensitive),
            SearchOption(title: "Whole Words", isOn: $project.findQuery.wholeWord),
            SearchOption(title: "Regular Expression", isOn: $project.findQuery.regexp),
        ]
    }
}

/// The Insert menu's items; the section level is Format's, a style.
struct InsertMenuItems<InlineMath: View>: View {
    let project: ProjectModel?
    /// The menu bar's own Inline Math item, which carries its shortcut.
    let inlineMath: InlineMath

    var body: some View {
        inlineMath
        Button("Display Math") { project?.format(.displayMath) }
        SymbolMenu(project: project)
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
