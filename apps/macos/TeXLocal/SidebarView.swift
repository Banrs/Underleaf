import SwiftUI

/// The sidebar, as a writer's rather than a programmer's and as Overleaf
/// lays it out: the project's files over the open document's outline, with
/// a divider to drag between them, and project search at the top. They are
/// separate lists: the files keep the one selection (the open file); the
/// outline is a table of contents with no selection of its own, its current
/// section tinted. The outline folds to its header, docked at the foot of
/// the sidebar, and the files take the room.
struct NavigatorView: View {
    /// The outline folded to its header (its section's chevron, or View ›
    /// Hide File Outline).
    static let outlineCollapsedKey = "OutlineCollapsed"
    /// The folded outline's height: its header, the secondary rows'
    /// height, so the divider over it continues the status bar's hairline.
    static var outlineHeaderHeight: CGFloat { BarMetrics.secondaryBarHeight }
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @FocusState private var searchFocused: Bool
    @AppStorage(Self.outlineCollapsedKey) private var outlineCollapsed = false
    @State private var fold = OutlineFold()

    var body: some View {
        SidebarSplit(app: app, autosave: "OutlineSplit",
                     top: SidebarPane(minimum: 100),
                     bottom: SidebarPane(minimum: 80, fraction: 0.45, keepsSize: true, shown: showsOutline,
                                         collapsed: outlineCollapsed ? Self.outlineHeaderHeight : nil,
                                         didFold: { [fold] folded in fold.slid(folded: folded) })) {
            FilesList(project: project)
        } bottomContent: {
            // Takes no drops: files go into the list above.
            OutlineList(project: project, fold: fold)
        }
        .searchable(text: $project.searchQuery, placement: .sidebar, prompt: "Search Project")
        .searchFocused($searchFocused)
        .onChange(of: app.searchFocusToken) { _, _ in searchFocused = true }
    }

    /// Search results take the whole sidebar.
    private var showsOutline: Bool {
        project.searchQuery.isEmpty && project.isLaTeX
    }
}

/// The project's files, or the project search's results while there is a
/// query.
private struct FilesList: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var selection: String?
    @State private var hit: SearchHit.ID?
    @State private var deleting: String?
    @State private var rename = InPlaceRename<String>()
    /// The open folders, by path.
    @State private var expanded: Set<String> = []
    /// Files dragged over the list's empty space, or over a row.
    @State private var listTargeted = false
    @State private var rowTargeted: TreeNode?

    var body: some View {
        // Two lists rather than one whose sections change shape: the
        // sidebar's outline view, diffed from the tree to grouped hits and
        // back, kept stale rows.
        Group {
            if project.searchQuery.isEmpty { files } else { results }
        }
        .trashConfirmation($deleting, name: { ($0 as NSString).lastPathComponent }) { path in
            Task { await project.deleteEntry(path) }
        }
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
                // The project's top level, marked as a folder row is while a
                // drop would go there.
                Text("Files").headerDropHighlight(dropFolder == "")
            }
        }
        .listStyle(.sidebar)
        // Into the project's top level; a row takes a drop into its folder.
        // Only here, not over search results, whose rows aren't the tree.
        .fileDrop(targeted: { listTargeted = $0 }) { urls in
            Task { await project.importFiles(urls) }
        }
        // Adding, where Finder and Apple's lists keep it: the File menu, and
        // the list's own menu on its empty space.
        .contextMenu(forSelectionType: String.self) { paths in
            if paths.isEmpty {
                Button(MenuCommand.fileNew.title) { app.perform(.fileNew, on: project) }
                Button(MenuCommand.fileNewFolder.title) { app.perform(.fileNewFolder, on: project) }
                Divider()
                Button(MenuCommand.fileUpload.title) { app.perform(.fileUpload, on: project) }
            }
        } primaryAction: { paths in
            // Double-click or Return on a folder opens or closes it, as
            // Xcode's navigator does; a file is open once it's chosen.
            guard let path = paths.first, project.tree.flattened.contains(where: { $0.path == path && $0.isDirectory }) else { return }
            if expanded.remove(path) == nil { expanded.insert(path) }
        }
        .onChange(of: selection) { _, path in
            if let path, path != project.openPath,
               project.tree.flattened.contains(where: { $0.path == path && !$0.isDirectory }) {
                Task { await project.open(path, focus: false) }
            }
        }
        .onChange(of: project.openPath, initial: true) { _, path in selection = path }
        // ⌫, as Finder and the projects table take it.
        .onDeleteCommand { if let selection { deleting = selection } }
    }

    /// Choosing a hit opens it, as Xcode's find navigator does.
    private var results: some View {
        List(selection: $hit) { searchResults }
            .listStyle(.sidebar)
            .onChange(of: hit) { _, id in
                if let found = project.searchHits.first(where: { $0.id == id }) {
                    Task { await project.open(found.file, line: found.line) }
                }
            }
            .overlay {
                if project.searchHits.isEmpty { ContentUnavailableView.search(text: project.searchQuery) }
            }
    }

    /// Hits grouped by file, each line with its match picked out.
    @ViewBuilder
    private var searchResults: some View {
        let groups = Dictionary(grouping: project.searchHits, by: \.file).sorted { $0.key < $1.key }
        ForEach(groups, id: \.key) { file, hits in
            Section("\(file) — \(hits.count)") {
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
            }
        }
    }

    private func row(_ node: TreeNode) -> some View {
        let isMain = node.path == project.settings?.mainFile
        return Label {
            HStack {
                if rename.id == node.path {
                    RenameField(text: $rename.name) { commitRename(node) } cancel: { rename.cancel() }
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
            Image(systemName: fileSymbol(node.path, directory: node.isDirectory))
        }
        // The whole row a drop target, not only its name.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .dropHighlight(node.isDirectory && dropFolder == node.path)
        // The star's name too: the row's label replaces its children's.
        .accessibilityLabel(isMain ? "\(node.name), Main File" : node.name)
        // Into the folder dropped on, or the one the file dropped on is in,
        // as Windows' tree takes them; elsewhere the list's own drop adds
        // them at the top.
        .fileDrop(targeted: { over in
            if over { rowTargeted = node } else if rowTargeted?.path == node.path { rowTargeted = nil }
        }) { urls in
            let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
            Task { await project.importFiles(urls, into: folder) }
        }
        .contextMenu {
            if !node.isDirectory && node.path.hasSuffix(".tex") {
                Button("Set as Main File") { Task { await project.setMainFile(node.path) } }
                Divider()
            }
            ItemMenuItems(rename: { rename.begin(node.path, name: node.name) },
                          showInFinder: { project.showInFinder(node.path) },
                          moveToTrash: { deleting = node.path })
        }
    }

    private func commitRename(_ node: TreeNode) {
        guard let name = rename.end(node.path, from: node.name), !name.contains("/") else { return }
        let folder = (node.path as NSString).deletingLastPathComponent
        Task { await project.renameEntry(node.path, to: folder.isEmpty ? name : "\(folder)/\(name)") }
    }
}

/// The tree as the sidebar shows one: native disclosure triangles on the
/// folders, each open or closed as `expanded` has it.
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
    // The kit's window sidebar is 256 pt wide.
    .frame(width: 256, height: 240)
}

/// The sidebar's selection capsule, as the UI kit draws a selected row
/// (8 pt corners) and macOS 27.2 places one: 10 pt in from each side of
/// the list, a row's height (measured). Nonisolated for the shape's sake.
private nonisolated enum SidebarSelection {
    static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    static let inset: CGFloat = 10
}

/// A row's content outlined as the sidebar's selection is: from 4 pt
/// before it, as the UI kit's selected row reaches past its content, to
/// where the selection stops, the content running to 2 pt from the
/// sidebar's edge; and 2 pt above and below it, a header's height
/// (measured on macOS 27.2). Nonisolated: SwiftUI may ask a shape for its
/// path off the main thread.
private nonisolated struct SidebarRowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let row = CGRect(x: rect.minX - 4, y: rect.minY - 2, width: rect.width + 4 - (SidebarSelection.inset - 2),
                         height: rect.height + 4)
        return SidebarSelection.shape.path(in: row)
    }
}

private extension View {
    /// A row where a drop would go, marked as a selection is but tinted a
    /// level under one, so its text keeps its colours.
    func dropHighlight(_ isOn: Bool) -> some View {
        listRowBackground(isOn ? SidebarSelection.shape.fill(.tint.quaternary)
            .padding(.horizontal, SidebarSelection.inset) : nil)
    }

    /// The same for a section's header, which a list gives no row
    /// background: marked around its content.
    func headerDropHighlight(_ isOn: Bool) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isOn { SidebarRowShape().fill(.tint.quaternary) }
            }
    }
}

extension View {
    /// Takes files dropped from Finder, copied in (the pointer carries the
    /// copy badge). Anything else, a link dragged from a browser or a file
    /// `accepts` turns down, is refused as it's dragged, and slides back.
    /// `targeted` tells whether a drag it takes is over it.
    func fileDrop(accepts: @escaping (URL) -> Bool = { _ in true }, targeted: @escaping (Bool) -> Void,
                  action: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            targeted(false)
            let files = urls.filter { $0.isFileURL && accepts($0) }
            if !files.isEmpty { action(files) }
        }
        .dropConfiguration { _ in DropConfiguration(operation: draggedFiles(accepts) ? .copy : .forbidden) }
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering, .active: targeted(draggedFiles(accepts))
            default: targeted(false)
            }
        }
    }
}

/// Whether a drag holds a file `accepts` takes. From the drag's pasteboard,
/// AppKit's: a drop session names none of its items until they're dropped.
private func draggedFiles(_ accepts: (URL) -> Bool) -> Bool {
    let urls = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                     options: [.urlReadingFileURLsOnly: true]) as? [URL]
    return urls?.contains(where: accepts) ?? false
}

/// The open document's sections, as Overleaf's file outline, in a list of
/// their own under the files: one sidebar section, "File Outline", whose
/// header's chevron folds the whole outline away, leaving only the header
/// docked at the foot of the sidebar while the files take the room, and
/// opens it again at the height it had.
///
/// The headings nest with native disclosure triangles, in the sidebar's
/// Small rows (a size under the files'). They take no part in any
/// selection, so no row draws a selection capsule; the current section is
/// in the accent colour and semibold instead, its sections opened and kept
/// in view, as Overleaf's outline highlights where you are: the caret's
/// section, or the one at the top of the source once it scrolls, whichever
/// moved last. Choosing a heading scrolls it to the top of the source and
/// leaves focus where it was.
///
/// Only this view reads the top line, so scrolling the source re-renders
/// the outline, not the files, and only the headings whose state changed
/// (`HeadingRow` is equatable).
///
/// Folding slides the pane down to its header and unfolding slides it back
/// up, the rows riding with it as a drawer's contents do: the section
/// empties once the slide is over and fills before it starts, rather than
/// its rows collapsing up into the header while the pane moves down.
private struct OutlineList: View {
    /// Folded headings, by file and `Outline.foldKeys`.
    private static let foldedKey = "OutlineFolded"
    let project: ProjectModel
    let fold: OutlineFold
    @AppStorage(NavigatorView.outlineCollapsedKey) private var collapsed = false
    @State private var folded = Set(UserDefaults.standard.stringArray(forKey: Self.foldedKey) ?? [])
    /// The line the highlight follows: the caret's or the top line,
    /// whichever changed last.
    @State private var line = 1

    var body: some View {
        let outline = project.outline
        let current = Outline.chain(outline, at: line).last?.id
        let prefix = "\(project.id)/\(project.openPath ?? "")\t"
        let keys = Outline.foldKeys(outline).map { prefix + $0 }
        ScrollViewReader { proxy in
            List {
                Section("File Outline", isExpanded: Binding(get: { fold.rowsShown }, set: { collapsed = !$0 })) {
                    if outline.isEmpty {
                        Text("No Sections").foregroundStyle(.secondary)
                    } else {
                        OutlineRows(nodes: Outline.tree(outline), context: OutlineRows.Context(
                            project: project, current: current, keys: keys), folded: $folded)
                    }
                }
            }
            .listStyle(.sidebar)
            // A table of contents under a list of files: the sidebar's
            // compact rows, a size under the files'.
            .environment(\.sidebarRowSize, .small)
            // Centres the header in the docked bar when folded.
            .padding(.top, BarMetrics.spacing)
            // Filled before the pane slides open; emptied once it has slid
            // shut (`OutlineFold.slid`).
            .onChange(of: collapsed) { _, collapsed in
                if !collapsed { withTransaction(Transaction(animation: nil)) { fold.rowsShown = true } }
            }
            .onChange(of: project.cursorLine, initial: true) { _, cursor in line = cursor }
            .onChange(of: project.topLine) { _, top in line = top }
            // The current heading always shows: its sections open, then the
            // least scroll that brings it into view.
            .onChange(of: current, initial: true) { _, id in
                let chain = Outline.chain(outline, at: line).dropLast()
                let opened = folded.subtracting(chain.map { keys[$0.id] })
                if opened != folded { folded = opened }
                guard let id else { return }
                Task { proxy.scrollTo(id) }
            }
            .onChange(of: folded) { _, folded in
                UserDefaults.standard.set(Array(folded).sorted(), forKey: Self.foldedKey)
            }
        }
    }
}

/// Whether the outline's section shows its rows: with the pane open, and
/// until a fold has slid the pane down to its header, so the rows ride
/// down with it rather than collapsing up into the header first.
@Observable
final class OutlineFold {
    var rowsShown = !(UserDefaults.standard.object(forKey: NavigatorView.outlineCollapsedKey) as? Bool ?? false)

    /// A fold or unfold has finished sliding, or happened at once while
    /// the pane was out of the sidebar (during a project search), so it
    /// comes back with its chevron as it is.
    func slid(folded: Bool) {
        guard folded == UserDefaults.standard.bool(forKey: NavigatorView.outlineCollapsedKey) else { return }
        withTransaction(Transaction(animation: nil)) { rowsShown = !folded }
    }
}

/// The headings as the sidebar shows a hierarchy: native disclosure
/// triangles on the headings with headings under them, each fold
/// remembered (by `Outline.foldKeys`, so it survives renumbering).
private struct OutlineRows: View {
    struct Context {
        let project: ProjectModel
        let current: Int?
        let keys: [String]
    }

    let nodes: [OutlineNode]
    let context: Context
    @Binding var folded: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: expansion(node.item)) {
                    OutlineRows(nodes: children, context: context, folded: $folded)
                } label: {
                    row(node.item)
                }
            } else {
                row(node.item)
            }
        }
    }

    private func row(_ item: OutlineItem) -> some View {
        HeadingRow(project: context.project, item: item, isCurrent: item.id == context.current)
            .equatable()
            .id(item.id)
    }

    private func expansion(_ item: OutlineItem) -> Binding<Bool> {
        let key = context.keys[item.id]
        return Binding(
            get: { !folded.contains(key) },
            set: { open in
                if open { folded.remove(key) } else { folded.insert(key) }
            }
        )
    }
}

/// A heading: not a list selection, so it draws no selection capsule; the
/// current one is in the accent colour and semibold. Choosing one scrolls
/// it to the top of the source and leaves focus where it was. The list
/// indents each level and draws the disclosure triangles, so the outermost
/// headings' triangles line up with the files' and their titles start
/// where the file icons do.
private struct HeadingRow: View, Equatable {
    let project: ProjectModel
    let item: OutlineItem
    let isCurrent: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.project === b.project && a.item == b.item && a.isCurrent == b.isCurrent
    }

    var body: some View {
        let title = Outline.displayTitle(item)
        Button {
            guard let path = project.openPath else { return }
            Task { await project.open(path, line: item.line, atTop: true, focus: false) }
        } label: {
            // The whole title as a tooltip only where it's cut short.
            ViewThatFits(in: .horizontal) {
                Text(title).fixedSize()
                Text(title).help(title)
            }
            .lineLimit(1)
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint)
                             : item.isUntitled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            // Its focus ring in the row's shape, not the title's rectangle.
            .contentShape(.focusEffect, SidebarRowShape())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        // Its kind ("Subsection"); the list tells its depth.
        .accessibilityValue(item.kind)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
