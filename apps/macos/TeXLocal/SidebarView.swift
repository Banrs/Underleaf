import SwiftUI

/// The sidebar, as a writer's rather than a programmer's and as Overleaf
/// lays it out: the project's files over the open document's outline, with
/// a divider to drag between them, and project search at the top. They are
/// separate lists, so each shows its own selection: the open file, and the
/// section on screen.
struct NavigatorView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        SplitController(app: app, axis: .vertical, autosave: "OutlineSplit", panes: [
            SplitPane(minimum: 100) { FilesList(project: project) },
            SplitPane(minimum: 80, fraction: 0.45, keepsSize: true, shown: showsOutline) {
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

    var body: some View {
        List(selection: $selection) {
            if project.searchQuery.isEmpty {
                Section {
                    OutlineGroup(project.tree, children: \.children) { node in
                        row(node).tag(node.path)
                    }
                } header: {
                    HStack {
                        Text("Files")
                        Spacer()
                        Menu("Add", systemImage: "plus") {
                            Button(MenuCommand.fileNew.title) { app.perform(.fileNew) }
                            Button(MenuCommand.fileNewFolder.title) { app.perform(.fileNewFolder) }
                            Divider()
                            Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload) }
                        }
                        // A sidebar header's accessory: a plain small glyph, not
                        // a pane bar's button.
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .menuIndicator(.hidden)
                        .labelStyle(.iconOnly)
                        .fixedSize()
                        .help("Add Files")
                    }
                }
            } else {
                searchResults
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, path in
            if let path, path != project.openPath, isTextFile(path) { Task { await project.open(path, focus: false) } }
        }
        .onChange(of: project.openPath, initial: true) { _, path in selection = path }
        .overlay {
            if !project.searchQuery.isEmpty, project.searchHits.isEmpty {
                ContentUnavailableView.search(text: project.searchQuery)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await project.importFiles(urls) }
            return true
        }
        // ⌫, as Finder and the projects table take it.
        .onDeleteCommand { if let selection, project.searchQuery.isEmpty { deleting = selection } }
        .confirmationDialog(
            "Move “\((deleting.map { ($0 as NSString).lastPathComponent }) ?? "")” to the Trash?",
            isPresented: Binding(presenting: $deleting),
            titleVisibility: .visible,
            presenting: deleting
        ) { path in
            Button("Move to Trash", role: .destructive) { Task { await project.deleteEntry(path) } }
        } message: { _ in
            Text("You can restore it from the Trash.")
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
                Text(node.name)
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
            Button("Rename…") { app.prompt = .renameEntry(node.path) }
            Button("Show in Finder") { project.showInFinder(node.path) }
            Divider()
            Button("Move to Trash", role: .destructive) { deleting = node.path }
        }
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

/// The open document's sections, as Overleaf's file outline: the selection
/// is the section on screen — the one the top of the source is in — and
/// follows as the source scrolls. Choosing one brings it to the top.
private struct OutlineList: View {
    @Bindable var project: ProjectModel
    @State private var section: Int?
    /// Sections folded, by `OutlineRows.key`.
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $section) {
                Section("File Outline") {
                    OutlineRows(nodes: Outline.tree(project.outline), collapsed: $collapsed)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if project.outline.isEmpty {
                    ContentUnavailableView("No Sections", systemImage: "list.bullet.indent")
                }
            }
            .onChange(of: current, initial: true) { _, id in
                for item in Outline.chain(project.outline, at: project.topLine).dropLast() {
                    collapsed.remove(OutlineRows.key(item))
                }
                section = id
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: section) { _, id in
                guard let id, id != current, let path = project.openPath,
                      let item = project.outline.first(where: { $0.id == id }) else { return }
                Task { await project.open(path, line: item.line, atTop: true, focus: false) }
            }
        }
    }

    private var current: Int? {
        Outline.chain(project.outline, at: project.topLine).last?.id
    }
}

/// The outline's headings with native disclosure triangles, as Finder,
/// Mail and Xcode's navigators show a hierarchy: the system indents each
/// level and draws no guide lines. Headings start expanded; each row is
/// tagged with its heading, for the outline list's selection.
private struct OutlineRows: View {
    let nodes: [OutlineNode]
    @Binding var collapsed: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: expansion(node)) {
                    AnyView(OutlineRows(nodes: children, collapsed: $collapsed))
                } label: {
                    row(node.item)
                }
            } else {
                row(node.item)
            }
        }
    }

    /// A fold's key: level and title, so it survives edits that renumber
    /// the headings.
    static func key(_ item: OutlineItem) -> String { "\(item.level):\(item.title)" }

    private func expansion(_ node: OutlineNode) -> Binding<Bool> {
        let key = Self.key(node.item)
        return Binding(
            get: { !collapsed.contains(key) },
            set: { open in
                if open { collapsed.remove(key) } else { collapsed.insert(key) }
            }
        )
    }

    private func row(_ item: OutlineItem) -> some View {
        Text(Outline.displayTitle(item))
            .lineLimit(1)
            .foregroundStyle(item.title == "(untitled)" ? .secondary : .primary)
            .tag(item.id)
            .id(item.id)
    }
}
