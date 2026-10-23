import SwiftUI

/// The project's files, then the open file's outline, in one sidebar list; its search finds in every file, as the Mac's.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    /// Back to the source, where the split has collapsed to one column.
    let showSource: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var renaming: TreeNode?
    @State private var newName = ""

    var body: some View {
        @Bindable var search = project.search
        Group {
            if project.search.isSearching { SearchResults(project: project, showSource: showSource) } else { files }
        }
        .navigationTitle(project.name)
        .searchable(text: $search.query, placement: .sidebar, prompt: "Find in Project")
        .task(id: project.search.query) {
            if project.search.isSearching { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            await project.search.run(in: project.session)
        }
        .toolbar {
            if sizeClass == .compact {
                ToolbarItem(placement: .topBarLeading) { CloseProjectButton() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") { addItems(in: "") }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { node in
            TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename(node) }
        }
        .onChange(of: app.newEntry, initial: true) { _, entry in
            guard let entry, !project.closed else { return }
            app.newEntry = nil
            create(in: entry.folder ?? "", directory: entry.directory)
        }
    }

    private var files: some View {
        List {
            Section("Files") {
                TreeRows(nodes: project.tree.nodes, project: project) { node in
                    row(node)
                        .contextMenu { actions(node) }
                        .swipeActions { swipe(node) }
                }
            }
            if project.isLaTeX {
                Section("Outline", isExpanded: Binding(get: { !app.outlineCollapsed }, set: { app.outlineCollapsed = !$0 })) {
                    OutlineRows(nodes: project.outlineTree, project: project, showSource: showSource)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if project.initialLoadComplete, project.tree.nodes.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "text.document")
                } description: {
                    Text("Create a file, or add files from Files.")
                } actions: {
                    Button(MenuCommand.fileNew.title) { create(in: "", directory: false) }
                    Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload, on: project) }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { Task { await project.dropFiles(files, into: "") } }
            return !files.isEmpty
        }
    }

    private func row(_ node: TreeNode) -> some View {
        Button {
            guard !node.isDirectory else { return }
            showSource()
            Task { await project.open(node.path) }
        } label: {
            Label {
                HStack {
                    Text(node.name).truncationMode(.middle)
                    if node.main == true {
                        Spacer()
                        Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small).accessibilityHidden(true)
                    }
                }
            } icon: { Image(systemName: node.symbol) }
        }
        .foregroundStyle(.primary)
        .listRowBackground(node.path == project.openPath ? Color.accentColor.opacity(0.18) : nil)
        .accessibilityLabel(node.main == true ? "\(node.name), Main File" : node.name)
        .accessibilityAddTraits(node.path == project.openPath ? .isSelected : [])
        .draggable(project.url(node.path) ?? URL(filePath: "/"))
    }

    @ViewBuilder private func addItems(in folder: String) -> some View {
        Button(MenuCommand.fileNew.title, systemImage: "doc.badge.plus") { create(in: folder, directory: false) }
        Button(MenuCommand.fileNewFolder.title, systemImage: "folder.badge.plus") { create(in: folder, directory: true) }
        Button(MenuCommand.fileUpload.title, systemImage: "square.and.arrow.down") { app.perform(.fileUpload, on: project) }
    }

    @ViewBuilder private func actions(_ node: TreeNode) -> some View {
        if node.isDirectory {
            addItems(in: node.path)
            Divider()
        } else if node.kind == .tex {
            Button("Set as Main File", systemImage: "star") { Task { await project.patchSettings(.mainFile(node.path)) } }
                .disabled(node.main == true)
            Divider()
        }
        Button("Rename", systemImage: "pencil") { beginRename(node) }
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await project.deleteEntry(node.path) } }
    }

    @ViewBuilder private func swipe(_ node: TreeNode) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await project.deleteEntry(node.path) } }
        Button("Rename", systemImage: "pencil") { beginRename(node) }
    }

    private func beginRename(_ node: TreeNode) {
        newName = node.name
        renaming = node
    }

    private func create(in folder: String, directory: Bool) {
        if project.search.isSearching { project.search.query = "" }
        Task {
            guard let path = await project.createEntry(in: folder, directory: directory), let node = project.tree.node(at: path) else { return }
            project.expandedFolders.formUnion(sequence(first: path.parentFolder) { $0.parentFolder }.prefix { !$0.isEmpty })
            beginRename(node)
        }
    }

    private func rename(_ node: TreeNode) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != node.name else { return }
        guard !name.contains("/") else {
            app.alert = AppAlert("Couldn’t Rename “\(node.name)”", "File and folder names can’t contain “/”.")
            return
        }
        let folder = node.path.parentFolder
        Task { await project.renameEntry(node.path, to: folder.isEmpty ? name : "\(folder)/\(name)") }
    }
}

/// Folders as disclosure groups whose open state is the project's, kept with its settings.
private struct TreeRows<Row: View>: View {
    let nodes: [TreeNode]
    let project: ProjectModel
    @ViewBuilder let row: (TreeNode) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(get: { project.expandedFolders.contains(node.path) }, set: { open in
                    if open { project.expandedFolders.insert(node.path) } else { project.expandedFolders.remove(node.path) }
                })) {
                    TreeRows(nodes: children, project: project, row: row)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
    }
}

/// The open file's headings; the current one is marked, and a tap goes to it.
private struct OutlineRows: View {
    let nodes: [OutlineNode]
    let project: ProjectModel
    let showSource: () -> Void

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children, !children.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { !project.foldedHeadings.contains(node.foldKey) }, set: { open in
                    if open { project.foldedHeadings.remove(node.foldKey) } else { project.foldedHeadings.insert(node.foldKey) }
                })) {
                    OutlineRows(nodes: children, project: project, showSource: showSource)
                } label: {
                    heading(node.item)
                }
            } else {
                heading(node.item)
            }
        }
    }

    private func heading(_ item: OutlineItem) -> some View {
        Button {
            showSource()
            project.reveal(item)
        } label: {
            Text(item.title).lineLimit(1).foregroundStyle(item.untitled ? .secondary : .primary)
        }
        .listRowBackground(item.id == project.currentHeading ? Color.accentColor.opacity(0.12) : nil)
        .accessibilityValue(item.level)
        .accessibilityAddTraits(item.id == project.currentHeading ? .isSelected : [])
    }
}

private struct SearchResults: View {
    let project: ProjectModel
    let showSource: () -> Void

    var body: some View {
        @Bindable var search = project.search
        List {
            Section {
                HStack {
                    TextField("Replace With", text: $search.replacement)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Replace All") { Task { await project.replaceAll() } }
                        .disabled(project.search.hitCount == 0)
                }
            }
            ForEach(project.search.groups ?? []) { group in
                Section {
                    ForEach(group.hits) { hit in
                        Button {
                            showSource()
                            Task { await project.open(hit.file, line: hit.line, column: hit.column, length: hit.length) }
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)").lineLimit(2)
                                Spacer(minLength: 4)
                                Text("\(hit.line)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                    .accessibilityLabel("Line \(hit.line)")
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    HStack {
                        Text(group.file).truncationMode(.middle)
                        Spacer()
                        Text(group.hits.count, format: .number).monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if let failure = project.search.failure {
                ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass", description: Text(failure))
            } else if project.search.groups?.isEmpty == true {
                ContentUnavailableView.search(text: project.search.searched)
            }
        }
    }
}
