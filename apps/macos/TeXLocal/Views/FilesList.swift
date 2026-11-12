import SwiftUI

struct FilesList: View {
    @Environment(WindowModel.self) private var window
    @Environment(WorkspaceViews.self) private var views
    let project: ProjectModel
    @State private var rename = InPlaceRename<String>()
    @State private var created: String?
    @FocusState private var listFocused: Bool

    private var selection: String? {
        get { project.navigator.fileSelection }
        nonmutating set { project.navigator.fileSelection = newValue }
    }

    private var shownNodes: [TreeNode] {
        let nodes = filtered(project.files, \.children, by: project.navigator.fileFilter) { $0.name }
        guard project.navigator.showsOnlyRecentFiles else { return nodes }
        let recent = Set(project.navigator.recentFiles)
        return filtered(nodes, \.children) { !$0.isDirectory && recent.contains($0.path) }
    }

    @ViewBuilder private func emptyState(_ empty: Bool, filter: String, recentOnly: Bool) -> some View {
        if empty, !filter.isEmpty || recentOnly, !project.files.isEmpty {
            NoFilterResults()
        } else if project.initialLoadComplete, project.files.isEmpty {
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

    var body: some View {
        let (filter, recentOnly) = (project.navigator.fileFilter, project.navigator.showsOnlyRecentFiles)
        let nodes = shownNodes, folds = filter.isEmpty && !recentOnly
        ScrollViewReader { proxy in
            List(selection: Bindable(project.navigator).fileSelection) {
                TreeRows(nodes: nodes, children: \.children, isExpanded: { node in
                    folds ? disclosure(\.expandedFolders, of: project, key: node.path,
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
            .overlay { emptyState(nodes.isEmpty, filter: filter, recentOnly: recentOnly) }
            .contextMenu(forSelectionType: String.self) { paths in
                if let path = paths.first, let node = project.files.node(at: path) {
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
                guard let path = paths.first, project.files.node(at: path)?.isDirectory == true else { return }
                if project.expandedFolders.remove(path) == nil { project.expandedFolders.insert(path) }
            }
            .contextMenu {
                Button(MenuCommand.fileNew.title) { create(NewEntry(directory: false, folder: "")) }
                Button(MenuCommand.fileNewFolder.title) { create(NewEntry(directory: true, folder: "")) }
                Divider()
                Button(MenuCommand.fileUpload.title) { window.perform(.fileUpload, on: project) }
            }
            .onChange(of: selection) { _, path in
                if let path, path != project.openPath, project.files.node(at: path)?.isDirectory == false {
                    Task {
                        await project.open(path, focus: false, jump: true)
                        if project.openPath != path, selection == path { selection = project.openPath }
                    }
                }
            }
            .onChange(of: project.openPath, initial: true) { old, path in
                if old != path || selection == nil { selection = path }
                if let path { showRow(path) }
            }
            .onKeyPress(.return) {
                guard rename.id == nil, let node = selection.flatMap({ project.files.node(at: $0) }) else { return .ignored }
                Task { actions(node).rename?() }
                return .handled
            }
            .focused($listFocused)
            .offersActions(for: listFocused && rename.id == nil ? selection : nil) { path in project.files.node(at: path).map(actions) }
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
        guard let path = selection, let node = project.files.node(at: path) else { return "" }
        return node.folder
    }

    private func create(_ entry: NewEntry) {
        let folder = entry.folder ?? chosenFolder
        (project.navigator.fileFilter, project.navigator.showsOnlyRecentFiles) = ("", false)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityLabel(isMain ? "\(node.name), Main File" : node.name)
        .fileDrop(moves: { project.projectPath($0) != nil }) { urls in
            Task { await project.dropFiles(urls, into: node.folder) }
        }
        .draggable(file: project.url(node.path))
    }

    private func renameEnded(_ node: TreeNode) {
        if created == node.path { views.focusEditor() } else { listFocused = true }
        created = nil
    }

    private func commitRename(_ node: TreeNode) {
        guard let name = rename.end(node.path, from: node.name) else { return }
        let path = node.path.parentFolder.appending(component: name)
        Task {
            await project.renameEntry(node.path, to: path)
            if selection == node.path, project.files.node(at: path) != nil { selection = path }
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
