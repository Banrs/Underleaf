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

    var body: some View {
        // The File Outline's header is the files' bottom bar: they scroll on beneath it, under
        // SwiftUI's hard edge and its hairline. Its height is the pane's bottom safe area, which
        // follows the header's as it folds.
        GeometryReader { geometry in
            // Two lists: one list diffed from the tree to grouped hits and back keeps stale rows.
            Group { if project.isSearching { results } else { files } }
                .modifier(HeaderEdge(height: geometry.safeAreaInsets.bottom))
        }
            // Each search reads every file in the project; it waits for typing to pause.
            .task(id: project.searchQuery) {
                if project.isSearching { try? await Task.sleep(for: PDFFind.debounce) }
                if !Task.isCancelled { await project.search() }
            }
            // File › New File and New Folder, taken once.
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
                    // Between the top-level rows, into the project's top level.
                    TreeRows(nodes: project.tree, children: \.children, isExpanded: { node in
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
            // The blank space below the rows is the project's top level, as in Finder; the
            // rows' own drops are the innermost.
            .fileDrop(moves: { project.projectPath($0) != nil }) { urls in
                Task { await project.dropFiles(urls, into: "") }
            }
            .overlay {
                if project.initialLoadComplete, project.tree.isEmpty {
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
            // The clicked row's menu, which leaves the selection (and the open file) as
            // it is. None for no row: SwiftUI's asks AppKit for row -1's view, which raises (27.2).
            .contextMenu(forSelectionType: String.self) { paths in
                if let path = paths.first, let node = project.node(at: path) {
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
                // A folder opens or closes; a file is already open once chosen.
                guard let path = paths.first, project.node(at: path)?.isDirectory == true else { return }
                if project.expandedFolders.remove(path) == nil { project.expandedFolders.insert(path) }
            }
            // The empty space's: the project's top level's, as a Finder window's background
            // has its folder's.
            .contextMenu {
                Button(MenuCommand.fileNew.title) { create(NewEntry(directory: false, folder: "")) }
                Button(MenuCommand.fileNewFolder.title) { create(NewEntry(directory: true, folder: "")) }
                Divider()
                Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload, on: project) }
            }
            .onChange(of: selection) { _, path in
                if let path, path != project.openPath, project.node(at: path)?.isDirectory == false {
                    Task {
                        await project.open(path, focus: false)
                        // It didn't open (reported): the file on screen stays chosen.
                        if project.openPath != path, selection == path { selection = project.openPath }
                    }
                }
            }
            .onChange(of: project.openPath, initial: true) { _, path in
                selection = path
                if let path { showRow(path) }
            }
            // Return renames the chosen item, as in Finder: after the key event, through
            // which the list keeps the keyboard from the field.
            .onKeyPress(.return) {
                guard rename.id == nil, let node = selection.flatMap({ project.node(at: $0) }) else { return .ignored }
                Task { actions(node).rename() }
                return .handled
            }
            .focused($listFocused)
            .offersActions(for: listFocused && rename.id == nil ? selection : nil) { path in
                project.node(at: path).map(actions)
            }
            // A row named in place comes into view first: the list makes only the rows it shows.
            .onChange(of: rename.id) { _, id in
                if let id { Task { proxy.scrollTo(id) } }
            }
        }
    }

    /// Its folders open, so its row shows.
    private func showRow(_ path: String) {
        var folder = path.parentFolder
        while !folder.isEmpty { project.expandedFolders.insert(folder); folder = folder.parentFolder }
    }

    /// The chosen folder, or the chosen file's; the top level with neither.
    private var chosenFolder: String {
        guard let path = selection, let node = project.node(at: path) else { return "" }
        return node.isDirectory ? path : path.parentFolder
    }

    /// Made in the chosen folder, or the chosen file's, as Xcode makes a new file; then
    /// chosen with its name ready to type over, as Finder's New Folder is. Escape keeps it.
    private func create(_ entry: NewEntry) {
        let folder = entry.folder ?? chosenFolder
        // The files show it, not the search's results.
        if project.isSearching { project.searchQuery = "" }
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
                if let failure = project.searchFailure {
                    ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(failure))
                } else if project.searchHits?.isEmpty == true {
                    ContentUnavailableView.search(text: project.searchQuery)
                }
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
        ForEach(project.searchGroups) { group in
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
                    // One hit, its line and where on it, as one element.
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
        // The whole row a drop target, not only its name.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        // The star's name too: the row's label replaces its children's.
        .accessibilityLabel(isMain ? "\(node.name), Main File" : node.name)
        // Into the folder dropped on, or the dropped-on file's folder.
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
            // A renamed folder stays chosen, as in Finder; a file follows the open file.
            if selection == node.path, project.node(at: path) != nil { selection = path }
        }
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
        // Only the top rows take drops between them: the nested ones pass none.
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

/// A disclosure group's state, on while `set` of the project holds `key` (with `inverted`, while it
/// doesn't). With Option held the `subtree`'s keys go with it, as Option-clicking a disclosure
/// triangle opens or closes everything below (HIG, Outline views). Not a `Binding` of the set:
/// two changes in one click would each start from the set as it was.
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
    /// Takes the dropped files `accepts` takes, copied in or, those `moves` names,
    /// moved (as Finder does within a volume), and leaves the rest; the drag's badge
    /// counts the ones taken. A drag with none of them is refused while dragged.
    func fileDrop(accepts: @escaping (URL) -> Bool = { _ in true }, moves: @escaping (URL) -> Bool = { _ in false },
                  action: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && accepts($0) }
            if !files.isEmpty { action(files) }
        }
        .dropConfiguration { _ in fileDropConfiguration(accepts, moves) }
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

/// What a drop does with the dragged files `accepts` takes, and how many it takes.
/// AppKit's drag pasteboard: a drop session names none of its items until they're dropped.
private func fileDropConfiguration(_ accepts: (URL) -> Bool, _ moves: (URL) -> Bool) -> DropConfiguration {
    let urls = (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(accepts)
    var configuration = DropConfiguration(operation: urls.isEmpty ? .forbidden : urls.allSatisfy(moves) ? .move : .copy)
    if !urls.isEmpty { configuration.acceptedItemCount = urls.count }
    return configuration
}

/// The project's sections from its main file, in a pane under `OutlineHeader`, which
/// folds it away. Takes no drops: files go into the list above.
struct OutlineList: View {
    let project: ProjectModel
    @Environment(\.sidebarRowSize) private var rowSize
    /// The line the selection follows: the caret's or the top line, whichever
    /// changed last; the caret's when both do, as its `onChange` runs second.
    @State private var line = 1
    /// A heading chosen in the list, shown selected until the source reaches it.
    @State private var chosen: Int?

    var body: some View {
        let outline = project.outline
        let current = Outline.current(outline, file: project.openPath, line: line)
        // The current heading is the selection; choosing one, by click or arrow
        // key, scrolls the source to it and leaves the keyboard where it was. A list sends
        // nothing for a click on the row already selected, so the rows tap for those two.
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
                        // The selected row (the source's heading, or the one just chosen) is
                        // shown again, as when the source has been scrolled away; a click on
                        // any other is the selection's.
                        .simultaneousGesture(TapGesture().onEnded {
                            guard node.id == current || node.id == chosen else { return }
                            chosen = node.id == current ? nil : node.id
                            project.reveal(node.item)
                        })
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("File Outline")
            // The header above stands for a section's, so the list's room over its first
            // row goes; the scroller keeps to what shows.
            .contentMargins(.top, sidebarListRoom, for: .scrollIndicators)
            .padding(.top, -sidebarListRoom)
            .clipped()
            // A step under the files' rows: a table of contents under a list.
            .environment(\.sidebarRowSize, rowSize == .large ? .medium : .small)
            .overlay {
                if outline.isEmpty { ContentUnavailableView("No Sections", systemImage: "list.bullet.indent") }
            }
            // Return or a double-click goes into the source there, as in the search results.
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
                guard let id = ids.first, outline.indices.contains(id) else { return }
                let item = outline[id]
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

/// The File Outline's header: the system's collapsible sidebar section (so it folds and
/// shows its chevron on hover; its button gives VoiceOver the state), with no rows, at the
/// files' foot so it stays put over the outline. Its whole row folds and unfolds.
/// Folded, it lines up with the status bar; open, the first heading follows at the
/// Files section's own spacing.
struct OutlineHeader: View {
    @Environment(AppModel.self) private var app

    /// A sidebar section header's row (measured, 27.2).
    private static let row: CGFloat = 19
    /// Centred in the status bar's height, as folded, and kept there open.
    private static let top = (StatusBar.height - row) / 2
    static let openHeight = top + row

    var body: some View {
        let expanded = Binding(get: { !app.outlineCollapsed }, set: { app.outlineCollapsed = !$0 })
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
        // The sidebar's own material shows through, as behind the lists either side.
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: sidebarListRoom + Self.row + sidebarListRoom, alignment: .top)
        // AppKit animates the bar's height with the split; the header keeps one
        // size and one place under the line.
        .offset(y: Self.top - sidebarListRoom)
        .frame(height: Self.openHeight, alignment: .top)
        .clipped()
    }
}

/// The room a sidebar list leaves over its first row and under its last, inside its
/// table (measured, 27.2); `contentMargins` doesn't reach it.
private let sidebarListRoom: CGFloat = 10

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

/// The File Outline header's edge on the files: the hard edge where the header is, the header's
/// region the list's own, in place of the one its accessory gives the pane, which would double it.
/// The bar here is a blank the accessory's content sits over; SwiftUI draws the edge only under a
/// bar that draws something itself (measured 2026-10-06: not under `Color.clear`, a `Spacer` or a
/// hidden view, and only after a later layout, if at all), so the blank is a fill the eye can't see.
struct HeaderEdge: ViewModifier {
    /// The header's; none, no edge.
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .bottom, spacing: 0) { Rectangle().fill(.white.opacity(0.001)).frame(height: height) }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .scrollEdgeEffectHidden(height == 0, for: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}
