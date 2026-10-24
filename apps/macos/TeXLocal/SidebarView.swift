import SwiftUI

struct FilesList: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @State private var selection: String?
    @State private var rename = InPlaceRename<String>()
    /// A file just made, whose name once given goes on to its text, as Xcode's New File does.
    @State private var created: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        // The File Outline's header is the files' bottom bar, as high as the pane's bottom safe area.
        GeometryReader { geometry in
            // Two lists: one diffed from the tree to grouped hits and back keeps stale rows.
            Group { if project.search.isSearching { SearchResults(project: project) } else { files } }
                .modifier(HeaderEdge(height: geometry.safeAreaInsets.bottom))
        }
        .searching(project)
        .onChange(of: app.newEntry, initial: true) { _, entry in
            // A project left for another still shows while the next loads, whose list takes the entry.
            guard let entry, !project.closed else { return }
            app.newEntry = nil
            create(entry)
        }
    }

    private var files: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Section("Files") {
                    TreeRows(nodes: project.tree.nodes, children: \.children, isExpanded: { node in
                        disclosure(\.expandedFolders, of: project, key: node.path,
                                   subtree: node.children?.flattened.filter(\.isDirectory).map(\.path) ?? [])
                    }, insert: { urls in Task { await project.dropFiles(urls, into: "") } }) { node in
                        row(node).tag(node.path)
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Files")
            .fileDrop(moves: { project.projectPath($0) != nil }) { urls in
                Task { await project.dropFiles(urls, into: "") }
            }
            .overlay {
                if project.initialLoadComplete, project.tree.nodes.isEmpty {
                    ContentUnavailableView {
                        Label("No Files", systemImage: "text.document")
                    } description: {
                        Text("Create a file, or drag files here from the Finder.")
                    } actions: {
                        Button(MenuCommand.fileNew.title) { create(NewEntry(directory: false, folder: "")) }
                        Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload, on: project) }
                    }
                }
            }
            // None for no row: SwiftUI's would ask AppKit for row -1's view, which raises.
            .contextMenu(forSelectionType: String.self) { paths in
                if let path = paths.first, let node = project.tree.node(at: path) {
                    if node.isDirectory {
                        Button(MenuCommand.fileNew.title) { create(NewEntry(directory: false, folder: node.path)) }
                        Button(MenuCommand.fileNewFolder.title) { create(NewEntry(directory: true, folder: node.path)) }
                        Divider()
                    } else if node.kind == .tex {
                        Button("Set as Main File") { Task { await project.patchSettings(.mainFile(node.path)) } }
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
                Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload, on: project) }
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
            // Return renames after the key event, through which the list keeps the keyboard from the field.
            .onKeyPress(.return) {
                guard rename.id == nil, let node = selection.flatMap({ project.tree.node(at: $0) }) else { return .ignored }
                Task { actions(node).rename?() }
                return .handled
            }
            .focused($listFocused)
            .offersActions(for: listFocused && rename.id == nil ? selection : nil) { path in project.tree.node(at: path).map(actions) }
            // The list makes only the rows it shows.
            .onChange(of: rename.id) { _, id in if let id { Task { proxy.scrollTo(id) } } }
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
        if project.search.isSearching { project.search.query = "" }
        Task {
            guard let path = await project.createEntry(in: folder, directory: entry.directory) else { return }
            showRow(path)
            selection = path
            created = entry.directory ? nil : path
            rename.begin(path, name: path.fileName)
        }
    }

    private func actions(_ node: TreeNode) -> ItemActions {
        ItemActions(rename: { rename.begin(node.path, name: node.name) },
                    showInFinder: { project.url(node.path).map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } },
                    moveToTrash: { Task { await project.deleteEntry(node.path) } })
    }

    private func row(_ node: TreeNode) -> some View {
        let isMain = node.main == true
        return Label {
            HStack {
                if rename.id == node.path {
                    RenameField(text: $rename.name, isFile: !node.isDirectory, forbidden: "/", ended: { renameEnded(node) }) {
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
        } icon: { Image(systemName: node.symbol) }
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
        if created == node.path { project.editor.focus() } else { listFocused = true }
        created = nil
    }

    private func commitRename(_ node: TreeNode) {
        guard let name = rename.end(node.path, from: node.name) else { return }
        // The field refuses a "/" as it is typed; one may get by.
        guard !name.contains("/") else {
            app.alert = AppAlert("Couldn’t Rename “\(node.name)”", "File and folder names can’t contain “/”.")
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
            // A drop session names none of its items until they're dropped.
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

/// The main file's sections, under `OutlineHeader`, which folds them away. Takes no drops: files go into the list above.
struct OutlineList: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @Environment(\.sidebarRowSize) private var rowSize
    @State private var chosen: Int?

    var body: some View {
        let outline = project.outline
        let current = project.currentHeading
        // A list sends nothing for a click on the row already selected, so the rows tap for it.
        let selection = Binding<Int?>(get: { chosen ?? current }, set: { id in
            guard let id, id != current, outline.indices.contains(id) else { return }
            chosen = id
            project.reveal(outline[id])
        })
        ScrollViewReader { proxy in
            List(selection: selection) {
                TreeRows(nodes: project.outlineTree, children: \.children, isExpanded: { node in
                    disclosure(\.foldedHeadings, of: project, key: node.foldKey, inverted: true, subtree: node.descendants.map(\.foldKey))
                }) { node in
                    HeadingRow(item: node.item, words: app.showWordCount ? node.words : nil).tag(node.id)
                        // A double-click's second click is the list's primary action, into the source.
                        .simultaneousGesture(TapGesture().onEnded {
                            guard NSApp.currentEvent?.clickCount ?? 1 < 2, node.id == current || node.id == chosen else { return }
                            chosen = node.id == current ? nil : node.id
                            project.reveal(node.item)
                        })
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("File Outline")
            // The header above stands for a section's: the room over the first row goes.
            .contentMargins(.top, sidebarListRoom, for: .scrollIndicators)
            .padding(.top, -sidebarListRoom)
            .clipped()
            // A step under the files' rows.
            .environment(\.sidebarRowSize, rowSize == .large ? .medium : .small)
            .overlay { if outline.isEmpty { ContentUnavailableView("No Sections", systemImage: "list.bullet.indent") } }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
                guard let id = ids.first, outline.indices.contains(id) else { return }
                let item = outline[id]
                Task { await project.open(item.file, line: item.line, atTop: true, focus: true, jump: true) }
            }
            .onChange(of: current, initial: true) { _, id in
                chosen = nil
                guard let id else { return }
                Task { proxy.scrollTo(id) }
            }
        }
    }
}

/// A sidebar section's header at the files' foot, level with the status bar: its whole row folds and unfolds the outline,
/// and its chevron shows under the pointer, as a sidebar section's does.
struct OutlineHeader: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let open = app.outlineOpen(of: app.project)
        Button { app.outlineCollapsed = open } label: {
            HStack {
                Text("File Outline")
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .opacity(hovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            // Level with the Files section's header above (measured), the chevron where AppKit puts a section's.
            .padding(.leading, 14)
            .padding(.trailing, 18)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(app.project?.isLaTeX != true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

/// The room a sidebar list leaves over its first row, inside its table (measured), which `contentMargins` doesn't reach: the
/// header above stands for it.
private let sidebarListRoom: CGFloat = 10

private struct HeadingRow: View {
    let item: OutlineItem
    /// While the status bar counts the document's.
    let words: Int?

    var body: some View {
        HStack {
            Text(item.title)
                .help(item.title)
                .foregroundStyle(item.untitled ? .secondary : .primary)
            if let words {
                Spacer(minLength: 4)
                Text(words, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("^[\(words) word](inflect: true)")
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.level)
        // For scrollTo, inside the row: on it, the list would take it for the row's identity.
        .id(item.id)
    }
}

/// The header's hard edge on the files, in place of its accessory's, which would double it. SwiftUI draws the edge only
/// under a bar that draws something, so the bar is a fill the eye can't see.
struct HeaderEdge: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .bottom, spacing: 0) { Rectangle().fill(.white.opacity(0.001)).frame(height: height) }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .scrollEdgeEffectHidden(height == 0, for: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}
