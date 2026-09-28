import SwiftUI

/// The source's tools in the toolbar over it: Bold | Italic and Insert by default
/// (HIG, Toolbars: few, frequent, grouped by function); the rest are added with
/// Customize Toolbar.
struct SourceToolbar: CustomizableToolbarContent {
    let app: AppModel
    let project: ProjectModel

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "undo") {
            segments(enabled: editsText) {
                button(.editUndo, "arrow.uturn.backward")
                button(.editRedo, "arrow.uturn.forward")
            }
        }
        .defaultCustomization(.hidden)
        .visibilityPriority(.low)
        // Occasional, and in Format › Section Level: added with Customize Toolbar
        // (HIG, Toolbars: the default set holds the most frequent actions).
        ToolbarItem(id: "sectionLevel") {
            SectionLevelMenu(project: project)
                .disabled(!project.isLaTeX)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "format") {
            segments(enabled: project.isLaTeX) {
                button(.editBold, "bold")
                button(.editItalic, "italic")
            }
        }
        ToolbarItem(id: "math") {
            segments(enabled: project.isLaTeX) {
                button(.editMath, "x.squareroot")
                Menu { SymbolItems(project: project) } label: { Label("Symbols", systemImage: "sum") }
                    .help("Symbols")
            }
        }
        .defaultCustomization(.hidden)
        .visibilityPriority(.low)
        ToolbarItem(id: "references") {
            segments(enabled: project.isLaTeX) { templateButtons(referenceTemplates) }
        }
        .defaultCustomization(.hidden)
        .visibilityPriority(.low)
        ToolbarItem(id: "figures") {
            segments(enabled: project.isLaTeX) { templateButtons(insertTemplates) }
        }
        .defaultCustomization(.hidden)
        .visibilityPriority(.low)
        ToolbarItem(id: "lists") {
            segments(enabled: project.isLaTeX) { templateButtons(listTemplates) }
        }
        .defaultCustomization(.hidden)
        .visibilityPriority(.low)
        ToolbarItem(id: "insert") {
            Menu {
                InsertMenuItems(project: project,
                                inlineMath: Button(MenuCommand.editMath.title) { app.perform(.editMath, on: project) })
            } label: {
                Label("Insert", systemImage: "plus")
            }
            .help("Insert")
            .disabled(!project.isLaTeX)
        }
    }

    /// Undo | redo act on any text; the LaTeX tools on LaTeX only.
    private var editsText: Bool { project.openPath == nil || project.editsText }

    /// Disabled rather than removed where they don't apply: a customized toolbar keeps its items put.
    private func segments(enabled: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        ControlGroup { content() }
            // Unverified that .automatic draws these the same in the toolbar on 27.2.
            .controlGroupStyle(.navigation)
            .disabled(!enabled)
    }

    /// The shortcut shows in the menu, not the tooltip.
    private func button(_ command: MenuCommand, _ systemImage: String) -> some View {
        Button(command.title, systemImage: systemImage) { app.perform(command, on: project) }
            .disabled(!app.isEnabled(command, on: project))
            .help(command.title)
    }

    private func templateButtons(_ templates: [Template]) -> some View {
        ForEach(templates.filter { $0.symbol != nil }, id: \.title) { template in
            Button(template.title, systemImage: template.symbol ?? "") { project.insert(template) }
                .help(template.title)
        }
    }
}

/// The caret line's section level; choosing one makes the line that heading. A
/// pop-up sized to its widest item, so it keeps its width as the caret moves. Its
/// own view, so a caret move redraws it alone.
private struct SectionLevelMenu: View {
    let project: ProjectModel

    var body: some View {
        let current = project.outline.first { $0.line == project.cursorLine }
            .flatMap { HeadingLevel.atDepth($0.level) } ?? .normalText
        Picker("Section Level", selection: Binding(get: { current }, set: { project.format(.heading, $0.command) })) {
            ForEach(HeadingLevel.all, id: \.self) { level in
                Text(level.title).tag(level)
                if level == .normalText { Divider() }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Section Level")
    }
}

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
    @FocusState private var replaceFocused: Bool

    var body: some View {
        FindBar(query: $project.findQuery.search, prompt: "Find", focus: project.findFocus, options: options,
                matches: project.findMatches, searched: project.findQuery.search,
                step: { project.findStep($0) }, close: { project.closeFind() }) {
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
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Replace") { project.replace(all: false) }
                        Button("Replace All") { project.replace(all: true) }
                    }
                    .fixedSize()
                    // Narrow: Replace All in Replace's menu.
                    Menu("Replace") {
                        Button("Replace All") { project.replace(all: true) }
                    } primaryAction: {
                        project.replace(all: false)
                    }
                }
                .disabled(project.findMatches.total == 0)
                .gridColumnAlignment(.trailing)
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
