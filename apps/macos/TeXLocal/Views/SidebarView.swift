import SwiftUI

struct FilesList: View {
    @Environment(WindowModel.self) private var window
    @Environment(WorkspaceViews.self) private var views
    let project: ProjectModel
    @State private var selection: String?
    @State private var rename = InPlaceRename<String>()
    @State private var created: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        let filter = project.navigator.fileFilter
        let nodes = filtered(project.tree.nodes, \.children, by: filter) { $0.name }
        ScrollViewReader { proxy in
            List(selection: $selection) {
                TreeRows(nodes: nodes, children: \.children, isExpanded: { node in
                    filter.isEmpty ? disclosure(\.expandedFolders, of: project, key: node.path,
                                                subtree: node.children?.flattened.filter(\.isDirectory).map(\.path) ?? []) : .constant(true)
                }, insert: { urls in Task { await project.dropFiles(urls, into: "") } }) { node in
                    row(node).tag(node.path)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Files")
            .fileDrop(moves: { project.projectPath($0) != nil }) { urls in
                Task { await project.dropFiles(urls, into: "") }
            }
            .overlay {
                if !filter.isEmpty, nodes.isEmpty {
                    ContentUnavailableView.search(text: filter)
                } else if project.initialLoadComplete, project.tree.nodes.isEmpty {
                    ContentUnavailableView {
                        Label("No Files", systemImage: "text.document")
                    } description: {
                        Text("Create a file, or drag files here from the Finder.")
                    } actions: {
                        Button(MenuCommand.fileNew.title) { create(NewEntry(directory: false, folder: "")) }
                        Button(MenuCommand.fileUpload.title) { window.perform(.fileUpload, on: project) }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { paths in
                if let path = paths.first, let node = project.tree.node(at: path) {
                    if node.isDirectory {
                        Button(MenuCommand.fileNew.title) { create(NewEntry(directory: false, folder: node.path)) }
                        Button(MenuCommand.fileNewFolder.title) { create(NewEntry(directory: true, folder: node.path)) }
                        Divider()
                    } else if node.kind == .tex {
                        Button("Set as Main File") { project.mainFile = node.path }
                            .disabled(node.main == true)
                        Divider()
                    }
                    ItemMenuItems(actions: actions(node))
                }
            } primaryAction: { paths in
                guard let path = paths.first, project.tree.node(at: path)?.isDirectory == true else { return }
                if project.expandedFolders.remove(path) == nil { project.expandedFolders.insert(path) }
            }
            .contextMenu {
                Button(MenuCommand.fileNew.title) { create(NewEntry(directory: false, folder: "")) }
                Button(MenuCommand.fileNewFolder.title) { create(NewEntry(directory: true, folder: "")) }
                Divider()
                Button(MenuCommand.fileUpload.title) { window.perform(.fileUpload, on: project) }
            }
            .onChange(of: selection) { _, path in
                if let path, path != project.openPath, project.tree.node(at: path)?.isDirectory == false {
                    Task {
                        await project.open(path, focus: false, jump: true)
                        if project.openPath != path, selection == path { selection = project.openPath }
                    }
                }
            }
            .onChange(of: project.openPath, initial: true) { _, path in
                selection = path
                if let path { showRow(path) }
            }
            .onKeyPress(.return) {
                guard rename.id == nil, let node = selection.flatMap({ project.tree.node(at: $0) }) else { return .ignored }
                Task { actions(node).rename?() }
                return .handled
            }
            .focused($listFocused)
            .offersActions(for: listFocused && rename.id == nil ? selection : nil) { path in project.tree.node(at: path).map(actions) }
            .onChange(of: rename.id) { _, id in if let id { Task { proxy.scrollTo(id) } } }
            .onChange(of: window.newEntry, initial: true) { _, entry in
                guard let entry, !project.closed else { return }
                window.newEntry = nil
                create(entry)
            }
        }
    }

    private func showRow(_ path: String) {
        project.expandedFolders.formUnion(sequence(first: path.parentFolder) { $0.parentFolder }.prefix { !$0.isEmpty })
    }

    private var chosenFolder: String {
        guard let path = selection, let node = project.tree.node(at: path) else { return "" }
        return node.isDirectory ? path : path.parentFolder
    }

    private func create(_ entry: NewEntry) {
        let folder = entry.folder ?? chosenFolder
        project.navigator.fileFilter = ""
        Task {
            guard let path = await project.createEntry(in: folder, directory: entry.directory) else { return }
            showRow(path)
            selection = path
            created = entry.directory ? nil : path
            rename.begin(path, name: path.fileName)
        }
    }

    private func actions(_ node: TreeNode) -> ItemActions {
        ItemActions(rename: { created = nil; rename.begin(node.path, name: node.name) },
                    showInFinder: { project.url(node.path).map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } },
                    moveToTrash: { Task { await project.deleteEntry(node.path) } })
    }

    private func row(_ node: TreeNode) -> some View {
        let isMain = node.main == true
        return Label {
            HStack {
                if rename.id == node.path {
                    RenameField(text: $rename.name, isFile: !node.isDirectory, forbidden: "/",
                                spaceWarning: "Spaces can break \\input and \\include.", ended: { renameEnded(node) }) {
                        commitRename(node)
                    } cancel: {
                        rename.cancel()
                    }
                } else {
                    Text(node.name).truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: node.symbol)
                .overlay(alignment: .bottomLeading) {
                    if isMain {
                        Image(systemName: "star.circle.fill")
                            .symbolRenderingMode(.multicolor)
                            .foregroundStyle(.yellow)
                            .imageScale(.small)
                            .offset(x: -3, y: 3)
                            .help("Main File")
                    }
                }
        }
        .navigatorRow()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityLabel(isMain ? "\(node.name), Main File" : node.name)
        .fileDrop(moves: { project.projectPath($0) != nil }) { urls in
            let folder = node.isDirectory ? node.path : node.path.parentFolder
            Task { await project.dropFiles(urls, into: folder) }
        }
        .draggable(file: project.url(node.path))
    }

    private func renameEnded(_ node: TreeNode) {
        if created == node.path { views.focusEditor() } else { listFocused = true }
        created = nil
    }

    private func commitRename(_ node: TreeNode) {
        guard let name = rename.end(node.path, from: node.name) else { return }
        guard !name.contains("/") else {
            window.report("Couldn’t Rename “\(node.name)”", "File and folder names can’t contain “/”.")
            return
        }
        let folder = node.path.parentFolder
        let path = folder.isEmpty ? name : "\(folder)/\(name)"
        Task {
            await project.renameEntry(node.path, to: path)
            if selection == node.path, project.tree.node(at: path) != nil { selection = path }
        }
    }
}

extension View {
    func fileDrop(accepts: @escaping (URL) -> Bool = { _ in true }, moves: @escaping (URL) -> Bool = { _ in false },
                  action: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && accepts($0) }
            if !files.isEmpty { action(files) }
        }
        .dropConfiguration { _ in
            let urls = (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(accepts)
            var configuration = DropConfiguration(operation: urls.isEmpty ? .forbidden : urls.allSatisfy(moves) ? .move : .copy)
            if !urls.isEmpty { configuration.acceptedItemCount = urls.count }
            return configuration
        }
    }

    @ViewBuilder func draggable(file url: URL?) -> some View {
        if let url {
            draggable(url).dragConfiguration(DragConfiguration(operationsWithinApp: .init(allowMove: true)))
        } else {
            self
        }
    }
}

struct OutlineList: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @State private var chosen: Int?

    var body: some View {
        let outline = project.outline
        let current = project.currentHeading
        let filter = project.navigator.outlineFilter
        let nodes = filtered(project.outlineTree, \.children, by: filter) { $0.heading.title }
        let selection = Binding<Int?>(get: { chosen ?? current }, set: { id in
            guard let id, id != current, outline.indices.contains(id) else { return }
            chosen = id
            project.reveal(outline[id])
        })
        ScrollViewReader { proxy in
            List(selection: selection) {
                TreeRows(nodes: nodes, children: \.children, isExpanded: { node in
                    filter.isEmpty ? disclosure(\.foldedHeadings, of: project, key: node.foldKey, inverted: true,
                                                subtree: node.descendants.map(\.foldKey)) : .constant(true)
                }) { node in
                    HeadingRow(node: node, words: app.showWordCount ? node.words : nil).tag(node.id)
                        .simultaneousGesture(TapGesture().onEnded {
                            guard NSApp.currentEvent?.clickCount ?? 1 < 2, node.id == current || node.id == chosen else { return }
                            chosen = node.id == current ? nil : node.id
                            project.reveal(node.heading)
                        })
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Outline")
            .overlay {
                if !filter.isEmpty, nodes.isEmpty {
                    ContentUnavailableView.search(text: filter)
                } else if outline.isEmpty {
                    ContentUnavailableView("No Sections", systemImage: "list.bullet.indent")
                }
            }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
                guard let id = ids.first, outline.indices.contains(id) else { return }
                let heading = outline[id]
                Task { await project.open(heading.file, line: heading.line, atTop: true, focus: true, jump: true) }
            }
            .onChange(of: current, initial: true) { _, id in
                chosen = nil
                guard let id else { return }
                Task { proxy.scrollTo(id) }
            }
        }
    }
}

private struct HeadingRow: View {
    let node: OutlineNode
    let words: Int?

    var body: some View {
        let heading = node.heading
        HStack(spacing: 4) {
            Text(heading.title)
                .help(heading.title)
                .foregroundStyle(heading.untitled ? .secondary : .primary)
            if let words {
                Text(words, format: .number)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                    .accessibilityLabel("^[\(words) word](inflect: true)")
            }
        }
        .lineLimit(1)
        .navigatorRow()
        .accessibilityElement(children: .combine)
        .accessibilityValue(heading.level)
        .id(node.id)
    }
}
