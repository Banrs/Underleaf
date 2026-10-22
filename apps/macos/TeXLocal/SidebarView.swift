import SwiftUI

struct FilesList: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @State private var selection: String?
    @State private var hit: SearchHit.ID?
    @State private var rename = InPlaceRename<String>()
    @FocusState private var listFocused: Bool

    var body: some View {
        // The File Outline's header is the files' bottom bar, as high as the pane's bottom safe area.
        GeometryReader { geometry in
            // Two lists: one diffed from the tree to grouped hits and back keeps stale rows.
            Group { if project.search.isSearching { results } else { files } }
                .modifier(HeaderEdge(height: geometry.safeAreaInsets.bottom))
        }
        // Each search reads every file: it waits for typing to pause.
        .task(id: project.search.query) {
            if project.search.isSearching { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            await project.search.run(in: project.session)
            // VoiceOver hears the count, as it does the PDF's find count.
            guard !Task.isCancelled, project.search.groups != nil, project.search.failure == nil else { return }
            let count = project.search.hitCount
            project.notices.announce(count == 0 ? String(localized: "Not found") : matches(count), queued: true)
        }
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
            // None for no row: SwiftUI's asks AppKit for row -1's view, which raises (27.2).
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
            rename.begin(path, name: path.fileName)
        }
    }

    private func actions(_ node: TreeNode) -> ItemActions {
        ItemActions(rename: { rename.begin(node.path, name: node.name) },
                    showInFinder: { project.showInFinder(node.path) },
                    moveToTrash: { Task { await project.deleteEntry(node.path) } })
    }

    private var results: some View {
        List(selection: $hit) {
            ForEach(project.search.groups ?? []) { group in
                Section {
                    ForEach(group.hits) { hit in
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
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    HStack {
                        Text(group.file).truncationMode(.middle)
                        Spacer()
                        Text(group.hits.count, format: .number).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(group.file), \(matches(group.hits.count))")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Search Results")
        // A new query can reuse a hit's ID: the first click on the new hit opens it.
        .onChange(of: project.search.query, initial: true) { hit = nil }
        .onChange(of: hit) { _, id in open(id, focus: false) }
        .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in open(ids.first, focus: true) }
        // Usages aren't the query's matches, which Replace All would replace.
        .safeAreaBar(edge: .top, spacing: 0) {
            if let usages = project.search.usages {
                Text(String(localized: "Usages of \(usages.name)"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            } else {
                replaceBar
            }
        }
        .overlay {
            if let failure = project.search.failure {
                ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass",
                                       description: Text(failure))
            } else if project.search.groups?.isEmpty == true {
                ContentUnavailableView.search(text: project.search.searched)
            }
        }
    }

    /// Under the search field, as Xcode's Find navigator in Replace mode, at the inset and spacing the field's accessory has
    /// (measured, 27.2).
    private var replaceBar: some View {
        HStack {
            SearchField(text: Bindable(project.search).replacement, prompt: "Replace With", symbol: "arrow.2.squarepath")
            Button("Replace All") { Task { await project.replaceAll() } }
                .disabled(project.search.hitCount == 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
    }

    private func open(_ id: SearchHit.ID?, focus: Bool) {
        if let found = project.search.groups?.lazy.flatMap(\.hits).first(where: { $0.id == id }) {
            Task { await project.open(found.file, line: found.line, column: found.column, length: found.length, focus: focus, jump: true) }
        }
    }

    private func matches(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) match](inflect: true)").characters)
    }

    private func row(_ node: TreeNode) -> some View {
        let isMain = node.main == true
        return Label {
            HStack {
                if rename.id == node.path {
                    RenameField(text: $rename.name, isFile: !node.isDirectory, forbidden: "/", ended: { listFocused = true }) {
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

private struct TreeRows<Node: Identifiable, Row: View>: View {
    let nodes: [Node]
    let children: (Node) -> [Node]?
    let isExpanded: (Node) -> Binding<Bool>
    var insert: (([URL]) -> Void)?
    @ViewBuilder let row: (Node) -> Row

    var body: some View {
        let rows = ForEach(nodes) { node in
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
        if let insert {
            rows.dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                if !files.isEmpty { insert(files) }
            }
        } else {
            rows
        }
    }
}

/// Not a `Binding` of the set: two changes in one click would each start from the set as it was. Option takes the
/// `subtree`'s keys with it (HIG, Outline views).
private func disclosure(_ set: ReferenceWritableKeyPath<ProjectModel, Set<String>>, of project: ProjectModel, key: String,
                        inverted: Bool = false, subtree: @autoclosure @escaping () -> [String]) -> Binding<Bool> {
    Binding(get: { project[keyPath: set].contains(key) != inverted },
            set: { on in
                let keys = NSEvent.modifierFlags.contains(.option) ? [key] + subtree() : [key]
                if on != inverted { project[keyPath: set].formUnion(keys) } else { project[keyPath: set].subtract(keys) }
            })
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
                    HeadingRow(item: node.item, words: app.showWordCount ? node.words : nil).equatable().tag(node.id)
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

/// The system's collapsible sidebar section with no rows, at the files' foot; its whole row folds and unfolds, level with
/// the status bar.
struct OutlineHeader: View {
    @Environment(AppModel.self) private var app

    /// A sidebar section header's row (measured, 27.2).
    private static let row: CGFloat = 19
    /// Centred in the status bar's height, as folded, and kept there open.
    private static let top = (BarMetrics.height - row) / 2
    static let openHeight = top + row

    var body: some View {
        let expanded = Binding(get: { app.outlineOpen(of: app.project) }, set: { app.outlineCollapsed = !$0 })
        List {
            Section(isExpanded: expanded) {
            } header: {
                Button { expanded.wrappedValue.toggle() } label: {
                    Text("File Outline")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // It covers the system's disclosure.
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            }
        }
        .listStyle(.sidebar)
        .disabled(app.project?.isLaTeX != true)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: sidebarListRoom + Self.row + sidebarListRoom, alignment: .top)
        // AppKit animates the bar's height with the split; the header keeps its size and place.
        .offset(y: Self.top - sidebarListRoom)
        .frame(height: Self.openHeight, alignment: .top)
        .clipped()
    }
}

/// The room a sidebar list leaves over its first row, inside its table (27.2), which `contentMargins` doesn't reach.
private let sidebarListRoom: CGFloat = 10

/// Equatable: as a plain view, a heading that takes the place of a leaf and has subheadings opens closed (27.2).
private struct HeadingRow: View, Equatable {
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
