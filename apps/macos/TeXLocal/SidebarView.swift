import SwiftUI

/// The File Outline's header: the system's collapsible sidebar section (so it folds,
/// shows its chevron on hover and gives VoiceOver its state), with no rows, at the
/// Files pane's foot so it stays put over the outline. Its height stays level with
/// the status bar, whether the outline is folded or revealed.
struct OutlineHeader: View {
    @Environment(AppModel.self) private var app

    /// A sidebar section header's row (measured, 27.2).
    private static let headerRow: CGFloat = 19
    /// How far under the middle of the status bar's height the list puts the title
    /// (measured, 27.2): it's raised so the two bars' words are level and centred.
    private static let titleDrop: CGFloat = 1.5

    var body: some View {
        List {
            Section(isExpanded: Binding(get: { !app.outlineCollapsed }, set: { app.outlineCollapsed = !$0 })) {
            } header: {
                Text("File Outline")
            }
        }
        .listStyle(.sidebar)
        // The sidebar's own material shows through, as behind the lists either side.
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        // Its room under the header too, so a drag from the header has nothing to
        // autoscroll (scrollDisabled doesn't stop it); the bar shows its top.
        .frame(height: sidebarListRoom + Self.headerRow + sidebarListRoom, alignment: .top)
        .offset(y: -Self.titleDrop)
        .frame(height: BarMetrics.secondaryBarHeight, alignment: .top)
    }
}

/// The room a sidebar list leaves over its first row and under its last, inside
/// its table (measured, 27.2).
private let sidebarListRoom: CGFloat = 10

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
    /// Files dragged over the list's empty space, or over a row.
    @State private var listTargeted = false
    @State private var rowTargeted: TreeNode?

    var body: some View {
        // Two lists: one list diffed from the tree to grouped hits and back
        // kept stale rows.
        if project.isSearching { results } else { files }
    }

    /// The folder a drop would go into ("" the project's top level): the
    /// row's, or the folder of the file it's over.
    private var dropFolder: String? {
        rowTargeted.map { $0.isDirectory ? $0.path : ($0.path as NSString).deletingLastPathComponent }
            ?? (listTargeted ? "" : nil)
    }

    private var files: some View {
        List(selection: $selection) {
            Section {
                TreeRows(nodes: project.tree, expanded: $expanded) { node in
                    row(node).tag(node.path)
                }
            } header: {
                // The project's top level, as a row takes a drop into its folder: a List
                // hands a drop on its empty space to neither dropDestination nor onDrop
                // (27.2). Search results take none.
                Text("Files")
                    .headerDropHighlight(dropFolder == "")
                    .contentShape(.rect)
                    .fileDrop(moves: { project.projectPath($0) != nil }, targeted: { listTargeted = $0 }) { urls in
                        Task { await project.dropFiles(urls, into: "") }
                    }
            }
        }
        .listStyle(.sidebar)
        // The clicked row's menu, which leaves the selection (and the open file) as
        // it is; on the list's empty space, the list's own.
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first, let node = project.tree.flattened.first(where: { $0.path == path }) {
                if node.isDirectory {
                    Button(MenuCommand.fileNew.title) { app.prompt = .newFile(in: node.path) }
                    Button(MenuCommand.fileNewFolder.title) { app.prompt = .newFolder(in: node.path) }
                    Divider()
                } else if node.path.hasSuffix(".tex") {
                    Button("Set as Main File") { Task { await project.setMainFile(node.path) } }
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
        .onChange(of: project.openPath, initial: true) { _, path in selection = path }
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

    /// Choosing a hit opens it; double-clicking or Return opens the chosen one again.
    private var results: some View {
        List(selection: $hit) { searchResults }
            .listStyle(.sidebar)
            .onChange(of: hit) { _, id in open(id) }
            .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in open(ids.first) }
            .overlay {
                if project.searchHits?.isEmpty == true { ContentUnavailableView.search(text: project.searchQuery) }
            }
    }

    private func open(_ id: SearchHit.ID?) {
        if let found = project.searchHits?.first(where: { $0.id == id }) {
            Task { await project.open(found.file, line: found.line) }
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
                        Spacer(minLength: BarMetrics.spacing)
                        Text("\(hit.line)")
                            .font(Typography.secondary)
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
                        .accessibilityLabel("Main File")
                }
            }
        } icon: {
            Image(systemName: fileSymbol(node.path, directory: node.isDirectory))
        }
        // The whole row a drop target, not only its name.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .dropHighlight(node.isDirectory && dropFolder == node.path)
        // The star's name too: the row's label replaces its children's.
        .accessibilityLabel(isMain ? "\(node.name), Main File" : node.name)
        // Into the folder dropped on, or the dropped-on file's folder.
        .fileDrop(moves: { project.projectPath($0) != nil }, targeted: { over in
            if over { rowTargeted = node } else if rowTargeted?.path == node.path { rowTargeted = nil }
        }) { urls in
            let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
            Task { await project.dropFiles(urls, into: folder) }
        }
        .draggable(file: project.url(node.path))
    }

    private func commitRename(_ node: TreeNode) {
        guard let name = rename.end(node.path, from: node.name), !name.contains("/") else { return }
        let folder = (node.path as NSString).deletingLastPathComponent
        Task { await project.renameEntry(node.path, to: folder.isEmpty ? name : "\(folder)/\(name)") }
    }
}

/// The file tree, each folder open or closed as `expanded` has it.
private struct TreeRows<Row: View>: View {
    let nodes: [TreeNode]
    @Binding var expanded: Set<String>
    @ViewBuilder let row: (TreeNode) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(node.path) },
                    set: { open in
                        if open { expanded.insert(node.path) } else { expanded.remove(node.path) }
                    }
                )) {
                    TreeRows(nodes: children, expanded: $expanded, row: row)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
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
            ], expanded: $expanded) { node in
                Label(node.name, systemImage: fileSymbol(node.path, directory: node.isDirectory))
            }
        }
    }
    .listStyle(.sidebar)
    .frame(width: ColumnMetrics.sidebarIdeal, height: 240)
}

/// The sidebar's selection capsule. UI kit Sidebars/Small/Items/Level 0 - Selected:
/// background x −4, width row+8, radius 8; inset measured on 27.2.
private nonisolated enum SidebarSelection {
    static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    /// From each side of the list to the capsule.
    static let inset: CGFloat = 10
    /// The capsule reaches this far before a row's content.
    static let leading: CGFloat = 4
    /// Above and below a header's content, to a row's height (27.2).
    static let vertical: CGFloat = 2
    /// Where a header's content ends, short of the sidebar's edge (27.2).
    static let contentTrailing: CGFloat = 2
}

/// A row's content outlined as the sidebar's selection is.
/// Nonisolated: SwiftUI may ask a shape for its path off the main thread.
private nonisolated struct SidebarRowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = SidebarSelection.self
        let row = CGRect(x: rect.minX - s.leading, y: rect.minY - s.vertical,
                         width: rect.width + s.leading - (s.inset - s.contentTrailing),
                         height: rect.height + 2 * s.vertical)
        return s.shape.path(in: row)
    }
}

private extension View {
    /// A row where a drop would go, tinted a level under a selection so its
    /// text keeps its colours.
    func dropHighlight(_ isOn: Bool) -> some View {
        listRowBackground(isOn ? SidebarSelection.shape.fill(.tint.quaternary)
            .padding(.horizontal, SidebarSelection.inset) : nil)
    }

    /// The same for a section's header, which a list gives no row background.
    func headerDropHighlight(_ isOn: Bool) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isOn { SidebarRowShape().fill(.tint.quaternary) }
            }
    }
}

extension View {
    /// Takes dropped files, copied in or, those `moves` names, moved (as Finder
    /// does within a volume); anything else, or a file `accepts` turns down, is
    /// refused while dragged. `targeted`: a taken drag is over it.
    func fileDrop(accepts: @escaping (URL) -> Bool = { _ in true }, moves: @escaping (URL) -> Bool = { _ in false },
                  targeted: @escaping (Bool) -> Void, action: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            targeted(false)
            let files = urls.filter { $0.isFileURL && accepts($0) }
            if !files.isEmpty { action(files) }
        }
        .dropConfiguration { _ in DropConfiguration(operation: dropOperation(accepts, moves)) }
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering, .active: targeted(dropOperation(accepts, moves) != .forbidden)
            default: targeted(false)
            }
        }
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
private func dropOperation(_ accepts: (URL) -> Bool, _ moves: (URL) -> Bool) -> DropOperation {
    let urls = (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(accepts)
    return urls.isEmpty ? .forbidden : urls.allSatisfy(moves) ? .move : .copy
}

/// The open document's sections, under `OutlineHeader`, which folds them away.
/// Takes no drops: files go into the list above.
struct OutlineList: View {
    let project: ProjectModel
    @Environment(\.sidebarRowSize) private var rowSize
    /// Folded headings, by file and `Outline.foldKeys`.
    @State private var folded = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.outlineFolded) ?? [])
    /// The line the selection follows: the caret's or the top line, whichever
    /// changed last.
    @State private var line = 1
    /// A heading chosen in the list, shown selected until the source reaches it.
    @State private var chosen: Int?

    /// A step under the files' rows: a table of contents under a list.
    private var outlineRowSize: SidebarRowSize { rowSize == .large ? .medium : .small }

    private var prefix: String { "\(project.id)/\(project.openPath ?? "")\t" }

    var body: some View {
        let outline = project.outline
        let current = Outline.chain(outline, at: line).last?.id
        let keys = Outline.foldKeys(outline).map { prefix + $0 }
        // The current heading is the selection; choosing one, by click or arrow
        // key, scrolls the source to it and leaves the keyboard where it was.
        let selection = Binding<Int?>(get: { chosen ?? current }, set: { id in
            guard let id, id != (chosen ?? current), let item = outline.first(where: { $0.id == id }) else { return }
            chosen = id
            project.reveal(item)
        })
        ScrollViewReader { proxy in
            List(selection: selection) {
                if outline.isEmpty {
                    Text("No Sections").foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    OutlineRows(nodes: Outline.tree(outline), project: project, keys: keys, folded: $folded,
                                selected: chosen ?? current)
                }
            }
            .listStyle(.sidebar)
            // The header above stands in for a section's, so the list's room over its
            // first row goes; the scroller keeps to what shows.
            .contentMargins(.top, sidebarListRoom, for: .scrollIndicators)
            .padding(.top, -sidebarListRoom)
            .clipped()
            .environment(\.sidebarRowSize, outlineRowSize)
            .onChange(of: project.cursorLine, initial: true) { _, cursor in line = cursor }
            .onChange(of: project.topHeading) { line = project.topLine }
            // The current heading always shows: its sections open, then the
            // least scroll that brings it into view.
            .onChange(of: current, initial: true) { _, id in
                chosen = nil
                let chain = Outline.chain(outline, at: line).dropLast()
                let opened = folded.subtracting(chain.map { keys[$0.id] })
                if opened != folded { folded = opened }
                guard let id else { return }
                Task { proxy.scrollTo(id) }
            }
            .onChange(of: folded) { _, folded in
                // The open file's folds of headings it no longer has go.
                let current = Set(keys)
                let stale = outline.isEmpty ? [] : folded.filter { $0.hasPrefix(prefix) && !current.contains($0) }
                UserDefaults.standard.set(Array(folded.subtracting(stale)).sorted(), forKey: DefaultsKey.outlineFolded)
            }
        }
    }
}

/// The headings nested, each fold remembered by `Outline.foldKeys`.
private struct OutlineRows: View {
    let nodes: [OutlineNode]
    let project: ProjectModel
    let keys: [String]
    @Binding var folded: Set<String>
    let selected: Int?

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: expansion(node.item)) {
                    OutlineRows(nodes: children, project: project, keys: keys, folded: $folded, selected: selected)
                } label: {
                    row(node.item)
                }
            } else {
                row(node.item)
            }
        }
    }

    private func row(_ item: OutlineItem) -> some View {
        HeadingRow(project: project, item: item, repeatSelection: selected == item.id)
            .equatable()
            .id(item.id)
            .tag(item.id)
    }

    private func expansion(_ item: OutlineItem) -> Binding<Bool> {
        let key = keys[item.id]
        return Binding(
            get: { !folded.contains(key) },
            set: { open in
                if open { folded.remove(key) } else { folded.insert(key) }
            }
        )
    }
}

/// A heading. A click takes the source to it even when it's the current one,
/// which a selection that doesn't change wouldn't.
private struct HeadingRow: View, Equatable {
    let project: ProjectModel
    let item: OutlineItem
    let repeatSelection: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.project === b.project && a.item == b.item && a.repeatSelection == b.repeatSelection
    }

    var body: some View {
        let title = Outline.displayTitle(item)
        // The whole title as a tooltip only where it's cut short.
        ViewThatFits(in: .horizontal) {
            Text(title).fixedSize()
            Text(title).help(title)
        }
        .lineLimit(1)
        .foregroundStyle(item.isUntitled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        // New selections are handled by List (including arrow keys). Only a
        // click on the already selected heading needs a second way to activate.
        .simultaneousGesture(TapGesture().onEnded { if repeatSelection { project.reveal(item) } })
        .accessibilityLabel(title)
        // Its kind ("Subsection"); the list tells its depth.
        .accessibilityValue(item.kind)
    }
}
