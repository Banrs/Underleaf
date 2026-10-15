import SwiftUI

struct FilesList: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @State private var selection: String?
    @State private var hit: SearchHit.ID?
    @State private var rename = InPlaceRename<String>()
    @FocusState private var listFocused: Bool

    var body: some View {
        // The File Outline's header is the files' bottom bar: their bottom safe area follows its height as it folds.
        GeometryReader { geometry in
            // Two lists: one list diffed from the tree to grouped hits and back keeps stale rows.
            Group { if project.search.isSearching { results } else { files } }
                .modifier(HeaderEdge(height: geometry.safeAreaInsets.bottom))
        }
            // Each search reads every file in the project; it waits for typing to pause.
            .task(id: project.search.query) {
                if project.search.isSearching { try? await Task.sleep(for: PDFFind.debounce) }
                guard !Task.isCancelled else { return }
                await project.search.run()
                // The list changes without a word: VoiceOver hears the count, as it does the PDF's find count.
                guard !Task.isCancelled, let hits = project.search.hits, project.search.failure == nil else { return }
                var spoken = hits.isEmpty ? AttributedString(localized: "Not found")
                    : AttributedString(localized: "^[\(hits.count) match](inflect: true)")
                spoken.accessibilitySpeechAnnouncementPriority = .low
                AccessibilityNotification.Announcement(spoken).post()
            }
            .onChange(of: app.newEntry, initial: true) { _, entry in
                guard let entry else { return }
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
                    },
                             insert: { urls in Task { await project.dropFiles(urls, into: "") } }) { node in
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
                    } else if isLaTeXFile(node.path) {
                        Button("Set as Main File") { Task { await project.setMainFile(node.path) } }
                            .disabled(node.path == project.settings?.mainFile)
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
                        await project.open(path, focus: false)
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
                Task { actions(node).rename() }
                return .handled
            }
            .focused($listFocused)
            .offersActions(for: listFocused && rename.id == nil ? selection : nil) { path in
                project.tree.node(at: path).map(actions)
            }
            // A row named in place comes into view first: the list makes only the rows it shows.
            .onChange(of: rename.id) { _, id in
                if let id { Task { proxy.scrollTo(id) } }
            }
        }
    }

    private func showRow(_ path: String) {
        var folder = path.parentFolder
        while !folder.isEmpty { project.expandedFolders.insert(folder); folder = folder.parentFolder }
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
        List(selection: $hit) { searchResults }
            .listStyle(.sidebar)
            .accessibilityLabel("Search Results")
            // A new query can reuse a file/line ID: clear the old selection so the first click on the new hit opens it.
            .onChange(of: project.search.query, initial: true) { hit = nil }
            .onChange(of: hit) { _, id in open(id, focus: false) }
            .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in open(ids.first, focus: true) }
            .overlay {
                if let failure = project.search.failure {
                    ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(failure))
                } else if project.search.hits?.isEmpty == true {
                    ContentUnavailableView.search(text: project.search.searched)
                }
            }
    }

    private func open(_ id: SearchHit.ID?, focus: Bool) {
        if let found = project.search.hits?.first(where: { $0.id == id }) {
            Task { await project.open(found.file, line: found.line, focus: focus) }
        }
    }

    private var searchResults: some View {
        ForEach(project.search.groups) { group in
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
                .accessibilityLabel("\(group.file), \(String(AttributedString(localized: "^[\(group.hits.count) match](inflect: true)").characters))")
            }
        }
    }

    private func row(_ node: TreeNode) -> some View {
        let isMain = node.path == project.settings?.mainFile
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
        } icon: {
            Image(systemName: fileSymbol(node.path, directory: node.isDirectory))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        // The star's name too: the row's label replaces its children's.
        .accessibilityLabel(isMain ? "\(node.name), Main File" : node.name)
        .fileDrop(moves: { project.projectPath($0) != nil }) { urls in
            let folder = node.isDirectory ? node.path : node.path.parentFolder
            Task { await project.dropFiles(urls, into: folder) }
        }
        .draggable(file: project.url(node.path))
    }

    private func commitRename(_ node: TreeNode) {
        guard let name = rename.end(node.path, from: node.name) else { return }
        // The field refuses a "/" as it is typed; this is for one that got by.
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

/// Not a `Binding` of the set: two changes in one click would each start from the set as it was. With Option held the
/// `subtree`'s keys go with it (HIG, Outline views).
private func disclosure(_ set: ReferenceWritableKeyPath<ProjectModel, Set<String>>, of project: ProjectModel, key: String,
                        inverted: Bool = false, subtree: @autoclosure @escaping () -> [String]) -> Binding<Bool> {
    Binding(get: { project[keyPath: set].contains(key) != inverted },
            set: { on in
                let keys = NSEvent.modifierFlags.contains(.option) ? [key] + subtree() : [key]
                if on != inverted { project[keyPath: set].formUnion(keys) } else { project[keyPath: set].subtract(keys) }
            })
}

#Preview("File tree") {
    @Previewable @State var expanded: Set<String> = ["figures"]
    let file = { (path: String) in TreeNode(type: "file", name: path.fileName, path: path, children: nil) }
    List {
        Section("Files") {
            TreeRows(nodes: [
                TreeNode(type: "dir", name: "figures", path: "figures",
                         children: [file("figures/plot.pdf"), file("figures/diagram.png")]),
                file("main.tex"), file("references.bib"),
            ], children: \.children, isExpanded: { node in
                Binding(get: { expanded.contains(node.path) }, set: { if $0 { expanded.insert(node.path) } else { expanded.remove(node.path) } })
            }) { node in
                Label(node.name, systemImage: fileSymbol(node.path, directory: node.isDirectory))
            }
        }
    }
    .listStyle(.sidebar)
    .frame(width: ColumnMetrics.sidebarIdeal, height: 240)
}

extension View {
    func fileDrop(accepts: @escaping (URL) -> Bool = { _ in true }, moves: @escaping (URL) -> Bool = { _ in false },
                  action: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && accepts($0) }
            if !files.isEmpty { action(files) }
        }
        .dropConfiguration { _ in
            // AppKit's drag pasteboard: a drop session names none of its items until they're dropped.
            let urls = (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(accepts)
            var configuration = DropConfiguration(operation: urls.isEmpty ? .forbidden : urls.allSatisfy(moves) ? .move : .copy)
            if !urls.isEmpty { configuration.acceptedItemCount = urls.count }
            return configuration
        }
    }

    @ViewBuilder
    func draggable(file url: URL?) -> some View {
        if let url {
            draggable(url).dragConfiguration(DragConfiguration(operationsWithinApp: .init(allowMove: true)))
        } else {
            self
        }
    }
}

struct OutlineList: View {
    let project: ProjectModel
    /// The caret's line when both change, as its `onChange` runs second.
    @State private var line = 1

    var body: some View {
        // The rows only when the current heading changes, not at each line the caret moves to.
        OutlineRows(project: project, current: Outline.current(project.outline, file: project.openPath, line: line))
            .onChange(of: project.topHeading) { line = project.topLine }
            .onChange(of: project.cursorLine, initial: true) { _, cursor in line = cursor }
    }
}

private struct OutlineRows: View {
    let project: ProjectModel
    let current: Int?
    @Environment(\.sidebarRowSize) private var rowSize
    @State private var chosen: Int?

    var body: some View {
        let outline = project.outline
        // A list sends nothing for a click on the row already selected, so the rows tap for those two.
        let selection = Binding<Int?>(get: { chosen ?? current }, set: { id in
            guard let id, id != current, outline.indices.contains(id) else { return }
            chosen = id
            project.reveal(outline[id])
        })
        ScrollViewReader { proxy in
            List(selection: selection) {
                TreeRows(nodes: Outline.tree(outline), children: \.children, isExpanded: { node in
                    disclosure(\.foldedHeadings, of: project, key: node.foldKey, inverted: true, subtree: node.descendants.map(\.foldKey))
                }) { node in
                    HeadingRow(item: node.item).equatable().tag(node.id)
                        // A click on the selected row shows it again; a double-click's second is the list's primary action, which goes into the source.
                        .simultaneousGesture(TapGesture().onEnded {
                            guard NSApp.currentEvent?.clickCount ?? 1 < 2, node.id == current || node.id == chosen else { return }
                            chosen = node.id == current ? nil : node.id
                            project.reveal(node.item)
                        })
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("File Outline")
            .contentMargins(.top, sidebarListRoom, for: .scrollIndicators)
            .padding(.top, -sidebarListRoom)
            .clipped()
            .environment(\.sidebarRowSize, rowSize == .large ? .medium : .small)
            .overlay {
                if outline.isEmpty { ContentUnavailableView("No Sections", systemImage: "list.bullet.indent") }
            }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
                guard let id = ids.first, outline.indices.contains(id) else { return }
                let item = outline[id]
                Task { await project.open(item.file, line: item.line, atTop: true, focus: true) }
            }
            .onChange(of: current, initial: true) { _, id in
                chosen = nil
                guard let id else { return }
                Task { proxy.scrollTo(id) }
            }
        }
    }
}

/// The system's collapsible sidebar section (it folds, shows its chevron on hover, and its button gives VoiceOver the
/// state), with no rows, at the files' foot so it stays put over the outline.
struct OutlineHeader: View {
    @Environment(AppModel.self) private var app

    /// A sidebar section header's row on 27.2.
    private static let row: CGFloat = 19
    private static let top = (BarMetrics.height - row) / 2
    static let openHeight = top + row

    var body: some View {
        // A file that isn't LaTeX has no outline to open: the header stays, folded and dim.
        let outlined = app.project?.isLaTeX == true
        let expanded = Binding(get: { outlined && !app.outlineCollapsed }, set: { app.outlineCollapsed = !$0 })
        List {
            Section(isExpanded: expanded) {
            } header: {
                Button { expanded.wrappedValue.toggle() } label: {
                    Text("File Outline")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // The button covers the system's disclosure, so it tells VoiceOver the state.
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            }
        }
        .listStyle(.sidebar)
        .disabled(!outlined)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: sidebarListRoom + Self.row + sidebarListRoom, alignment: .top)
        .offset(y: Self.top - sidebarListRoom)
        .frame(height: Self.openHeight, alignment: .top)
        .clipped()
    }
}

/// The room a sidebar list leaves over its first row and under its last, inside its table (27.2); `contentMargins` doesn't reach it.
private let sidebarListRoom: CGFloat = 10

/// Equatable: as a plain view, a heading that takes the place of a leaf and has subheadings opens closed (27.2).
private struct HeadingRow: View, Equatable {
    let item: OutlineItem

    var body: some View {
        Text(item.displayTitle)
            .lineLimit(1)
            .help(item.displayTitle)
            .foregroundStyle(item.isUntitled ? .secondary : .primary)
            .accessibilityValue(item.kind)
            // For scrollTo, inside the row: on it, the list would take it for the row's identity, and a heading that gains subheadings would keep a leaf's closed state.
            .id(item.id)
    }
}

/// The hard edge where the header is, in place of the one the accessory gives the pane, which would double it. SwiftUI
/// draws the edge only under a bar that draws something itself (not `Color.clear`, a `Spacer` or a hidden view), so the
/// blank bar is a fill the eye can't see.
struct HeaderEdge: ViewModifier {
    let height: CGFloat
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .bottom, spacing: 0) { Rectangle().fill(.white.opacity(0.001)).frame(height: height) }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .scrollEdgeEffectHidden(height == 0, for: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
            // 27.2: the hard edge's line is a device pixel in the separator's colour and the window's lines are a point: the rest of the point goes over it.
            .overlay(alignment: .bottom) {
                if height > 0, displayScale > 1 {
                    Rectangle().fill(.separator)
                        .frame(height: BarMetrics.line - 1 / displayScale)
                        .padding(.bottom, 1 / displayScale)
                        .allowsHitTesting(false)
                }
            }
    }
}
