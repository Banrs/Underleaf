import SwiftUI

/// The sidebar: one native sidebar list with the project's files over the
/// open document's outline, each a section that folds from its header as
/// Finder's, Mail's and Notes' do, with project search at the top. Search
/// results take the whole sidebar, in a list of their own.
///
/// The list's one selection is the open file. Headings are a table of
/// contents rather than a second selection (`OutlineRows`).
struct NavigatorView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @FocusState private var searchFocused: Bool
    @State private var selection: String?
    @State private var deleting: String?
    /// The row whose name is being edited in place, and the name so far.
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var renameFocused: Bool
    @State private var onScreen = OnScreenRows()
    @AppStorage("SidebarFilesExpanded") private var filesExpanded = true
    @AppStorage("SidebarOutlineExpanded") private var outlineExpanded = true

    var body: some View {
        // Two lists rather than one whose sections change shape: the
        // sidebar's outline view, diffed from two sections to grouped hits
        // and back, kept stale rows.
        Group {
            if project.searchQuery.isEmpty { browser } else { results }
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
        .searchable(text: $project.searchQuery, placement: .sidebar, prompt: "Search Project")
        .searchFocused($searchFocused)
        .onChange(of: app.searchFocusToken) { _, _ in searchFocused = true }
    }

    private var browser: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Section(isExpanded: $filesExpanded) {
                    OutlineGroup(project.tree, children: \.children) { node in
                        row(node)
                            .tag(node.path)
                            .onAppear { onScreen.files.insert(node.path) }
                            .onDisappear { onScreen.files.remove(node.path) }
                    }
                } header: {
                    filesHeader
                }
                if showsOutline {
                    Section("Outline", isExpanded: $outlineExpanded) {
                        OutlineRows(project: project, onScreen: onScreen)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, path in
                if let path, path != project.openPath, isTextFile(path) { Task { await project.open(path, focus: false) } }
            }
            .onChange(of: project.openPath, initial: true) { _, path in selection = path }
            // ⌫, as Finder and the projects table take it.
            .onDeleteCommand { if let selection { deleting = selection } }
            .task(id: ObjectIdentifier(project)) { await follow(with: proxy) }
        }
    }

    private var results: some View {
        List { searchResults }
            .listStyle(.sidebar)
            .overlay {
                if project.searchHits.isEmpty { ContentUnavailableView.search(text: project.searchQuery) }
            }
    }

    private var showsOutline: Bool {
        project.openPath?.hasSuffix(".tex") == true
    }

    /// Brings the current section into view as the source scrolls, but only
    /// once the files have been scrolled away (or folded): the sidebar never
    /// scrolls the files out of view by itself. The scroll is the least that
    /// shows the heading, as a list reveals a row. Observed here rather than
    /// in a body, so the scroll re-renders nothing.
    private func follow(with proxy: ScrollViewProxy) async {
        var last: Int?
        for await current in Observations({ Outline.chain(project.outline, at: project.topLine).last?.id }) {
            guard current != last else { continue }
            last = current
            guard let current, showsOutline, outlineExpanded, project.searchQuery.isEmpty,
                  onScreen.files.isEmpty, !onScreen.headings.contains(current) else { continue }
            proxy.scrollTo(current)
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

/// The sidebar's rows on screen, as the list shows and hides them. Not
/// observed: only `NavigatorView.follow` reads it, when the section changes.
private final class OnScreenRows {
    var files: Set<String> = []
    var headings: Set<Int> = []
}

/// The open document's headings as a table of contents: flat list rows,
/// indented by how the headings nest (`Outline.depths`), with no disclosure
/// (the section folds as a whole from its header), a step smaller than the
/// file rows. Untagged, so they take no part in the list's selection and
/// draw no capsule: the current section, the one at the top of the source
/// (`ProjectModel.topLine`), is in the accent colour and semibold instead.
///
/// Its own view so that only it reads the top line: scrolling the source
/// re-renders this, not the files, and only the two headings whose state
/// changes (`HeadingRow` is equatable).
private struct OutlineRows: View {
    let project: ProjectModel
    let onScreen: OnScreenRows
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        let outline = project.outline
        if outline.isEmpty {
            Text("No Sections").foregroundStyle(.secondary)
        } else {
            let depths = Outline.depths(outline)
            let current = Outline.chain(outline, at: project.topLine).last?.id
            let metrics = HeadingMetrics(rowSize)
            ForEach(outline) { item in
                HeadingRow(project: project, item: item, depth: depths[item.id],
                           isCurrent: item.id == current, metrics: metrics)
                    .equatable()
                    .onAppear { onScreen.headings.insert(item.id) }
                    .onDisappear { onScreen.headings.remove(item.id) }
            }
        }
    }
}

/// A heading's text and indent by the user's sidebar icon size. The row is
/// the list's own, as tall as a file row (the sidebar list has one row
/// height for every row); the text is a step down from the file rows'
/// (Large 13, Medium 11, Small 10: the kit's next row size down), as
/// Mail's and Notes' secondary rows are.
private struct HeadingMetrics: Equatable {
    let font: Font
    let indent: CGFloat

    init(_ size: SidebarRowSize) {
        switch size {
        case .large: (font, indent) = (.body, 12)
        case .small: (font, indent) = (.caption, 8)
        default: (font, indent) = (.subheadline, 10)
        }
    }
}

/// A heading: not a list selection, so it draws no selection capsule; the
/// current one is in the accent colour and semibold, as macOS 27's sidebar
/// marks a selection. Choosing one scrolls it to the top of the source and
/// leaves focus where it was. Regular weight otherwise (the kit's small row
/// title is Medium), so the current heading stands out.
private struct HeadingRow: View, Equatable {
    let project: ProjectModel
    let item: OutlineItem
    let depth: Int
    let isCurrent: Bool
    let metrics: HeadingMetrics

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.project === b.project && a.item == b.item && a.depth == b.depth
            && a.isCurrent == b.isCurrent && a.metrics == b.metrics
    }

    var body: some View {
        let title = Outline.displayTitle(item)
        Button {
            guard let path = project.openPath else { return }
            Task { await project.open(path, line: item.line, atTop: true, focus: false) }
        } label: {
            Label {
                // The whole title as a tooltip only where it's cut short.
                ViewThatFits(in: .horizontal) {
                    Text(title).fixedSize()
                    Text(title).help(title)
                }
                .lineLimit(1)
                .font(metrics.font)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint)
                                 : item.isUntitled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.leading, CGFloat(depth) * metrics.indent)
            } icon: {
                // The file rows' icon column, left empty: the outermost
                // headings start where the file names do, at every sidebar
                // size, whether or not the tree has folders.
                Image(systemName: "doc").hidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue("Level \(depth + 1)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
