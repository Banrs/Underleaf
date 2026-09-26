import SwiftUI

/// The source's tools, as items of the window toolbar over the source (see
/// `WorkspaceToolbar`): a LaTeX writer's tools, after Overleaf's toolbar.
/// Each group is one customizable item; the system gives each its glass,
/// sizes it and folds it into the toolbar's » menu when the window is
/// narrow. Every one is also in the menu bar (Edit and Format). Commenting
/// out is only in the Format menu (⌘/).
enum SourceTools {
    /// The templates with a button of their own, by title and symbol.
    static let references = [("Link", "link"), ("Reference", "number"), ("Citation", "text.quote")]
    static let figures = [("Figure", "photo"), ("Table", "tablecells")]
    static let lists = [("Bulleted List", "list.bullet"), ("Numbered List", "list.number")]
}

extension ProjectModel {
    /// The source tools act on LaTeX: they are off for other files.
    var editsLaTeX: Bool { openPath?.hasSuffix(".tex") == true }
}

/// A toolbar button for a menu command: its title, symbol and state.
private struct CommandButton: View {
    @Environment(AppModel.self) private var app
    let command: MenuCommand
    let systemImage: String

    init(_ command: MenuCommand, _ systemImage: String) {
        self.command = command
        self.systemImage = systemImage
    }

    var body: some View {
        Button(command.title, systemImage: systemImage) { app.perform(command) }
            .disabled(!app.isEnabled(command))
            .help(command.title)
    }
}

/// Undo and redo, one group.
struct UndoRedoTools: View {
    var body: some View {
        ControlGroup {
            CommandButton(.editUndo, "arrow.uturn.backward")
            CommandButton(.editRedo, "arrow.uturn.forward")
        } label: {
            Label("Undo and Redo", systemImage: "arrow.uturn.backward")
        }
    }
}

/// Bold, italic, inline and display math: one group, as Pages groups its
/// text styles. One item rather than two side by side: adjacent groups'
/// glass runs together into one shape.
struct FormatTools: View {
    let project: ProjectModel

    var body: some View {
        ControlGroup {
            CommandButton(.editBold, "bold")
            CommandButton(.editItalic, "italic")
            CommandButton(.editMath, "x.squareroot")
            Button("Display Math", systemImage: "sum") { project.format("displayMath") }
                .help("Display Math")
        } label: {
            Label("Format", systemImage: "bold.italic.underline")
        }
        .disabled(!project.editsLaTeX)
    }
}

/// The symbol palette, a popover from its own toolbar item.
struct SymbolsTool: View {
    let project: ProjectModel
    @State private var showing = false

    var body: some View {
        Button("Symbols", systemImage: "pi") { showing = true }
            .help("Symbols")
            .disabled(!project.editsLaTeX)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                SymbolPalette { project.format("symbol", $0) }
            }
    }
}

/// A group of templates with buttons of their own: links and references,
/// figures and tables, or lists.
struct TemplateTools: View {
    enum Kind { case references, figures, lists }
    let kind: Kind
    let project: ProjectModel

    var body: some View {
        ControlGroup {
            ForEach(items, id: \.0) { title, symbol in
                Button(title, systemImage: symbol) {
                    if kind == .references { project.inline(title) } else { project.insert(title) }
                }
                .help(title)
            }
        } label: {
            Label(label.0, systemImage: label.1)
        }
        .disabled(!project.editsLaTeX)
    }

    private var items: [(String, String)] {
        switch kind {
        case .references: SourceTools.references
        case .figures: SourceTools.figures
        case .lists: SourceTools.lists
        }
    }

    private var label: (String, String) {
        switch kind {
        case .references: ("References", "number")
        case .figures: ("Figure and Table", "photo")
        case .lists: ("Lists", "list.bullet")
        }
    }
}

/// Every block and reference the source can insert, as Pages' Insert
/// menu: whichever of the tools the toolbar shows, this has them all.
struct InsertTool: View {
    let project: ProjectModel

    var body: some View {
        Menu {
            ForEach(insertTemplates, id: \.0) { title, template in
                Button(title) { project.format("insert", template) }
            }
            Divider()
            ForEach(listTemplates, id: \.0) { title, template in
                Button(title) { project.format("insert", template) }
            }
            Divider()
            ForEach(referenceTemplates, id: \.0) { title, template in
                Button(title) { project.format("inline", template) }
            }
        } label: {
            Label("Insert", systemImage: "plus")
        }
        .help("Insert")
        .disabled(!project.editsLaTeX)
    }
}

/// The line's section level, as a word processor shows its paragraph
/// style; choosing one makes the line that heading, or plain text. The
/// system's pop-up, so it checks the level; its toolbar label doesn't reach
/// VoiceOver (it read the pop-up's symbol name), so it is named here.
/// A view of its own, so a caret move redraws it and not the whole toolbar.
struct SectionLevelMenu: View {
    let project: ProjectModel

    var body: some View {
        let level = project.outline.first { $0.line == project.cursorLine }?.level
        let current = level.map { headingLevels[$0 + 1].1 } ?? headingLevels[0].1
        Picker("Section Level", selection: Binding(
            get: { current },
            set: { project.format("heading", $0) }
        )) {
            ForEach(headingLevels, id: \.1) { title, command in
                Text(title).tag(command)
                if command.isEmpty { Divider() }
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Section Level")
        .help("Section Level")
        .disabled(!project.editsLaTeX)
    }
}

/// Symbols by kind, each inserted as its command: the palette LaTeX editors
/// keep beside the source (TeXstudio, TeXShop, Overleaf).
let symbolGroups: [(String, [(String, String)])] = [
    ("Greek", [("α", "\\alpha"), ("β", "\\beta"), ("γ", "\\gamma"), ("δ", "\\delta"), ("ε", "\\epsilon"),
               ("ζ", "\\zeta"), ("η", "\\eta"), ("θ", "\\theta"), ("κ", "\\kappa"), ("λ", "\\lambda"),
               ("μ", "\\mu"), ("ν", "\\nu"), ("ξ", "\\xi"), ("π", "\\pi"), ("ρ", "\\rho"), ("σ", "\\sigma"),
               ("τ", "\\tau"), ("φ", "\\phi"), ("χ", "\\chi"), ("ψ", "\\psi"), ("ω", "\\omega"),
               ("Γ", "\\Gamma"), ("Δ", "\\Delta"), ("Θ", "\\Theta"), ("Λ", "\\Lambda"), ("Π", "\\Pi"),
               ("Σ", "\\Sigma"), ("Φ", "\\Phi"), ("Ψ", "\\Psi"), ("Ω", "\\Omega")]),
    ("Operators", [("±", "\\pm"), ("×", "\\times"), ("÷", "\\div"), ("·", "\\cdot"), ("∑", "\\sum"),
                   ("∏", "\\prod"), ("∫", "\\int"), ("∮", "\\oint"), ("√", "\\sqrt{}"), ("∂", "\\partial"),
                   ("∇", "\\nabla"), ("∞", "\\infty"), ("∘", "\\circ"), ("⊗", "\\otimes"), ("⊕", "\\oplus")]),
    ("Relations", [("≤", "\\leq"), ("≥", "\\geq"), ("≠", "\\neq"), ("≈", "\\approx"), ("≡", "\\equiv"),
                   ("∼", "\\sim"), ("∝", "\\propto"), ("∈", "\\in"), ("∉", "\\notin"), ("⊂", "\\subset"),
                   ("⊆", "\\subseteq"), ("∪", "\\cup"), ("∩", "\\cap"), ("∅", "\\emptyset")]),
    ("Arrows and Logic", [("→", "\\rightarrow"), ("←", "\\leftarrow"), ("↔", "\\leftrightarrow"),
                          ("⇒", "\\Rightarrow"), ("⇐", "\\Leftarrow"), ("⇔", "\\Leftrightarrow"), ("↦", "\\mapsto"),
                          ("∀", "\\forall"), ("∃", "\\exists"), ("¬", "\\neg"), ("∧", "\\wedge"), ("∨", "\\vee")]),
]

/// The symbol palette: one grid, so the columns line up across the kinds;
/// each symbol a flat button named by its command. The popover draws its
/// own glass.
private struct SymbolPalette: View {
    let insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let columns = 10

    /// Each glyph a large (28 pt) accessory-bar button, the HIG's default
    /// control size, rather than a line of the glyphs' text high; the
    /// glyph in a column as wide as a line is high, so every glyph, narrow
    /// or wide, takes the same room. The button's own padding makes the
    /// hit area wider still.
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

/// The palette as a menu, for the Format menu.
struct SymbolMenu: View {
    let project: ProjectModel?

    var body: some View {
        Menu("Symbols") {
            ForEach(symbolGroups, id: \.0) { title, symbols in
                Menu(title) {
                    ForEach(symbols, id: \.1) { glyph, command in
                        Button("\(glyph)   \(command)") { project?.format("symbol", command) }
                    }
                }
            }
        }
    }
}

/// Where the cursor is, as Xcode's jump bar shows it: the project, its
/// folders, the file (a menu of its siblings) and the section (a menu of
/// the file's sections). Narrow panes drop the project and folders, then
/// the section.
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
        return HStack(spacing: BarMetrics.spacing) {
            if folders {
                crumb(project.id, "folder")
                ForEach(Array(parts.dropLast().enumerated()), id: \.offset) { _, folder in
                    chevron
                    crumb(folder, "folder")
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
        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
    }

    private func crumb(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
    }

    /// The file, a menu of the text files in its folder.
    private func fileMenu(_ path: String, _ siblings: [String], name: String) -> some View {
        Menu {
            ForEach(siblings, id: \.self) { file in
                Button((file as NSString).lastPathComponent) { Task { await project.open(file) } }
            }
        } label: {
            Label(name, systemImage: "doc.text").labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .help(path)
    }

    /// The text files in the open file's folder, walked once per update.
    private func siblings(of path: String) -> [String] {
        let folder = (path as NSString).deletingLastPathComponent
        return textFiles(project.tree).filter { ($0 as NSString).deletingLastPathComponent == folder }
    }

    private func textFiles(_ nodes: [TreeNode]) -> [String] {
        nodes.flatMap { node in
            node.isDirectory ? textFiles(node.children ?? []) : (isTextFile(node.path) ? [node.path] : [])
        }
    }
}

/// The section at the cursor, a menu of the file's sections. A view of its
/// own, so a caret move redraws it and not the whole row.
private struct SectionCrumb: View {
    let project: ProjectModel

    var body: some View {
        let chain = Outline.chain(project.outline, at: project.cursorLine)
        let depths = Outline.depths(project.outline)
        Menu {
            ForEach(project.outline) { item in
                Button(String(repeating: "    ", count: depths[item.id]) + Outline.displayTitle(item)) {
                    if let path = project.openPath { Task { await project.open(path, line: item.line) } }
                }
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
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .help("Go to a Section")
    }
}

/// Find and replace in the source, as Xcode's find bar has it; CodeMirror
/// does the searching, its own panel hidden. Text actions are push buttons.
/// Narrow panes fold it so the fields and Done are never clipped.
struct SourceFindBar: View {
    @Bindable var project: ProjectModel

    var body: some View {
        PaneBarRows {
            ViewThatFits(in: .horizontal) {
                // Replace All folds into Replace's menu, and the fields
                // narrow, before the count goes: the minimum window still
                // says "Not found".
                rows(count: true, replaceMenu: false)
                rows(count: true, replaceMenu: true)
                rows(count: true, replaceMenu: true, fieldWidth: BarMetrics.fieldMinWidth)
                rows(count: false, replaceMenu: true, fieldWidth: BarMetrics.fieldMinWidth)
                rows(count: false, replaceMenu: true, fieldWidth: 0)
            }
            .placingFields([0, 1]) { id in
                if id == 0 {
                    SearchField(text: $project.findQuery.search, prompt: "Find", focus: project.findFocus,
                                options: options, step: { project.findStep($0) }, close: { project.closeFind() })
                } else {
                    SearchField(text: $project.findQuery.replace, prompt: "Replace", searches: false,
                                submit: { project.replace(all: false) }, close: { project.closeFind() })
                }
            }
        }
    }

    /// The fields' slots share the one flexible column, so they take what
    /// the buttons leave and line up; the buttons' column keeps to the
    /// trailing edge, Done ending the first row. The fields themselves are
    /// drawn over the slots (`placingFields`), the same views in every layout.
    private func rows(count: Bool, replaceMenu: Bool, fieldWidth: CGFloat = BarMetrics.fieldWidth) -> some View {
        Grid(alignment: .leading, horizontalSpacing: BarMetrics.groupSpacing, verticalSpacing: BarMetrics.inset) {
            GridRow {
                FieldSlot(id: 0, minWidth: fieldWidth, idealWidth: fieldWidth)
                HStack(spacing: BarMetrics.groupSpacing) {
                    ToolGroup(items: [
                        Segment(id: "previous", title: "Previous Match", systemImage: "chevron.up",
                                enabled: project.findMatches.total > 0) { project.findStep(-1) },
                        Segment(id: "next", title: "Next Match", systemImage: "chevron.down",
                                enabled: project.findMatches.total > 0) { project.findStep(1) },
                    ])
                    if count {
                        Text(project.findMatches.label(for: project.findQuery.search))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("Done") { project.closeFind() }
                        .buttonStyle(.bordered)
                }
                .fixedSize()
                .gridColumnAlignment(.trailing)
            }
            GridRow {
                FieldSlot(id: 1, minWidth: fieldWidth, idealWidth: fieldWidth)
                Group {
                    if replaceMenu {
                        // Replace, with Replace All in its menu.
                        Menu("Replace") {
                            Button("Replace All") { project.replace(all: true) }
                        } primaryAction: {
                            project.replace(all: false)
                        }
                        .menuStyle(.button)
                    } else {
                        HStack(spacing: BarMetrics.spacing) {
                            Button("Replace") { project.replace(all: false) }
                            Button("Replace All") { project.replace(all: true) }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(project.findMatches.total == 0)
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

/// The section levels, as the line's style: plain text, then the
/// sectioning commands in the order the web's outline ranks them.
let headingLevels: [(String, String)] = [
    ("Normal Text", ""), ("Part", "part"), ("Chapter", "chapter"), ("Section", "section"),
    ("Subsection", "subsection"), ("Subsubsection", "subsubsection"), ("Paragraph", "paragraph"),
]

/// Cross-references, citations and links; each opens completion inside
/// its braces.
let referenceTemplates: [(String, String)] = [
    ("Reference", "\\ref{$0}"), ("Equation Reference", "\\eqref{$0}"), ("Citation", "\\cite{$0}"),
    ("Label", "\\label{$0}"), ("Link", "\\href{$0}{}"), ("URL", "\\url{$0}"),
]

/// The lists: web/src/sourcebar.js `LIST_TEMPLATES`.
let listTemplates: [(String, String)] = [
    ("Bulleted List", "\\begin{itemize}\n  \\item $0\n\\end{itemize}\n"),
    ("Numbered List", "\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n"),
    ("Description List", "\\begin{description}\n  \\item[$0] \n\\end{description}\n"),
]

extension ProjectModel {
    /// A block from `insertTemplates` or `listTemplates`, by its title.
    func insert(_ title: String) {
        if let template = (insertTemplates + listTemplates).first(where: { $0.0 == title })?.1 {
            format("insert", template)
        }
    }

    /// A template from `referenceTemplates` around the selection, by its title.
    func inline(_ title: String) {
        if let template = referenceTemplates.first(where: { $0.0 == title })?.1 { format("inline", template) }
    }
}
