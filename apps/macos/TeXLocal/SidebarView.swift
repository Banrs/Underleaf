import SwiftUI

/// The sidebar, as a writer's rather than a programmer's and as Overleaf
/// lays it out: the project's files over the open document's outline, with
/// a divider to drag between them, and project search at the top. They are
/// separate lists: the files keep the one selection (the open file); the
/// outline is a table of contents with no selection of its own, its current
/// section tinted. The outline folds to its header, docked at the foot of
/// the sidebar, and the files take the room.
struct NavigatorView: View {
    /// The outline folded to its header (its section's chevron, or View ›
    /// Hide File Outline).
    static let outlineCollapsedKey = "OutlineCollapsed"
    /// The folded outline's height: its header, the secondary rows'
    /// height, so the divider over it continues the status bar's hairline.
    static var outlineHeaderHeight: CGFloat { BarMetrics.secondaryBarHeight }
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @FocusState private var searchFocused: Bool
    @AppStorage(Self.outlineCollapsedKey) private var outlineCollapsed = false

    var body: some View {
        SplitController(app: app, axis: .vertical, autosave: "OutlineSplit", panes: [
            SplitPane(minimum: 100) { FilesList(project: project) },
            SplitPane(minimum: 80, fraction: 0.45, keepsSize: true, shown: showsOutline,
                      collapsed: outlineCollapsed ? Self.outlineHeaderHeight : nil) {
                OutlineList(project: project)
            },
        ])
        .searchable(text: $project.searchQuery, placement: .sidebar, prompt: "Search Project")
        .searchFocused($searchFocused)
        .onChange(of: app.searchFocusToken) { _, _ in searchFocused = true }
    }

    /// Search results take the whole sidebar.
    private var showsOutline: Bool {
        project.searchQuery.isEmpty && project.openPath?.hasSuffix(".tex") == true
    }
}

/// The project's files, with adding at the header as Overleaf has it, or
/// the project search's results while there is a query.
private struct FilesList: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var selection: String?
    @State private var hit: SearchHit.ID?
    @State private var deleting: String?
    /// The row whose name is being edited in place, and the name so far.
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var renameFocused: Bool
    /// The open folders, by path.
    @State private var expanded: Set<String> = []

    var body: some View {
        // Two lists rather than one whose sections change shape: the
        // sidebar's outline view, diffed from the tree to grouped hits and
        // back, kept stale rows.
        Group {
            if project.searchQuery.isEmpty { files } else { results }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await project.importFiles(urls) }
            return true
        }
        .confirmationDialog(
            "Move “\((deleting.map { ($0 as NSString).lastPathComponent }) ?? "")” to the Trash?",
            isPresented: Binding(presenting: $deleting),
            titleVisibility: .visible,
            presenting: deleting
        ) { path in
            // Not destructive-styled: moving to the Trash was chosen, and the
            // Trash gives it back (HIG, Alerts).
            Button("Move to Trash") { Task { await project.deleteEntry(path) } }
        } message: { _ in
            Text("You can restore it from the Trash.")
        }
    }

    private var files: some View {
        List(selection: $selection) {
            Section {
                rows(project.tree)
            } header: {
                Text("Files")
            }
        }
        .listStyle(.sidebar)
        // Adding, where Finder and Apple's lists keep it: the File menu, and
        // the list's own menu on its empty space.
        .contextMenu(forSelectionType: String.self) { paths in
            if paths.isEmpty {
                Button(MenuCommand.fileNew.title) { app.perform(.fileNew) }
                Button(MenuCommand.fileNewFolder.title) { app.perform(.fileNewFolder) }
                Divider()
                Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload) }
            }
        } primaryAction: { paths in
            // Double-click or Return on a folder opens or closes it, as
            // Xcode's navigator does; a file is open once it's chosen.
            guard let path = paths.first, isFolder(path, in: project.tree) else { return }
            if expanded.remove(path) == nil { expanded.insert(path) }
        }
        .onChange(of: selection) { _, path in
            if let path, path != project.openPath, isTextFile(path) { Task { await project.open(path, focus: false) } }
        }
        .onChange(of: project.openPath, initial: true) { _, path in selection = path }
        // ⌫, as Finder and the projects table take it.
        .onDeleteCommand { if let selection { deleting = selection } }
    }

    /// Choosing a hit opens it, as Xcode's find navigator does.
    private var results: some View {
        List(selection: $hit) { searchResults }
            .listStyle(.sidebar)
            .onChange(of: hit) { _, id in
                if let found = project.searchHits.first(where: { $0.id == id }) {
                    Task { await project.open(found.file, line: found.line) }
                }
            }
            .overlay {
                if project.searchHits.isEmpty { ContentUnavailableView.search(text: project.searchQuery) }
            }
    }

    /// Hits grouped by file, each line with its match picked out.
    @ViewBuilder
    private var searchResults: some View {
        let groups = Dictionary(grouping: project.searchHits, by: \.file).sorted { $0.key < $1.key }
        ForEach(groups, id: \.key) { file, hits in
            Section("\(file) — \(hits.count)") {
                ForEach(hits) { hit in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)")
                            .lineLimit(2)
                        Spacer(minLength: BarMetrics.spacing)
                        Text("\(hit.line)")
                            .font(Typography.secondary)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The tree as the sidebar shows one: native disclosure triangles on
    /// the folders, each open or closed as `expanded` has it.
    private func rows(_ nodes: [TreeNode]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(node.path) },
                    set: { open in
                        if open { expanded.insert(node.path) } else { expanded.remove(node.path) }
                    }
                )) {
                    rows(children)
                } label: {
                    row(node).tag(node.path)
                }
            } else {
                row(node).tag(node.path)
            }
        })
    }

    private func isFolder(_ path: String, in nodes: [TreeNode]) -> Bool {
        nodes.contains { $0.path == path ? $0.isDirectory : isFolder(path, in: $0.children ?? []) }
    }

    private func row(_ node: TreeNode) -> some View {
        let isMain = node.path == project.settings?.mainFile
        return Label {
            HStack {
                if renaming == node.path {
                    nameField(node)
                } else {
                    Text(node.name)
                }
                if isMain {
                    Spacer()
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .imageScale(.small)
                        .help("Main File")
                        .accessibilityLabel("Main File")
                }
            }
        } icon: {
            Image(systemName: icon(for: node))
        }
        // The star's name too: the row's label replaces its children's.
        .accessibilityLabel(isMain ? "\(node.name), Main File" : node.name)
        .contextMenu {
            if !node.isDirectory && node.path.hasSuffix(".tex") {
                Button("Set as Main File") { Task { await project.setMainFile(node.path) } }
                Divider()
            }
            // Edited in place, as Finder renames: no dialog, so no ellipsis.
            Button("Rename") {
                newName = node.name
                renaming = node.path
            }
            Button("Show in Finder") { project.showInFinder(node.path) }
            Divider()
            Button("Move to Trash") { deleting = node.path }
        }
    }

    /// The row's name, edited in place: Return or clicking away renames,
    /// Escape leaves it as it was.
    private func nameField(_ node: TreeNode) -> some View {
        TextField("Name", text: $newName)
            .labelsHidden()
            .focused($renameFocused)
            .onSubmit { commitRename(node) }
            .onExitCommand { renaming = nil }
            .onChange(of: renameFocused) { was, focused in
                if was, !focused { commitRename(node) }
            }
            // Once the context menu has closed and handed the list its
            // focus back, or the list takes it straight from the field.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                renameFocused = true
            }
    }

    private func commitRename(_ node: TreeNode) {
        guard renaming == node.path else { return }
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != node.name, !name.contains("/") else { return }
        let folder = (node.path as NSString).deletingLastPathComponent
        Task { await project.renameEntry(node.path, to: folder.isEmpty ? name : "\(folder)/\(name)") }
    }

    /// The file kind's symbol, as every list of the project's files shows it.
    private func icon(for node: TreeNode) -> String {
        if node.isDirectory { return "folder" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "tex": return "doc.text"
        case "bib": return "books.vertical"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

/// The open document's sections, as Overleaf's file outline, in a list of
/// their own under the files: one sidebar section, "File Outline", whose
/// header's chevron folds the whole outline away, leaving only the header
/// docked at the foot of the sidebar while the files take the room, and
/// opens it again at the height it had.
///
/// The headings nest with native disclosure triangles, in the sidebar's
/// Small rows (a size under the files'). They take no part in any
/// selection, so no row draws a selection capsule; the current section is
/// in the accent colour and semibold instead, its sections opened and kept
/// in view, as Overleaf's outline highlights where you are: the caret's
/// section, or the one at the top of the source once it scrolls, whichever
/// moved last. Choosing a heading scrolls it to the top of the source and
/// leaves focus where it was.
///
/// Only this view reads the top line, so scrolling the source re-renders
/// the outline, not the files, and only the headings whose state changed
/// (`HeadingRow` is equatable).
///
/// Folding slides the pane down to its header and unfolding slides it back
/// up, the rows riding with it as a drawer's contents do: the section
/// empties once the slide is over and fills before it starts, rather than
/// its rows collapsing up into the header while the pane moves down.
private struct OutlineList: View {
    /// Folded headings, by file and `Outline.foldKeys`.
    private static let foldedKey = "OutlineFolded"
    let project: ProjectModel
    @AppStorage(NavigatorView.outlineCollapsedKey) private var collapsed = false
    /// The section's rows showing: `collapsed`, a slide later when folding.
    @State private var expanded = !(UserDefaults.standard.object(forKey: NavigatorView.outlineCollapsedKey) as? Bool ?? false)
    @State private var folded = Set(UserDefaults.standard.stringArray(forKey: Self.foldedKey) ?? [])
    /// The line the highlight follows: the caret's or the top line,
    /// whichever changed last.
    @State private var line = 1

    var body: some View {
        let outline = project.outline
        let current = Outline.chain(outline, at: line).last?.id
        let prefix = "\(project.id)/\(project.openPath ?? "")\t"
        let keys = Outline.foldKeys(outline).map { prefix + $0 }
        ScrollViewReader { proxy in
            List {
                Section("File Outline", isExpanded: Binding(get: { expanded }, set: { collapsed = !$0 })) {
                    if outline.isEmpty {
                        Text("No Sections").foregroundStyle(.secondary)
                    } else {
                        OutlineRows(nodes: Outline.tree(outline), context: OutlineRows.Context(
                            project: project, current: current, keys: keys), folded: $folded)
                    }
                }
            }
            .listStyle(.sidebar)
            // A table of contents under a list of files: the sidebar's
            // compact rows, a size under the files'.
            .environment(\.sidebarRowSize, .small)
            // Centres the header in the docked bar when folded.
            .padding(.top, BarMetrics.spacing)
            .onChange(of: collapsed) { _, collapsed in
                if collapsed {
                    Task {
                        try? await Task.sleep(for: .seconds(0.25))
                        if self.collapsed { withTransaction(Transaction(animation: nil)) { expanded = false } }
                    }
                } else {
                    withTransaction(Transaction(animation: nil)) { expanded = true }
                }
            }
            .onChange(of: project.cursorLine, initial: true) { _, cursor in line = cursor }
            .onChange(of: project.topLine) { _, top in line = top }            // The current heading always shows: its sections open, then the
            // least scroll that brings it into view.
            .onChange(of: current, initial: true) { _, id in
                let chain = Outline.chain(outline, at: line).dropLast()
                let opened = folded.subtracting(chain.map { keys[$0.id] })
                if opened != folded { folded = opened }
                guard let id else { return }
                Task { proxy.scrollTo(id) }
            }
            .onChange(of: folded) { _, folded in
                UserDefaults.standard.set(Array(folded).sorted(), forKey: Self.foldedKey)
            }
        }
    }
}

/// The headings as the sidebar shows a hierarchy: native disclosure
/// triangles on the headings with headings under them, each fold
/// remembered (by `Outline.foldKeys`, so it survives renumbering).
private struct OutlineRows: View {
    struct Context {
        let project: ProjectModel
        let current: Int?
        let keys: [String]
    }

    let nodes: [OutlineNode]
    let context: Context
    @Binding var folded: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: expansion(node.item)) {
                    AnyView(OutlineRows(nodes: children, context: context, folded: $folded))
                } label: {
                    row(node.item)
                }
            } else {
                row(node.item)
            }
        }
    }

    private func row(_ item: OutlineItem) -> some View {
        HeadingRow(project: context.project, item: item, isCurrent: item.id == context.current)
            .equatable()
            .id(item.id)
    }

    private func expansion(_ item: OutlineItem) -> Binding<Bool> {
        let key = context.keys[item.id]
        return Binding(
            get: { !folded.contains(key) },
            set: { open in
                if open { folded.remove(key) } else { folded.insert(key) }
            }
        )
    }
}

/// A heading: not a list selection, so it draws no selection capsule; the
/// current one is in the accent colour and semibold. Choosing one scrolls
/// it to the top of the source and leaves focus where it was. The list
/// indents each level and draws the disclosure triangles, so the outermost
/// headings' triangles line up with the files' and their titles start
/// where the file icons do.
private struct HeadingRow: View, Equatable {
    let project: ProjectModel
    let item: OutlineItem
    let isCurrent: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.project === b.project && a.item == b.item && a.isCurrent == b.isCurrent
    }

    var body: some View {
        let title = Outline.displayTitle(item)
        Button {
            guard let path = project.openPath else { return }
            Task { await project.open(path, line: item.line, atTop: true, focus: false) }
        } label: {
            // The whole title as a tooltip only where it's cut short.
            ViewThatFits(in: .horizontal) {
                Text(title).fixedSize()
                Text(title).help(title)
            }
            .lineLimit(1)
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint)
                             : item.isUntitled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        // Its kind ("Subsection"); the list tells its depth.
        .accessibilityValue(headingLevels.indices.contains(item.level + 1) ? headingLevels[item.level + 1].0 : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
