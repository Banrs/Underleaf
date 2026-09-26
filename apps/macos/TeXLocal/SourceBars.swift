import SwiftUI

/// The bar over the source: a LaTeX writer's tools, as Overleaf's editor
/// toolbar has them, at the leading edge as Xcode places its editor's
/// controls: history; the section level of the line; bold and italic; math
/// and symbols; links, references and citations; figures and tables; lists;
/// then the rest in a menu. Narrow panes fold groups into that menu from the
/// end, as a toolbar overflows, then the section level and redo, so undo is
/// never clipped. Commenting out is a code editor's tool; it stays in
/// the Format menu (⌘/).
struct SourceBar: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @State private var showSymbols = false

    /// The groups that fold, in the order they fold back from.
    private enum Tools: Int, CaseIterable { case format, math, references, figures, lists }

    /// The templates with a button of their own, by title and symbol.
    private static let references = [("Link", "link"), ("Reference", "number"), ("Citation", "text.quote")]
    private static let figures = [("Figure", "photo"), ("Table", "tablecells")]
    private static let lists = [("Bulleted List", "list.bullet"), ("Numbered List", "list.number")]

    var body: some View {
        PaneBar {
            ViewThatFits(in: .horizontal) {
                tools(showing: 5)
                tools(showing: 4)
                tools(showing: 3)
                tools(showing: 2)
                tools(showing: 1)
                tools(showing: 0)
                tools(showing: 0, level: false)
                tools(showing: 0, level: false, redo: false)
            }
            Spacer(minLength: 0)
        }
    }

    /// The bar with the first `count` groups; the section level and redo
    /// fold last, for a source pane at its narrowest (at the large size,
    /// its buttons are 51 pt wide).
    private func tools(showing count: Int, level: Bool = true, redo: Bool = true) -> some View {
        let shown = Tools.allCases.filter { $0.rawValue < count }
        return HStack(spacing: BarMetrics.spacing) {
            ToolGroup(items: [Segment(.editUndo, "arrow.uturn.backward", app: app)]
                + (redo || !isLaTeX ? [Segment(.editRedo, "arrow.uturn.forward", app: app)] : []))
            if isLaTeX {
                if level {
                    ToolSeparator()
                    SectionLevelMenu(project: project)
                }
                ForEach(shown, id: \.self) { group in
                    ToolSeparator()
                    tools(group)
                }
                ToolSeparator()
                moreMenu(folded: Tools.allCases.filter { $0.rawValue >= count }, level: !level, redo: !redo)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func tools(_ group: Tools) -> some View {
        switch group {
        case .format:
            ToolGroup(items: [Segment(.editBold, "bold", app: app), Segment(.editItalic, "italic", app: app)])
        case .math:
            HStack(spacing: 0) {
                ToolGroup(items: [
                    Segment(.editMath, "x.squareroot", app: app),
                    Segment(id: "displayMath", title: "Display Math", systemImage: "sum") {
                        project.format("displayMath")
                    },
                ])
                // Its own button, so the popover points at it.
                Button("Symbols", systemImage: "pi") { showSymbols = true }
                    .labelStyle(.iconOnly)
                    .help("Symbols")
                    .popover(isPresented: $showSymbols, arrowEdge: .bottom) {
                        SymbolPalette { project.format("text", $0) }
                    }
            }
            .fixedSize()
        case .references:
            ToolGroup(items: Self.references.map { title, symbol in
                Segment(id: title, title: title, systemImage: symbol) { project.inline(title) }
            })
        case .figures, .lists:
            ToolGroup(items: (group == .figures ? Self.figures : Self.lists).map { title, symbol in
                Segment(id: title, title: title, systemImage: symbol) { project.insert(title) }
            })
        }
    }

    /// The folded groups' tools, then what has no button of its own.
    private func moreMenu(folded: [Tools], level: Bool, redo: Bool) -> some View {
        Menu {
            if redo {
                Button(MenuCommand.editRedo.title) { app.perform(.editRedo) }
                    .disabled(!app.isEnabled(.editRedo))
                Divider()
            }
            if level {
                Menu("Section Level") {
                    ForEach(headingLevels, id: \.1) { title, command in
                        Button(title) { project.format("heading", command) }
                    }
                }
                Divider()
            }
            ForEach(folded, id: \.self) { group in
                switch group {
                case .format:
                    Button(MenuCommand.editBold.title) { app.perform(.editBold) }
                    Button(MenuCommand.editItalic.title) { app.perform(.editItalic) }
                case .math:
                    Button(MenuCommand.editMath.title) { app.perform(.editMath) }
                    Button("Display Math") { project.format("displayMath") }
                    SymbolMenu(project: project)
                case .references:
                    ForEach(Self.references, id: \.0) { title, _ in
                        Button(title) { project.inline(title) }
                    }
                case .figures, .lists:
                    ForEach(group == .figures ? Self.figures : Self.lists, id: \.0) { title, _ in
                        Button(title) { project.insert(title) }
                    }
                }
                Divider()
            }
            ForEach(insertTemplates.filter { title, _ in !Self.figures.contains { $0.0 == title } }, id: \.0) { title, template in
                Button(title) { project.format("insert", template) }
            }
            ForEach(listTemplates.filter { title, _ in !Self.lists.contains { $0.0 == title } }, id: \.0) { title, template in
                Button(title) { project.format("insert", template) }
            }
            Divider()
            ForEach(referenceTemplates.filter { title, _ in !Self.references.contains { $0.0 == title } }, id: \.0) { title, template in
                Button(title) { project.format("inline", template) }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("More")
    }

    private var isLaTeX: Bool { project.openPath?.hasSuffix(".tex") == true }
}

/// The line's section level, as a word processor shows its paragraph
/// style; choosing one makes the line that heading, or plain text. The
/// system's pop-up: it shows the level, checks it in its menu and names
/// itself to VoiceOver. A view of its own, so a caret move redraws it and
/// not the whole bar.
private struct SectionLevelMenu: View {
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
        .labelsHidden()
        .fixedSize()
        .help("Section Level")
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

/// The symbol palette: one grid, so the columns line up across the kinds,
/// each kind under its name; each symbol a flat button named by its command
/// that highlights on hover, as the pane bars' do. The popover draws its
/// own glass.
private struct SymbolPalette: View {
    let insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let columns = 10

    /// A square cell a line of the glyphs' text style high, so every glyph,
    /// narrow or wide, takes the same room.
    private static var cell: CGFloat {
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
                                Text(glyph).font(.title3).frame(width: Self.cell, height: Self.cell)
                            }
                            .help(command)
                            .accessibilityLabel(command)
                        }
                    }
                }
            }
        }
        .buttonStyle(.accessoryBar)
        .padding()
    }
}

/// The palette as a menu, for the Format menu and the bar's overflow.
struct SymbolMenu: View {
    let project: ProjectModel?

    var body: some View {
        Menu("Symbols") {
            ForEach(symbolGroups, id: \.0) { title, symbols in
                Menu(title) {
                    ForEach(symbols, id: \.1) { glyph, command in
                        Button("\(glyph)   \(command)") { project?.format("text", command) }
                    }
                }
            }
        }
    }
}

/// Where the cursor is, as Xcode's jump bar shows it: the project, its
/// folders, the file — a menu of the files beside it — and the section
/// around the cursor, a menu of the file's sections. Narrow panes drop the
/// project and folders first, then the section.
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

/// Find and replace in the source, as TextEdit's and Xcode's find bars
/// have it: the system search field, its options in the field's own menu,
/// previous and next, the match count and Done; under it the replacement
/// and its actions. Text actions are push buttons, apart from the icon
/// buttons. Narrow panes drop the count, then put Replace All in Replace's
/// menu, then narrow the fields, so the fields and Done are never clipped. CodeMirror does the
/// searching; its own panel stays hidden. Return steps to the next match
/// (Shift-Return the previous) and Escape closes the bar, as in the PDF's.
struct SourceFindBar: View {
    @Bindable var project: ProjectModel

    var body: some View {
        PaneBarRows {
            ViewThatFits(in: .horizontal) {
                // Replace All folds into Replace's menu before the count
                // goes, so a narrow bar still says how many matches there
                // are (or that there are none), as Xcode's does.
                rows(count: true, replaceMenu: false)
                rows(count: true, replaceMenu: true)
                rows(count: true, replaceMenu: true, fieldWidth: BarMetrics.fieldMinWidth)
                rows(count: false, replaceMenu: true, fieldWidth: BarMetrics.fieldMinWidth)
                rows(count: false, replaceMenu: true, fieldWidth: 0)
            }
        }
    }

    /// The fields share the one flexible column, so they take what the
    /// buttons leave and line up; the buttons' column keeps to the trailing
    /// edge, Done ending the first row.
    private func rows(count: Bool, replaceMenu: Bool, fieldWidth: CGFloat = BarMetrics.fieldWidth) -> some View {
        Grid(alignment: .leading, horizontalSpacing: BarMetrics.groupSpacing, verticalSpacing: BarMetrics.inset) {
            GridRow {
                SearchField(text: $project.findQuery.search, prompt: "Find", focus: project.findFocus,
                            options: options, step: { project.findStep($0) }, close: { project.closeFind() })
                    .frame(minWidth: fieldWidth, idealWidth: fieldWidth, maxWidth: .infinity)
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
                SearchField(text: $project.findQuery.replace, prompt: "Replace", searches: false,
                            submit: { project.replace(all: false) }, close: { project.closeFind() })
                    .frame(minWidth: fieldWidth, idealWidth: fieldWidth, maxWidth: .infinity)
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

    /// How to match, each checked in the search field's menu, as Xcode's
    /// find options are.
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
