import SwiftUI

/// The sidebar, as a writer's rather than a programmer's and as Overleaf
/// lays it out: the project's files over the open document's outline, with
/// a divider to drag between them, and project search at the top. They are
/// separate lists: the files keep the one selection (the open file); the
/// outline is a table of contents with no selection of its own, its current
/// section tinted. The outline folds to its header, docked at the foot of
/// the sidebar, and the files take the room.
struct NavigatorView: View {
    /// The outline folded to its header (the sidebar's section chevron, or
    /// View › Hide File Outline).
    static let outlineCollapsedKey = "OutlineCollapsed"
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @FocusState private var searchFocused: Bool
    @AppStorage(Self.outlineCollapsedKey) private var outlineCollapsed = false

    var body: some View {
        SplitController(app: app, axis: .vertical, autosave: "OutlineSplit", panes: [
            SplitPane(minimum: 100) { FilesList(project: project) },
            SplitPane(minimum: 80, fraction: 0.45, keepsSize: true, shown: showsOutline,
                      collapsed: outlineCollapsed ? OutlineHeader.height : nil) {
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
    @State private var deleting: String?
    /// The row whose name is being edited in place, and the name so far.
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var renameFocused: Bool

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
                OutlineGroup(project.tree, children: \.children) { node in
                    row(node).tag(node.path)
                }
            } header: {
                filesHeader
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, path in
            if let path, path != project.openPath, isTextFile(path) { Task { await project.open(path, focus: false) } }
        }
        .onChange(of: project.openPath, initial: true) { _, path in selection = path }
        // ⌫, as Finder and the projects table take it.
        .onDeleteCommand { if let selection { deleting = selection } }
    }

    private var results: some View {
        List { searchResults }
            .listStyle(.sidebar)
            .overlay {
                if project.searchHits.isEmpty { ContentUnavailableView.search(text: project.searchQuery) }
            }
    }

    /// Adding, at the header, as Overleaf has it.
    private var filesHeader: some View {
        HStack {
            Text("Files")
            Spacer()
            Menu("Add", systemImage: "plus") {
                Button(MenuCommand.fileNew.title) { app.perform(.fileNew) }
                Button(MenuCommand.fileNewFolder.title) { app.perform(.fileNewFolder) }
                Divider()
                Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload) }
            }
            // A sidebar header's accessory: a plain small glyph, not a pane
            // bar's button.
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Add Files")
        }
    }

    /// Hits grouped by file, each line with its match picked out.
    @ViewBuilder
    private var searchResults: some View {
        let groups = Dictionary(grouping: project.searchHits, by: \.file).sorted { $0.key < $1.key }
        ForEach(groups, id: \.key) { file, hits in
            Section("\(file) — \(hits.count)") {
                ForEach(hits) { hit in
                    Button {
                        Task { await project.open(hit.file, line: hit.line) }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(hit.before)\(Text(hit.match).bold().foregroundStyle(.tint))\(hit.after)")
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Text("\(hit.line)")
                                .font(Typography.secondary)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
/// their own under the files, under a pinned "File Outline" header
/// (`OutlineHeader`) whose chevron folds the whole outline away, leaving
/// only the header docked at the foot of the sidebar while the files take
/// the room, and opens it again at the height it had.
///
/// The headings nest with native disclosure triangles, in the sidebar's
/// Small rows (a size under the files'). They take no part in any
/// selection, so no row draws a selection capsule; the current section,
/// the one at the top of the source (`ProjectModel.topLine`, not the
/// caret), is in the accent colour and semibold instead, its sections
/// opened and kept in view as the source scrolls. Choosing a heading
/// scrolls it to the top of the source and leaves focus where it was.
///
/// Only this view reads the top line, so scrolling the source re-renders
/// the outline, not the files, and only the headings whose state changed
/// (`HeadingRow` is equatable).
private struct OutlineList: View {
    /// Folded headings, by file and `Outline.foldKeys`.
    private static let foldedKey = "OutlineFolded"
    let project: ProjectModel
    @AppStorage(NavigatorView.outlineCollapsedKey) private var collapsed = false
    @State private var folded = Set(UserDefaults.standard.stringArray(forKey: Self.foldedKey) ?? [])

    var body: some View {
        let outline = project.outline
        let current = Outline.chain(outline, at: project.topLine).last?.id
        let prefix = "\(project.id)/\(project.openPath ?? "")\t"
        let keys = Outline.foldKeys(outline).map { prefix + $0 }
        VStack(spacing: 0) {
            OutlineHeader(collapsed: $collapsed)
            if !collapsed {
                list(outline: outline, current: current, keys: keys)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func list(outline: [OutlineItem], current: Int?, keys: [String]) -> some View {
        ScrollViewReader { proxy in
            List {
                if outline.isEmpty {
                    Text("No Sections").foregroundStyle(.secondary)
                } else {
                    OutlineRows(nodes: Outline.tree(outline), context: OutlineRows.Context(
                        project: project, current: current, keys: keys), folded: $folded)
                }
            }
            .listStyle(.sidebar)
            // A table of contents under a list of files: the sidebar's
            // compact rows, a size under the files'.
            .environment(\.sidebarRowSize, .small)
            // The current heading always shows: its sections open, then the
            // least scroll that brings it into view.
            .onChange(of: current, initial: true) { _, id in
                let chain = Outline.chain(outline, at: project.topLine).dropLast()
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

/// The outline's header, pinned over its headings (they scroll under it,
/// it never scrolls away): the title in the kit's sidebar-header style
/// (Bold 11 in the tertiary label colour) and, trailing, a borderless
/// chevron button that folds and opens the outline, always visible.
/// Clicking the title folds too. The chevron is the sidebar's disclosure
/// vocabulary, as on the headings and folders under and over it: down
/// while open, right while folded (a state, not a direction, so it reads
/// the same docked at the foot of the sidebar). The button takes keyboard
/// focus as every button does (with Keyboard Navigation on), Space toggles
/// it, and VoiceOver reads "File Outline" with its state. 28 pt, the status
/// bar's height: folded to it, the pane's divider continues the status
/// bar's top hairline in one line across the window.
private struct OutlineHeader: View {
    static let height = BarMetrics.secondaryBarHeight
    @Binding var collapsed: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text("File Outline")
                .font(.subheadline.bold())
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Spacer(minLength: BarMetrics.spacing)
            Button(collapsed ? "Show File Outline" : "Hide File Outline",
                   systemImage: collapsed ? "chevron.right" : "chevron.down") { collapsed.toggle() }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help(collapsed ? "Show File Outline" : "Hide File Outline")
                .accessibilityLabel("File Outline")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                .accessibilityHint(collapsed ? "Shows the outline" : "Hides the outline")
        }
        .padding(.leading, Self.leading)
        .padding(.trailing, Self.trailing)
        .frame(height: Self.height)
        .contentShape(.rect)
        .onTapGesture { collapsed.toggle() }
    }

    /// The Files header's title and accessory insets, so the two headers
    /// line up.
    static let leading: CGFloat = 14
    static let trailing: CGFloat = 5
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
