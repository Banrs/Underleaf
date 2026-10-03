import SwiftUI

/// The project's files, or the project search's results while there is a
/// query.
struct FilesList: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var selection: String?
    @State private var hit: SearchHit.ID?
    @State private var rename = InPlaceRename<String>()
    @FocusState private var listFocused: Bool
    /// The open folders, by path.
    @State private var expanded: Set<String> = []

    var body: some View {
        // Two lists: one list diffed from the tree to grouped hits and back keeps stale rows.
        if project.isSearching { results } else { files }
    }

    private var files: some View {
        List(selection: $selection) {
            Section("Files") {
                // Between the top-level rows, into the project's top level.
                TreeRows(nodes: project.tree, children: \.children, isExpanded: { $expanded.contains($0.path) },
                         insert: { urls in Task { await project.dropFiles(urls, into: "") } }) { node in
                    row(node).tag(node.path)
                }
            }
            // The folded File Outline's header, which unfolds it into its pane below.
            if project.isLaTeX, app.outlineCollapsed {
                Section(isExpanded: Binding(get: { false }, set: { if $0 { app.outlineCollapsed = false } })) {
                } header: {
                    Text("File Outline")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Files")
        // The clicked row's menu, which leaves the selection (and the open file) as
        // it is; on the list's empty space, the list's own.
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first, let node = project.tree.flattened.first(where: { $0.path == path }) {
                if node.isDirectory {
                    Button(MenuCommand.fileNew.title) { app.prompt = .newFile(in: node.path) }
                    Button(MenuCommand.fileNewFolder.title) { app.prompt = .newFolder(in: node.path) }
                    Divider()
                } else if isLaTeXFile(node.path) {
                    Button("Set as Main File") { Task { await project.setMainFile(node.path) } }
                        .disabled(node.path == project.settings?.mainFile)
                    Divider()
                }
                ItemMenuItems(actions: actions(node))
            } else {
                Button(MenuCommand.fileNew.title) { app.perform(.fileNew, on: project) }
                Button(MenuCommand.fileNewFolder.title) { app.perform(.fileNewFolder, on: project) }
                Divider()
                Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload, on: project) }
            }
        } primaryAction: { paths in
            // A folder opens or closes; a file is already open once chosen.
            guard let path = paths.first, project.tree.flattened.contains(where: { $0.path == path && $0.isDirectory }) else { return }
            if expanded.remove(path) == nil { expanded.insert(path) }
        }
        .onChange(of: selection) { _, path in
            if let path, path != project.openPath,
               project.tree.flattened.contains(where: { $0.path == path && !$0.isDirectory }) {
                Task {
                    await project.open(path, focus: false)
                    // It didn't open (reported): the file on screen stays chosen.
                    if project.openPath != path, selection == path { selection = project.openPath }
                }
            }
        }
        .onChange(of: project.openPath, initial: true) { _, path in
            selection = path
            // The open file's folders open, so its row shows.
            var folder = ((path ?? "") as NSString).deletingLastPathComponent
            while !folder.isEmpty { expanded.insert(folder); folder = (folder as NSString).deletingLastPathComponent }
        }
        // Return renames the chosen item, as in Finder: after the key event, through
        // which the list keeps the keyboard from the field.
        .onKeyPress(.return) {
            guard rename.id == nil, let node = project.tree.flattened.first(where: { $0.path == selection }) else { return .ignored }
            Task { actions(node).rename() }
            return .handled
        }
        .focused($listFocused)
        .offersActions(for: listFocused && rename.id == nil ? selection : nil) { path in
            project.tree.flattened.first { $0.path == path }.map(actions)
        }
    }

    private func actions(_ node: TreeNode) -> ItemActions {
        ItemActions(rename: { rename.begin(node.path, name: node.name) },
                    showInFinder: { project.showInFinder(node.path) },
                    moveToTrash: { Task { await project.deleteEntry(node.path) } })
    }

    /// Choosing a hit shows it and leaves the keyboard in the list; double-clicking
    /// or Return goes into the source there.
    private var results: some View {
        List(selection: $hit) { searchResults }
            .listStyle(.sidebar)
            .accessibilityLabel("Search Results")
            // A new query can reuse a file/line ID. Clear the old selection so
            // the first click on that new hit opens it.
            .onChange(of: project.searchQuery, initial: true) { _, _ in hit = nil }
            .onChange(of: hit) { _, id in open(id, focus: false) }
            .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in open(ids.first, focus: true) }
            .overlay {
                if project.searchHits?.isEmpty == true { ContentUnavailableView.search(text: project.searchQuery) }
            }
    }

    private func open(_ id: SearchHit.ID?, focus: Bool) {
        if let found = project.searchHits?.first(where: { $0.id == id }) {
            Task { await project.open(found.file, line: found.line, focus: focus) }
        }
    }

    /// Hits grouped by file, each line with its match picked out.
    @ViewBuilder
    private var searchResults: some View {
        let groups = Dictionary(grouping: project.searchHits ?? [], by: \.file).sorted { $0.key < $1.key }
        ForEach(groups, id: \.key) { file, hits in
            Section {
                ForEach(hits) { hit in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)")
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text("\(hit.line)")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Line \(hit.line)")
                    }
                    // One hit, its line and where on it, as one element.
                    .accessibilityElement(children: .combine)
                }
            } header: {
                // Middle truncation keeps the extension and the count, as Finder keeps a name's end.
                Text("\(file) — \(hits.count)").truncationMode(.middle)
            }
        }
    }

    private func row(_ node: TreeNode) -> some View {
        let isMain = node.path == project.settings?.mainFile
        return Label {
            HStack {
                if rename.id == node.path {
                    RenameField(text: $rename.name, isFile: !node.isDirectory, ended: { listFocused = true }) {
                        commitRename(node)
                    } cancel: {
                        rename.cancel()
                    }
                } else {
                    Text(node.name).truncationMode(.middle)
                }
                if isMain {
                    Spacer()
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .imageScale(.small)
                        .help("Main File")
                        .accessibilityHidden(true)
                }
            }
        } icon: {
            Image(systemName: fileSymbol(node.path, directory: node.isDirectory))
        }
        // The whole row a drop target, not only its name.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        // The star's name too: the row's label replaces its children's.
        .accessibilityLabel(isMain ? "\(node.name), Main File" : node.name)
        // Into the folder dropped on, or the dropped-on file's folder.
        .fileDrop(moves: { project.projectPath($0) != nil }) { urls in
            let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
            Task { await project.dropFiles(urls, into: folder) }
        }
        .draggable(file: project.url(node.path))
    }

    private func commitRename(_ node: TreeNode) {
        guard let name = rename.end(node.path, from: node.name) else { return }
        guard !name.contains("/") else {
            app.alert = AppAlert("Couldn’t Rename “\(node.name)”", "File and folder names can’t contain “/”.")
            return
        }
        let folder = (node.path as NSString).deletingLastPathComponent
        Task { await project.renameEntry(node.path, to: folder.isEmpty ? name : "\(folder)/\(name)") }
    }
}

/// A tree's rows, each with children a disclosure group, open as `isExpanded` says:
/// the files and the outline. `insert` takes files dropped between its top rows.
private struct TreeRows<Node: Identifiable, Row: View>: View {
    let nodes: [Node]
    let children: (Node) -> [Node]?
    let isExpanded: (Node) -> Binding<Bool>
    var insert: (([URL]) -> Void)?
    @ViewBuilder let row: (Node) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if let kids = children(node) {
                DisclosureGroup(isExpanded: isExpanded(node)) {
                    TreeRows(nodes: kids, children: children, isExpanded: isExpanded, row: row)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
        .onInsert(of: insert == nil ? [] : [.fileURL]) { _, providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url = await withCheckedContinuation { done in
                        _ = provider.loadTransferable(type: URL.self) { done.resume(returning: try? $0.get()) }
                    }
                    if let url { urls.append(url) }
                }
                if !urls.isEmpty { insert?(urls) }
            }
        }
    }
}

private extension Binding<Set<String>> {
    /// On while the set holds `key`; a switch that adds or removes it.
    func contains(_ key: String) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue.contains(key) },
                      set: { if $0 { wrappedValue.insert(key) } else { wrappedValue.remove(key) } })
    }
}

#Preview("File tree") {
    @Previewable @State var expanded: Set<String> = ["figures"]
    let file = { (path: String) in TreeNode(type: "file", name: (path as NSString).lastPathComponent, path: path, children: nil) }
    List {
        Section("Files") {
            TreeRows(nodes: [
                TreeNode(type: "dir", name: "figures", path: "figures",
                         children: [file("figures/plot.pdf"), file("figures/diagram.png")]),
                file("main.tex"), file("references.bib"),
            ], children: \.children, isExpanded: { $expanded.contains($0.path) }) { node in
                Label(node.name, systemImage: fileSymbol(node.path, directory: node.isDirectory))
            }
        }
    }
    .listStyle(.sidebar)
    .frame(width: ColumnMetrics.sidebarIdeal, height: 240)
}

extension View {
    /// Takes dropped files, copied in or, those `moves` names, moved (as Finder
    /// does within a volume). A drag of anything else, of a file `accepts` turns
    /// down, or of more than `limit` files, is refused while dragged.
    func fileDrop(accepts: @escaping (URL) -> Bool = { _ in true }, moves: @escaping (URL) -> Bool = { _ in false },
                  limit: Int = .max, action: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && accepts($0) }
            if !files.isEmpty, files.count <= limit { action(files) }
        }
        .dropConfiguration { _ in DropConfiguration(operation: dropOperation(accepts, moves, limit)) }
    }

    /// Dragged out as the file itself: other apps copy it, the tree moves it.
    @ViewBuilder
    func draggable(file url: URL?) -> some View {
        if let url {
            draggable(url).dragConfiguration(DragConfiguration(operationsWithinApp: .init(allowMove: true)))
        } else {
            self
        }
    }
}

/// What a drop does with the dragged files `accepts` takes. AppKit's drag
/// pasteboard: a drop session names none of its items until they're dropped.
private func dropOperation(_ accepts: (URL) -> Bool, _ moves: (URL) -> Bool, _ limit: Int) -> DropOperation {
    let urls = (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(accepts)
    return urls.isEmpty || urls.count > limit ? .forbidden : urls.allSatisfy(moves) ? .move : .copy
}

/// The project's sections from its main file, in a pane under the files, whose
/// header folds it away. Takes no drops: files go into the list above.
struct OutlineList: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    /// Folded headings, by file, level and title, for this session.
    @State private var folded: Set<String> = []
    /// The line the selection follows: the caret's or the top line, whichever
    /// changed last; the caret's when both do, as its `onChange` runs second.
    @State private var line = 1
    /// A heading chosen in the list, shown selected until the source reaches it.
    @State private var chosen: Int?

    var body: some View {
        let outline = project.outline
        let current = Outline.current(outline, file: project.openPath, line: line)
        // The current heading is the selection; choosing one, by click or arrow
        // key, scrolls the source to it and leaves the keyboard where it was.
        let selection = Binding<Int?>(get: { chosen ?? current }, set: { id in
            guard let id, id != current, let item = outline.first(where: { $0.id == id }) else { return }
            chosen = id
            project.reveal(item)
        })
        ScrollViewReader { proxy in
            List(selection: selection) {
                Section(isExpanded: Binding(get: { !app.outlineCollapsed }, set: { app.outlineCollapsed = !$0 })) {
                    TreeRows(nodes: Outline.tree(outline), children: \.children, isExpanded: { node in
                        let key = "\(node.item.file)\t\(node.item.level):\(node.item.title)"
                        return Binding(get: { !folded.contains(key) },
                                       set: { if $0 { folded.remove(key) } else { folded.insert(key) } })
                    }) { node in
                        HeadingRow(item: node.item).equatable().tag(node.id)
                    }
                } header: {
                    Text("File Outline")
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("File Outline")
            .overlay {
                if outline.isEmpty { ContentUnavailableView("No Sections", systemImage: "list.bullet.indent") }
            }
            // Return or a double-click goes into the source there, as in the search results.
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
                guard let item = outline.first(where: { $0.id == ids.first }) else { return }
                Task { await project.open(item.file, line: item.line, atTop: true, focus: true) }
            }
            .onChange(of: project.topHeading) { line = project.topLine }
            .onChange(of: project.cursorLine, initial: true) { _, cursor in line = cursor }
            // The current heading's row comes into view if it shows.
            .onChange(of: current, initial: true) { _, id in
                chosen = nil
                guard let id else { return }
                Task { proxy.scrollTo(id) }
            }
        }
    }
}

/// A heading in the file outline. Equatable: as a plain view, a heading that
/// takes the place of a leaf and has subheadings opens closed (27.2).
private struct HeadingRow: View, Equatable {
    let item: OutlineItem

    var body: some View {
        Text(item.displayTitle)
            .lineLimit(1)
            .help(item.displayTitle)
            .foregroundStyle(item.isUntitled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            // Its kind ("Subsection"); the list tells its depth.
            .accessibilityValue(item.kind)
            // For scrollTo, inside the row: on it, the list would take it for the row's
            // identity, and a heading that gains subheadings would keep a leaf's closed state.
            .id(item.id)
    }
}
