import SwiftUI

/// The sidebar, as a writer's rather than a programmer's: the project's
/// files with the open document's outline beneath (as Overleaf pairs them),
/// project search at the top, and adding files at the foot.
struct NavigatorView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var selection: String?
    @State private var deleting: String?
    @FocusState private var searchFocused: Bool
    @AppStorage("outlineOpen") private var outlineOpen = true
    /// Sections folded in the outline, by level and title, so a fold
    /// survives edits that renumber the headings.
    @State private var collapsedSections: Set<String> = []

    var body: some View {
        List(selection: $selection) {
            if project.searchQuery.isEmpty {
                Section("Files") {
                    OutlineGroup(project.tree, children: \.children) { node in
                        row(node).tag(node.path)
                    }
                }
                if !project.outline.isEmpty, let path = project.openPath {
                    Section("Outline", isExpanded: $outlineOpen) {
                        OutlineRows(nodes: Outline.tree(project.outline), path: path,
                                    project: project, current: current, collapsed: $collapsedSections)
                    }
                }
            } else {
                searchResults
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $project.searchQuery, placement: .sidebar, prompt: "Search Project")
        .searchFocused($searchFocused)
        .onChange(of: app.searchFocusToken) { _, _ in searchFocused = true }
        .onChange(of: selection) { _, path in
            if let path, path != project.openPath, isTextFile(path) { Task { await project.open(path) } }
        }
        .onChange(of: project.openPath, initial: true) { _, path in selection = path }
        .overlay {
            if !project.searchQuery.isEmpty, project.searchHits.isEmpty {
                ContentUnavailableView.search(text: project.searchQuery)
            }
        }
        .safeAreaBar(edge: .bottom) {
            HStack {
                Menu("Add", systemImage: "plus") {
                    Button(MenuCommand.fileNew.title) { app.perform(.fileNew) }
                    Button(MenuCommand.fileNewFolder.title) { app.perform(.fileNewFolder) }
                    Divider()
                    Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload) }
                }
                .menuIndicator(.hidden)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Add Files")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await project.importFiles(urls) }
            return true
        }
        .confirmationDialog(
            "Move “\(deleting ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let path = deleting { Task { await project.deleteEntry(path) } }
            }
        }
    }

    /// The section the cursor is in.
    private var current: Int? {
        Outline.chain(project.outline, at: project.cursorLine).last?.id
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
                                .font(.caption)
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
        Label {
            HStack {
                Text(node.name)
                if node.path == project.settings?.mainFile {
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
        .accessibilityLabel(node.name)
        .contextMenu {
            if !node.isDirectory && node.path.hasSuffix(".tex") {
                Button("Set as Main File") { Task { await project.setMainFile(node.path) } }
                Divider()
            }
            Button("Rename…") { app.prompt = .renameEntry(node.path) }
            Button("Show in Finder") { reveal(node.path, in: project) }
            Divider()
            Button("Move to Trash", role: .destructive) { deleting = node.path }
        }
    }

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

/// Select a project entry in Finder.
@MainActor
func reveal(_ path: String, in project: ProjectModel) {
    Task {
        if let abs = try? await Core.shared.call("raw_path", ["id": project.id, "path": path], as: String.self) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
        }
    }
}

/// An error or warning; choosing it opens its line — in the main file when
/// the log names none, as the web's does.
struct IssueRow: View {
    let item: LogItem
    let project: ProjectModel

    var body: some View {
        Button {
            if let file { Task { await project.open(file, line: item.line) } }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.message).lineLimit(3).textSelection(.enabled)
                    if let file = item.file {
                        Text(item.line.map { "\(file):\($0)" } ?? file)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(item.isError ? .red : .orange)
            }
        }
        .buttonStyle(.plain)
        .disabled(file == nil)
    }

    private var file: String? {
        item.file ?? (item.line == nil ? nil : project.settings?.mainFile)
    }
}

/// The outline's headings with native disclosure triangles, as Finder,
/// Mail and Xcode's navigators show a hierarchy: the system indents each
/// level and draws no guide lines. Headings start expanded.
private struct OutlineRows: View {
    let nodes: [OutlineNode]
    let path: String
    let project: ProjectModel
    let current: Int?
    @Binding var collapsed: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: expansion(node)) {
                    AnyView(OutlineRows(nodes: children, path: path, project: project,
                                        current: current, collapsed: $collapsed))
                } label: {
                    row(node.item)
                }
            } else {
                row(node.item)
            }
        }
    }

    private func key(_ node: OutlineNode) -> String { "\(node.item.level):\(node.item.title)" }

    private func expansion(_ node: OutlineNode) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(key(node)) },
            set: { open in
                if open { collapsed.remove(key(node)) } else { collapsed.insert(key(node)) }
            }
        )
    }

    private func row(_ item: OutlineItem) -> some View {
        Button {
            Task { await project.open(path, line: item.line) }
        } label: {
            Text(Outline.displayTitle(item))
                .lineLimit(1)
                .foregroundStyle(item.title == "(untitled)" ? .secondary : .primary)
                .fontWeight(item.id == current ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
