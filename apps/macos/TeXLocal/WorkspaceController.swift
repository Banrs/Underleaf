import AppKit
import SwiftUI

/// A project's workspace: the files, the source and the PDF over the build panel, and the inspector, in AppKit's splits
/// with SwiftUI in the panes. AppKit's, as only its splits give the editor and PDFKit's view the system's scroll edges
/// under one status bar, with the toolbar's sections over the source and the PDF following their divider.
final class WorkspaceController: SplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    let toolbar: WorkspaceToolbar

    let columns = SplitViewController(splitView: ColumnsSplitView())
    private let area = SplitViewController(isVertical: false)
    private let sidebar = SidebarSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var outlineItem, sourceItem, pdfItem, panelItem, inspectorItem, areaItem: NSSplitViewItem!
    private var sidebarSearch, pdfFind: NSSplitViewItemAccessoryViewController!
    /// The File Outline's header at the files' foot, and its height: as the outline's
    /// first row's room when open, the status bar's when folded.
    private var outlineBar: NSSplitViewItemAccessoryViewController!
    private var outlineBarHeight: NSLayoutConstraint!
    private let searchField = FieldHandle()

    private var panelHeight: CGFloat = 0
    private var watches: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        toolbar = WorkspaceToolbar(app: app, project: project)
        super.init()
        toolbar.workspace = self
        // Remembered positions: not "Workspace", whose saved sidebar is the earlier opening width's.
        if app.savesLayout {
            for (split, name) in [(splitView, "Workspace 2"), (sidebar.splitView, "Sidebar"), (columns.splitView, "Columns"),
                                  (area.splitView, "Area")] {
                split.autosaveName = name
            }
        }
        buildSidebar(size: size)
        // Before the area, which opens in the room the side columns leave; added after it.
        buildInspector()
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
        for item in [sidebarItem, outlineItem, pdfItem, panelItem, inspectorItem] as [NSSplitViewItem] {
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        }
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The autosave restores which panes were collapsed as each split loads, but the models say which show, and the side
    /// columns take that at once: left to the tracks (`watch`), a column the autosave had shut, as a narrow window folds
    /// one, would open with AppKit's animation as the project appears. The model follows the side columns from here on.
    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarItem.isCollapsed = !app.sidebarVisible
        inspectorItem.isCollapsed = !app.inspectorVisible
        collapses = [
            follow(sidebarItem) { [unowned self] in app.sideColumn(.sidebar, shown: $0, byWindow: foldedByWindow) },
            follow(inspectorItem) { [unowned self] in app.sideColumn(.inspector, shown: $0, byWindow: foldedByWindow) },
            follow(pdfItem) { [unowned self] _ in fitArea() },
            // A drag on the status bar's line opens or closes it without the model's asking; the autosave's restore at load
            // doesn't count.
            follow(panelItem) { [unowned self] shown in
                guard [.leftMouseDragged, .leftMouseUp].contains(NSApp.currentEvent?.type), project.panel.shown != shown else { return }
                project.panel.shown = shown
            },
        ]
        fitArea()
    }

    /// A side column that shut without the model's asking was shut by the user, with a click or a drag on its divider, or
    /// folded by the split for want of room: during the window's live resize, or with no pointer event behind it.
    private var foldedByWindow: Bool {
        let pointer: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        return view.window?.inLiveResize == true || NSApp.currentEvent.map { !pointer.contains($0.type) } ?? true
    }

    /// AppKit folds the side columns as the window narrows by the minimum of the area beside them, not by the minimums of
    /// the panes inside it.
    private func fitArea() {
        let pdf = pdfItem.isCollapsed ? 0 : columns.splitView.dividerThickness + pdfItem.minimumThickness
        areaItem.minimumThickness = sourceItem.minimumThickness + pdf
    }

    // MARK: - Layout

    /// A pane's size is its view's frame as it's added: the split opens it there, and a collapsed one shows there first.
    /// The sidebar opens at AppKit's standard share of the window; the autosave keeps its width afterwards.
    private func buildSidebar(size: CGSize) {
        let filesItem = NSSplitViewItem(viewController: host(FilesList(project: project)))
        filesItem.minimumThickness = ColumnMetrics.filesMinimum
        // The outline's header stays at the files' foot, over the outline's pane or, folded, at the sidebar's: one view, which
        // the pane's collapse carries down and back. Only search results hide it, and a workspace opens with none: hidden
        // before its first layout, a bottom accessory still insets its pane (27.2).
        buildOutlineBar()
        filesItem.addBottomAlignedAccessoryViewController(outlineBar)
        outlineItem = NSSplitViewItem(viewController: host(OutlineList(project: project),
                                                            height: (size.height * ColumnMetrics.outlineShare).rounded()))
        outlineItem.minimumThickness = ColumnMetrics.outlineMinimum
        // It keeps its height as the window resizes; the files take the change.
        outlineItem.holdingPriority = .defaultLow + 1
        sidebar.addSplitViewItem(filesItem)
        sidebar.addSplitViewItem(outlineItem)
        sidebar.loaded = { [unowned self] in if app.outlineState(of: project) != .open { outlineItem.isCollapsed = true } }
        sidebar.header = outlineBar

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebar.view.frame.size.width = (size.width * sidebarItem.preferredThicknessFraction).rounded()
        sidebarItem.isCollapsed = !app.sidebarVisible
        sidebarSearch = accessory(SearchField(text: Bindable(project.search).query, prompt: "Search Project", handle: searchField))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    private func buildArea(size: CGSize) {
        // As a first launch opens, the source and the PDF alike: the autosave puts the columns as they were afterwards.
        let sidebarWidth = app.sidebarVisible ? sidebar.view.frame.width : 0
        let inspectorWidth = app.inspectorVisible ? inspectorItem.minimumThickness : 0
        let panes = max(size.width - sidebarWidth - inspectorWidth, ColumnMetrics.sourceMinimum + ColumnMetrics.pdfMinimum)
        panelHeight = max(ColumnMetrics.panelMinimum, (size.height * ColumnMetrics.panelShare).rounded())

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: (panes / 2).rounded()))
        sourceItem.minimumThickness = ColumnMetrics.sourceMinimum

        pdfItem = NSSplitViewItem(viewController: host(PDFPane(project: project), width: panes - (panes / 2).rounded()))
        pdfItem.minimumThickness = ColumnMetrics.pdfMinimum
        pdfFind = accessory(PDFFindBar(find: pdf.find), hidden: true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)

        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        columns.loaded = { [unowned self] in pdfItem.isCollapsed = !app.showPDF }

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project), height: panelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        panelItem.holdingPriority = .defaultLow + 1
        // As Xcode's debug area: dragged under its least height from the status bar's line it closes, and dragged up from
        // there it opens.
        panelItem.canCollapse = true

        let columnsItem = NSSplitViewItem(viewController: columns)
        columnsItem.minimumThickness = ColumnMetrics.columnsMinimum
        buildStatusBar()
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)
        area.loaded = { [unowned self] in if !project.panel.shown { panelItem.isCollapsed = true } }
        // The panel resizes from the status bar's line, as Xcode's debug area does from its bar's, and opens from there while
        // shut. A split view is flipped, and a thin divider takes presses 2 pt either side of its line.
        area.grip = { [unowned area] _ in
            let split = area.splitView, line = split.arrangedSubviews[0].frame.maxY - BarMetrics.height
            return NSRect(x: 0, y: line - 2, width: split.bounds.width, height: split.dividerThickness + 4)
        }

        areaItem = NSSplitViewItem(viewController: area)
        addSplitViewItem(areaItem)
    }

    /// The editors' one bar, across both panes at the columns' foot: their text and the PDF's pages scroll on beneath it,
    /// and it rides up with them as the panel opens. Each pane has an empty bottom accessory of the bar's height with
    /// AppKit's hard scroll edge, as Xcode's editor bar has: the ground, its line and what shows through are AppKit's, and
    /// the bar lies over both. 27.2: one accessory across the columns gave its edge to one pane's scroll view only, about
    /// half the launches.
    private func buildStatusBar() {
        for item in [sourceItem!, pdfItem!] {
            let space = NSSplitViewItemAccessoryViewController()
            space.view = NSView()
            space.view.heightAnchor.constraint(equalToConstant: BarMetrics.height).isActive = true
            // 27.2: AppKit's insets would pad it, and the pane's safe area with it.
            space.automaticallyAppliesContentInsets = false
            // A bar of text and controls: even over its whole height, as under Xcode's editor bar.
            space.preferredScrollEdgeEffectStyle = .hard
            item.addBottomAlignedAccessoryViewController(space)
        }
        let bar = NSHostingView(rootView: root(StatusBar(project: project)))
        bar.sizingOptions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        columns.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: columns.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: columns.view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: columns.view.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: BarMetrics.height),
        ])
    }

    private func buildInspector() {
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project)))
        inspectorItem.isCollapsed = !app.inspectorVisible
        // As the sidebar: a window too narrow for it folds it, and brings it back.
        inspectorItem.canCollapseFromWindowResize = true
    }

    /// The toolbar's toggles go through the model, as the menu's do.
    override func toggleSidebar(_ sender: Any?) { app.sidebarShown.toggle() }
    override func toggleInspector(_ sender: Any?) { app.inspectorShown.toggle() }

    /// SwiftUI whose sizes stay out of Auto Layout, so the split item's limits size it and its content never sets the
    /// window's minimum.
    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0) -> NSViewController {
        let host = NSHostingController(rootView: root(content))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        return host
    }

    private func root(_ content: some View) -> some View {
        WorkspaceContent(project: project, content: content).environment(app)
    }

    /// The header under the files' scroll edge, whose hairline stands for the sidebar split's divider (`SidebarSplitViewController`).
    /// Its content keeps one place under the line as the bar's height animates with the split, so folded it lines up with the
    /// status bar.
    private func buildOutlineBar() {
        let bar = NSView()
        let header = NSHostingView(rootView: root(OutlineHeader()))
        header.sizingOptions = [.intrinsicContentSize]
        header.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(header)
        outlineBarHeight = bar.heightAnchor.constraint(equalToConstant: outlineBarHeight(folded: app.outlineState(of: project) != .open))
        NSLayoutConstraint.activate([
            outlineBarHeight,
            header.topAnchor.constraint(equalTo: bar.topAnchor),
            header.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        outlineBar = NSSplitViewItemAccessoryViewController()
        outlineBar.view = bar
        outlineBar.automaticallyAppliesContentInsets = false
        // The files draw the edge (`HeaderEdge`); the accessory's own would lay AppKit's glass over them.
        outlineBar.preferredScrollEdgeEffectStyle = .soft
    }

    private func outlineBarHeight(folded: Bool) -> CGFloat { folded ? BarMetrics.height : OutlineHeader.openHeight }

    private func accessory(_ content: some View, hidden: Bool = false) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        let host = NSHostingView(rootView: root(content))
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessory.view = host
        accessory.isHidden = hidden
        accessory.view.isHidden = hidden
        return accessory
    }

    // MARK: - The models drive the panes

    private func watch() {
        let app = app, project = project, pdf = pdf
        watches = [
            track({ app.sidebarShown }) { [weak self] visible in if let self { setCollapsed(sidebarItem, !visible) } },
            track({ app.inspectorShown }) { [weak self] visible in if let self { setCollapsed(inspectorItem, !visible) } },
            track({ app.showPDF }) { [weak self] visible in if let self { setCollapsed(pdfItem, !visible) } },
            track({ project.panel.shown }) { [weak self] in self?.setPanelShown($0) },
            track({ app.outlineState(of: project) }) { [weak self] in self?.setOutline($0) },
            track({ pdf.find.isOpen }) { [weak self] finding in if let self { setHidden(pdfFind, !finding) } },
            track({ app.searchFocusToken }, initial: false) { [weak self] _ in self?.focusSearch() },
            // Closed, as a project opened over it loads, it keeps no keyboard: its panes are off (`WorkspaceContent`).
            track({ project.closed }, initial: false) { [weak self] _ in self?.view.window?.makeFirstResponder(nil) },
        ]
        app.performPDF = { [weak self] in self?.performPDF($0) }
    }

    private func follow(_ item: NSSplitViewItem, _ shown: @escaping @MainActor (Bool) -> Void) -> NSKeyValueObservation {
        item.observe(\.isCollapsed, options: .new) { _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated { shown(!collapsed) }
        }
    }

    /// Through AppKit's collapse animation, which brings a pane back at the size it was hidden at.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, done: @escaping @MainActor () -> Void = {}) {
        // Repeated model notifications must not snap an animation already heading here.
        guard item.isCollapsed != collapsed else { return done() }
        guard animates else {
            item.isCollapsed = collapsed
            if item === outlineItem { outlineBarHeight.constant = outlineBarHeight(folded: collapsed) }
            view.layoutSubtreeIfNeeded()
            return done()
        }
        NSAnimationContext.runAnimationGroup { context in
            // One animation carries the outline's pane and its header's height.
            if item === outlineItem {
                context.allowsImplicitAnimation = true
                outlineBarHeight.animator().constant = outlineBarHeight(folded: collapsed)
            }
            item.animator().isCollapsed = collapsed
            if item === outlineItem { sidebar.view.layoutSubtreeIfNeeded() }
        } completionHandler: {
            MainActor.assumeIsolated(done)
        }
    }

    /// The pane folds down under its header to the sidebar's foot, and opens up from there.
    private func setOutline(_ state: OutlineState) {
        setHidden(outlineBar, state == .hidden)
        setCollapsed(outlineItem, state != .open)
    }

    /// A hidden accessory only folds to no height, and its controls would stay in the key view loop and VoiceOver.
    private func setHidden(_ accessory: NSSplitViewItemAccessoryViewController, _ hidden: Bool) {
        guard accessory.isHidden != hidden else { return }
        if !hidden { accessory.view.isHidden = false }
        guard animates else {
            accessory.isHidden = hidden
            accessory.view.isHidden = hidden
            return
        }
        NSAnimationContext.runAnimationGroup { _ in
            accessory.animator().isHidden = hidden
        } completionHandler: {
            MainActor.assumeIsolated {
                if hidden, accessory.isHidden { accessory.view.isHidden = true }
            }
        }
    }

    /// AppKit's animation brings it back at its hosted view's height, and unanimated at its minimum, so the height it was hidden at is kept here.
    private func setPanelShown(_ shown: Bool) {
        guard shown == panelItem.isCollapsed else { return }
        let split = area.splitView, panel = panelItem.viewController.view
        // Opening, the hosted view is already at the height the pane is heading for.
        if !shown { panelHeight = panel.frame.height }
        guard animates else {
            setCollapsed(panelItem, !shown)
            if shown { split.setPosition(split.bounds.height - split.dividerThickness - panelHeight, ofDividerAt: 0) }
            return
        }
        // Not reversing a close midway, which heads back to where it began.
        if shown, split.arrangedSubviews[1].isHidden {
            let room = split.bounds.height - split.dividerThickness - area.view.safeAreaInsets.top
                - area.splitViewItems[0].minimumThickness
            panel.frame.size.height = min(panelHeight, room)
        }
        setCollapsed(panelItem, !shown)
    }

    private var animates: Bool { view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func focusField(_ field: FieldHandle, in accessory: NSSplitViewItemAccessoryViewController) {
        if field.field == nil { accessory.view.layoutSubtreeIfNeeded() }
        field.focus()
    }

    private func focusSearch() {
        setCollapsed(sidebarItem, false)
        focusField(searchField, in: sidebarSearch)
    }

    /// A split animation still running finishes after its window has gone and would save its frames over the next window's.
    func close() {
        for split in [splitView, sidebar.splitView, columns.splitView, area.splitView] { split.autosaveName = nil }
        watches.forEach { $0.cancel() }
        app.performPDF = nil
        // The next workspace's columns are AppKit's to fold afresh: it brings back only what it folded.
        (app.sidebarFolded, app.inspectorFolded) = (false, false)
        collapses = []
        toolbar.close()
    }

    // MARK: - The menus' PDF requests

    private func performPDF(_ action: PDFAction) {
        setCollapsed(pdfItem, false) { [weak self] in
            guard let self, project.hasPDF else { return }
            switch action {
            case .zoomIn: pdf.zoom(in: true)
            case .zoomOut: pdf.zoom(in: false)
            case .actualSize: pdf.setScale(1)
            case .fitWidth: pdf.fitWidth()
            case .fitPage: pdf.fitPage()
            case .goToPage(let page): pdf.go(toPage: page)
            case .find:
                pdf.find.isOpen = true
                setHidden(pdfFind, false)
                focusField(pdf.find.field, in: pdfFind)
            case let .reveal(loc, source): pdf.reveal(loc, from: source)
            case .inverseFromView:
                if case let (page, point)? = pdf.sourcePoint() {
                    Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
                }
            }
        }
    }
}

/// Off while a project opened over this one loads, which keeps this one in the window until then (`AppModel.workspaceProject`).
private struct WorkspaceContent<Content: View>: View {
    let project: ProjectModel
    let content: Content

    var body: some View { content.disabled(project.closed) }
}
