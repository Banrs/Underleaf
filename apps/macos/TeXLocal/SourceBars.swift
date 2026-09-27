import SwiftUI

/// The bar over the source: a LaTeX writer's tools, as Overleaf's toolbar
/// has them, then the rest in a ⋯ menu. Narrow panes fold groups into that
/// menu from the end, then the section level and redo, so undo is never
/// clipped. Figures and lists are always there: the groups up to the
/// references are as many as the bar showed before its controls had fills,
/// and past them eight filled groups ran together (HIG, Toolbars: reduce
/// the use of toolbar backgrounds). Commenting out stays in the Format
/// menu (⌘/).
struct SourceBar: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @State private var showSymbols = false

    /// The groups that fold, in the order they fold back from.
    private enum Tools: Int, CaseIterable {
        case format, math, references, figures, lists

        /// How many the bar shows at its widest (`SourceBar`).
        static let shownAtMost = references.rawValue + 1

        /// The templates whose buttons the group holds: those with a symbol.
        var templates: [Template] {
            switch self {
            case .format, .math: []
            case .references: referenceTemplates
            case .figures: insertTemplates
            case .lists: listTemplates
            }
        }
    }

    var body: some View {
        PaneBar {
            ViewThatFits(in: .horizontal) {
                ForEach((0...Tools.shownAtMost).reversed(), id: \.self) { tools(showing: $0) }
                tools(showing: 0, level: false)
                tools(showing: 0, level: false, redo: false)
            }
            Spacer(minLength: 0)
        }
    }

    /// The bar with the first `count` groups; the section level and redo
    /// fold last, for a source pane at its narrowest.
    private func tools(showing count: Int, level: Bool = true, redo: Bool = true) -> some View {
        let shown = Tools.allCases.filter { $0.rawValue < count }
        // A group's room either side of each line, as every bar has it.
        return HStack(spacing: BarMetrics.groupSpacing) {
            ToolGroup(items: [Segment(.editUndo, "arrow.uturn.backward", app: app, project: project)]
                + (redo || !project.isLaTeX ? [Segment(.editRedo, "arrow.uturn.forward", app: app, project: project)] : []))
            if project.isLaTeX {
                if level {
                    BarSeparator()
                    SectionLevelMenu(project: project)
                }
                ForEach(shown, id: \.self) { group in
                    BarSeparator()
                    tools(group)
                }
                BarSeparator()
                moreMenu(folded: Tools.allCases.filter { $0.rawValue >= count }, level: !level, redo: !redo)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func tools(_ group: Tools) -> some View {
        switch group {
        case .format:
            ToolGroup(items: [Segment(.editBold, "bold", app: app, project: project), Segment(.editItalic, "italic", app: app, project: project)])
        case .math:
            HStack(spacing: 0) {
                ToolGroup(items: [
                    Segment(.editMath, "x.squareroot", app: app, project: project),
                    Segment(id: "displayMath", title: "Display Math", systemImage: "sum") {
                        project.format("displayMath")
                    },
                ])
                // Its own button, so the popover points at it.
                Button("Symbols", systemImage: "pi") { showSymbols = true }
                    .labelStyle(.iconOnly)
                    .help("Symbols")
                    .popover(isPresented: $showSymbols, arrowEdge: .bottom) {
                        SymbolPalette { project.format("symbol", $0) }
                    }
            }
            .fixedSize()
        case .references, .figures, .lists:
            ToolGroup(items: group.templates.compactMap { template in
                template.symbol.map { Segment(id: template.title, title: template.title, systemImage: $0) { project.insert(template) } }
            })
        }
    }

    /// The folded groups' tools, then what has no button of its own.
    private func moreMenu(folded: [Tools], level: Bool, redo: Bool) -> some View {
        Menu {
            if redo {
                Button(MenuCommand.editRedo.title) { app.perform(.editRedo, on: project) }
                    .disabled(!app.isEnabled(.editRedo, on: project))
                Divider()
            }
            if level {
                SectionLevelItems(project: project)
                Divider()
            }
            ForEach(folded, id: \.self) { group in
                switch group {
                case .format:
                    Button(MenuCommand.editBold.title) { app.perform(.editBold, on: project) }
                    Button(MenuCommand.editItalic.title) { app.perform(.editItalic, on: project) }
                case .math:
                    Button(MenuCommand.editMath.title) { app.perform(.editMath, on: project) }
                    Button("Display Math") { project.format("displayMath") }
                    SymbolMenu(project: project)
                case .references, .figures, .lists:
                    items(group.templates.filter { $0.symbol != nil })
                }
                Divider()
            }
            items((insertTemplates + listTemplates).filter { $0.symbol == nil })
            Divider()
            items(referenceTemplates.filter { $0.symbol == nil })
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("More")
    }

    private func items(_ templates: [Template]) -> some View {
        ForEach(templates, id: \.title) { template in
            Button(template.title) { project.insert(template) }
        }
    }
}

/// The line's section level, as a word processor shows its paragraph
/// style; choosing one makes the line that heading, or plain text. A menu
/// in the bar's accessory-bar style, flat until the pointer is over it as
/// its neighbours are (a pop-up button drew the one filled control in the
/// row), its level checked in the menu. A view of its own, so a caret move
/// redraws it and not the whole bar.
private struct SectionLevelMenu: View {
    let project: ProjectModel

    var body: some View {
        let level = project.outline.first { $0.line == project.cursorLine }?.level
        let current = level.map { headingLevels[$0 + 1] } ?? headingLevels[0]
        Menu {
            ForEach(headingLevels, id: \.1) { title, command in
                CheckedItem(title, checked: command == current.1) { project.format("heading", command) }
                if command.isEmpty { Divider() }
            }
        } label: {
            // The pop-up's ⇕, so it reads as a choice, not a label: the
            // accessory-bar style draws no indicator of its own.
            // One text, so the menu keeps the symbol after the words, where
            // a pop-up has it, an en space (half the font's size) off the
            // words: a plain space set it tighter than a pop-up does.
            let chevrons = Text(Image(systemName: "chevron.up.chevron.down")).font(.caption).foregroundStyle(.secondary)
            Text("\(current.0)\u{2002}\(chevrons)")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Section Level")
        .accessibilityLabel("Section Level")
        .accessibilityValue(current.0)
    }
}

/// The symbol palette: one grid, so the columns line up across the kinds;
/// each symbol a flat button named by its command. The popover draws its
/// own glass.
private struct SymbolPalette: View {
    let insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let columns = 10

    /// Each glyph a large accessory-bar button (the kit's large controls
    /// are 28 pt), rather than a line of the glyphs' text high; the glyph
    /// in a column as wide as a line is high, so every glyph, narrow or
    /// wide, takes the same room. The button's own padding makes the hit
    /// area wider still.
    private static var glyphWidth: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .title3)
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(symbolGroups.enumerated()), id: \.offset) { index, group in
                let (title, symbols) = group
                Text(title)
                    .font(Typography.secondary)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, index == 0 ? 0 : BarMetrics.inset)
                    .padding(.bottom, BarMetrics.spacing)
                    .gridCellColumns(Self.columns)
                ForEach(Array(stride(from: 0, to: symbols.count, by: Self.columns)), id: \.self) { start in
                    GridRow {
                        ForEach(symbols[start..<min(start + Self.columns, symbols.count)], id: \.1) { glyph, command in
                            Button {
                                insert(command)
                                dismiss()
                            } label: {
                                Text(glyph).font(.title3).frame(width: Self.glyphWidth)
                            }
                            .help(command)
                            .accessibilityLabel(command)
                        }
                    }
                }
            }
        }
        .buttonStyle(.accessoryBar)
        // Set here: macOS 27 resets the control size in popovers.
        .controlSize(.large)
        .padding()
    }
}

/// The line's section level as a submenu, for the Format menu and the
/// bar's overflow.
struct SectionLevelItems: View {
    let project: ProjectModel?

    var body: some View {
        Menu("Section Level") {
            ForEach(headingLevels, id: \.1) { title, command in
                Button(title) { project?.format("heading", command) }
            }
        }
    }
}

/// The palette as a menu, for the Insert menu and the bar's overflow.
struct SymbolMenu: View {
    let project: ProjectModel?

    var body: some View {
        Menu("Symbols") {
            ForEach(symbolGroups, id: \.0) { title, symbols in
                Menu(title) {
                    // The glyph over its command, the menu's own title and
                    // subtitle, rather than the two spaced apart in one title.
                    ForEach(symbols, id: \.1) { glyph, command in
                        Button { project?.format("symbol", command) } label: {
                            Text(glyph)
                            Text(command)
                        }
                    }
                }
            }
        }
    }
}

/// Where the cursor is, as Xcode's jump bar shows it, every crumb a menu:
/// the project and its folders (each a menu of what it holds), the file (a
/// menu of its siblings) and the section (a menu of the file's sections).
/// Narrow panes drop the project and folders, then the section.
struct SourceLocation: View {
    let project: ProjectModel

    var body: some View {
        SecondaryBar {
            if let path = project.openPath {
                let siblings = siblings(of: path)
                ViewThatFits(in: .horizontal) {
                    crumbs(path, siblings, folders: true, section: true)
                    crumbs(path, siblings, folders: false, section: true)
                    crumbs(path, siblings, folders: false, section: false)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func crumbs(_ path: String, _ siblings: [String], folders: Bool, section: Bool) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        // Crumb against chevron: the crumbs' own padding (their fill under
        // the pointer) parts them, as Xcode's jump bar sets its chevrons.
        return HStack(spacing: 0) {
            if folders {
                folderMenu(project.id, contents: project.tree)
                ForEach(Array(parts.dropLast().enumerated()), id: \.offset) { index, folder in
                    chevron
                    let path = parts[...index].joined(separator: "/")
                    folderMenu(folder, contents: project.tree.flattened.first { $0.path == path }?.children ?? [])
                }
                chevron
            }
            fileMenu(path, siblings, name: parts.last ?? path)
            if section, !project.outline.isEmpty {
                chevron
                SectionCrumb(project: project)
            }
        }
        .fixedSize()
    }

    private var chevron: some View {
        // Decoration: VoiceOver read each one as "Compact Forward Chevron".
        Image(systemName: "chevron.compact.forward").foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// The project or a folder, a menu of what it holds: its folders as
    /// submenus, its files to open, the open one checked.
    private func folderMenu(_ name: String, contents: [TreeNode]) -> some View {
        Menu {
            FolderMenuItems(nodes: contents, current: project.openPath) { path in Task { await project.open(path) } }
        } label: {
            Label(name, systemImage: "folder").labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .menuIndicator(.hidden)
        .help(name)
    }

    /// The file, a menu of the text files in its folder, itself checked.
    private func fileMenu(_ path: String, _ siblings: [String], name: String) -> some View {
        Menu {
            ForEach(siblings, id: \.self) { file in
                CheckedItem((file as NSString).lastPathComponent, checked: file == path) {
                    Task { await project.open(file) }
                }
            }
        } label: {
            Label(name, systemImage: fileSymbol(path)).labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        // A quiet fill under the pointer, as Xcode's jump bar has.
        .buttonStyle(.accessoryBar)
        .menuIndicator(.hidden)
        .help(path)
    }

    /// The text files in the open file's folder, walked once per update.
    private func siblings(of path: String) -> [String] {
        let folder = (path as NSString).deletingLastPathComponent
        return project.tree.flattened.filter { !$0.isDirectory && isTextFile($0.path) }.map(\.path)
            .filter { ($0 as NSString).deletingLastPathComponent == folder }
    }
}

/// The section at the cursor, a menu of the file's sections. A view of its
/// own, so a caret move redraws it and not the whole row.
private struct SectionCrumb: View {
    let project: ProjectModel

    var body: some View {
        let chain = Outline.chain(project.outline, at: project.cursorLine)
        Menu {
            SectionMenuItems(nodes: Outline.tree(project.outline), current: chain.last?.line) { item in
                if let path = project.openPath { Task { await project.open(path, line: item.line) } }
            }
        } label: {
            // On the label's text, not the menu: the pop-up takes its colour
            // from the text it is given. Only a real section reads as primary.
            Label {
                Text(chain.last.map(Outline.displayTitle) ?? "Top of File")
                    .foregroundStyle(chain.isEmpty ? .secondary : .primary)
            } icon: {
                Image(systemName: "list.bullet.indent")
            }
            .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .menuIndicator(.hidden)
        .help("Go to a Section")
    }
}

/// A folder's contents as a menu: each folder a submenu, each file an
/// item that opens it, the open file checked.
private struct FolderMenuItems: View {
    let nodes: [TreeNode]
    let current: String?
    let open: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                Menu {
                    FolderMenuItems(nodes: node.children ?? [], current: current, open: open)
                } label: {
                    Label(node.name, systemImage: "folder")
                }
            } else {
                CheckedItem(checked: node.path == current) { open(node.path) } label: {
                    Label(node.name, systemImage: fileSymbol(node.path))
                }
            }
        }
    }
}

/// The sections as the outline nests them: a heading with subsections is
/// a submenu, itself its first item, as a menu can't both open a submenu
/// and act. The section at the cursor is checked.
private struct SectionMenuItems: View {
    let nodes: [OutlineNode]
    /// The line of the section at the cursor.
    let current: Int?
    let go: (OutlineItem) -> Void

    var body: some View {
        ForEach(nodes) { node in
            let title = Outline.displayTitle(node.item)
            let item = CheckedItem(title, checked: node.item.line == current) { go(node.item) }
            if let children = node.children {
                Menu(title) {
                    item
                    Divider()
                    SectionMenuItems(nodes: children, current: current, go: go)
                }
            } else {
                item
            }
        }
    }
}

/// Find and replace in the source; CodeMirror does the searching, its own
/// panel hidden. In a narrow pane the fields narrow, the count goes and
/// Replace All folds into Replace's menu.
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
                    // A capsule, as the find field over it is (the kit's
                    // search fields).
                    .textFieldStyle(.bordered)
                    .textInputBorderShape(.capsule)
                    .onSubmit { project.replace(all: false) }
                    .onExitCommand { project.closeFind() }
                    .focused($replaceFocused)
                    // Find and Replace…, as the bar opens or while it shows.
                    .task(id: project.replaceFocus) {
                        if project.replaceFocus > 0 { replaceFocused = true }
                    }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BarMetrics.spacing) {
                        Button("Replace") { project.replace(all: false) }
                        Button("Replace All") { project.replace(all: true) }
                    }
                    .fixedSize()
                    // Replace, with Replace All in its menu.
                    Menu("Replace") {
                        Button("Replace All") { project.replace(all: true) }
                    } primaryAction: {
                        project.replace(all: false)
                    }
                }
                .buttonStyle(.bordered)
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

/// The Insert menu: what the source bar inserts, math and symbols, then
/// references, then blocks. The line's level is Format's, a style.
struct InsertMenuItems<InlineMath: View>: View {
    let project: ProjectModel?
    /// The menu bar's Inline Math item, with its shortcut.
    let inlineMath: InlineMath

    var body: some View {
        inlineMath
        Button("Display Math") { project?.format("displayMath") }
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

#Preview("Symbol palette") {
    SymbolPalette { _ in }
}
