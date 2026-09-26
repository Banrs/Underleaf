import SwiftUI

/// The bar over the source: a LaTeX writer's tools, as Overleaf's editor
/// toolbar has them, at the leading edge as Xcode places its editor's
/// controls: history; the section level of the line; bold and italic; math
/// and symbols; links, references and citations; figures and tables; lists;
/// then the rest in a menu. Narrow panes fold groups into that menu from the
/// end, as a toolbar overflows. Commenting out is a code editor's tool; it
/// stays in the Format menu (⌘/).
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
            }
            Spacer(minLength: 0)
        }
    }

    private func tools(showing count: Int) -> some View {
        let shown = Tools.allCases.filter { $0.rawValue < count }
        return HStack(spacing: 4) {
            ToolGroup(items: [
                Segment(.editUndo, "arrow.uturn.backward", app: app),
                Segment(.editRedo, "arrow.uturn.forward", app: app),
            ])
            if isLaTeX {
                ToolSeparator()
                SectionLevelMenu(project: project)
                ForEach(shown, id: \.self) { group in
                    ToolSeparator()
                    tools(group)
                }
                ToolSeparator()
                moreMenu(folded: Tools.allCases.filter { $0.rawValue >= count })
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
            ToolGroup(items: [
                Segment(.editMath, "x.squareroot", app: app),
                Segment(id: "displayMath", title: "Display Math", systemImage: "sum") {
                    project.format("displayMath")
                },
                Segment(id: "symbols", title: "Symbols", systemImage: "pi") { showSymbols = true },
            ])
            .popover(isPresented: $showSymbols, arrowEdge: .bottom) {
                SymbolPalette { project.format("text", $0) }
            }
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
    private func moreMenu(folded: [Tools]) -> some View {
        Menu {
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
/// style; choosing one makes the line that heading, or plain text. A view of
/// its own, so a caret move redraws it and not the whole bar.
private struct SectionLevelMenu: View {
    let project: ProjectModel

    var body: some View {
        let level = project.outline.first { $0.line == project.cursorLine }?.level
        let current = level.map { headingLevels[$0 + 1].0 } ?? headingLevels[0].0
        // As wide as the widest level, so the bar doesn't shift as the cursor
        // moves between lines: the pop-up takes its label's text alone, so
        // the room is kept by a hidden twin.
        ZStack(alignment: .leading) {
            popUp("Subsubsection").hidden()
            popUp(current)
                .help("Section Level")
                .accessibilityLabel("Section Level")
                .accessibilityValue(current)
        }
    }

    private func popUp(_ title: String) -> some View {
        Menu {
            ForEach(headingLevels, id: \.1) { title, command in
                Button(title) { project.format("heading", command) }
                if command.isEmpty { Divider() }
            }
        } label: {
            Text("\(title) \(Text.popUpChevron)")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
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

/// The symbol palette: a grid per kind, each symbol a plain button named by
/// its command. The popover draws its own glass.
private struct SymbolPalette: View {
    let insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(symbolGroups, id: \.0) { title, symbols in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 10), spacing: 2) {
                        ForEach(symbols, id: \.1) { glyph, command in
                            Button {
                                insert(command)
                                dismiss()
                            } label: {
                                Text(glyph).font(.title3).frame(width: 28, height: 28).contentShape(.rect)
                            }
                            // Borderless: the accessory-bar bezel pads a 28 pt
                            // glyph to 52 × 36, past its fixed grid cell.
                            .buttonStyle(.borderless)
                            .help(command)
                            .accessibilityLabel(command)
                        }
                    }
                }
            }
        }
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
        LocationBar {
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
        return HStack(spacing: 4) {
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
            Label(chain.last.map(Outline.displayTitle) ?? "Top of File", systemImage: "list.bullet.indent")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .foregroundStyle(chain.isEmpty ? .secondary : .primary)
        .help("Go to a Section")
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

/// The lists; with `insertTemplates`, web/src/workspace.js `INSERT_TEMPLATES`
/// plus the description list.
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
