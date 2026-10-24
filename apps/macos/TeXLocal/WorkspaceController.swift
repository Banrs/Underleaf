import AppKit
import SwiftUI

/// AppKit's splits, as only they give the editor and PDFKit's view the system's scroll edges under one status bar.
final class WorkspaceController: ThinSplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    let toolbar: WorkspaceToolbar

    let columns = ThinSplitViewController(splitView: ColumnsSplitView())
    private let area = AreaSplitViewController(isVertical: false)
    private let sidebar = SidebarSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var outlineItem, sourceItem, pdfItem, panelItem, inspectorItem, areaItem: NSSplitViewItem!
    private var sidebarSearch, pdfFind, outlineBar: NSSplitViewItemAccessoryViewController!
    private var pdfEmpty: NSView!
    private let searchField = FieldHandle()
    private let inspectorMount: Mount

    private var appeared = false
    private var panelHeight: CGFloat = 0
    private var quieting = 0
    private var quietScrollViews: [NSScrollView] = []
    private var watches: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []
    private var resizes: [NotificationCenter.ObservationToken] = []

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        inspectorMount = Mount(shown: app.inspectorVisible)
        toolbar = WorkspaceToolbar(app: app, project: project)
        super.init()
        toolbar.workspace = self
        // Not "Workspace", whose saved sidebar is the earlier opening width's.
        if app.savesLayout {
            for (split, name) in zip(splitViews, ["Workspace 2", "Sidebar", "Columns", "Area"]) {
                split.autosaveName = name
            }
        }
        // Before the side columns, which open at the width AppKit's inspector does, and the area, which opens in the room
        // they leave; added after them.
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project), mount: inspectorMount))
        buildSidebar(height: size.height)
        // Collapsed before they are added: collapsed only once loaded, the inspector's form loses its grouped insets and
        // large section titles, and opens narrower.
        inspectorItem.isCollapsed = !app.inspectorVisible
        inspectorItem.canCollapseFromWindowResize = true
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
        for item in [sidebarItem, outlineItem, sourceItem, pdfItem, panelItem, inspectorItem] {
            item!.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        }
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The models overrule the autosave at once: left to the tracks, a pane would open with AppKit's animation.
    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarItem.isCollapsed = !app.sidebarVisible
        inspectorItem.isCollapsed = !app.inspectorVisible
        if !project.panel.shown { panelItem.isCollapsed = true }
        collapses = [
            follow(sidebarItem) { [unowned self] in app.sideColumn(.sidebar, shown: $0, byWindow: foldedByWindow) },
            follow(inspectorItem) { [unowned self] in app.sideColumn(.inspector, shown: $0, byWindow: foldedByWindow) },
            follow(sourceItem),
            follow(pdfItem),
            // A drag on the status bar's line, not the autosave's restore nor a window's resize.
            follow(panelItem) { [unowned self] shown in
                guard [.leftMouseDragged, .leftMouseUp].contains(NSApp.currentEvent?.type), view.window?.inLiveResize != true,
                      project.panel.shown != shown else { return }
                project.panel.shown = shown
            },
        ]
        // The splits tell of a resize before the nested panes have their frames.
        resizes = [sourceItem, pdfItem].map { pane in
            let view = pane!.viewController.view
            view.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(of: view, for: .frameDidChange) { [weak self] _ in self?.fitToolbar() }
        }
    }

    /// Unless a divider was dragged shut: a column AppKit folds as a toggle opens the other has the click as its event.
    private var foldedByWindow: Bool { NSApp.currentEvent?.type != .leftMouseDragged || view.window?.inLiveResize == true }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !appeared else { return }
        appeared = true
        if !app.showSource { sourceItem.isCollapsed = true }
        if !app.showPDF { pdfItem.isCollapsed = true }
        fitColumns()
    }

    /// AppKit's fixed inspector takes no drag.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        splitViewItems.firstIndex(of: inspectorItem) == dividerIndex + 1 ? .zero
            : super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
    }

    /// AppKit folds the side columns before the area goes under the panes' least widths.
    private func fitColumns() {
        let both = !sourceItem.isCollapsed && !pdfItem.isCollapsed
        let area = both ? 2 * ColumnMetrics.paneMinimum + columns.splitView.dividerThickness : ColumnMetrics.paneMinimum
        if areaItem.minimumThickness != area { areaItem.minimumThickness = area }
        fitToolbar()
    }

    /// Compile's word goes before AppKit would take Zoom or Compile to the overflow menu, where it is the first tool
    /// without room, and comes back once no pane moves.
    private func fitToolbar() {
        func edges(_ item: NSSplitViewItem) -> NSRect { item.viewController.view.convert(item.viewController.view.bounds, to: splitView) }
        let source = edges(sourceItem), area = edges(areaItem)
        let leading = max(source.minX, ColumnMetrics.windowControls)
        let trailing = min(area.maxX, splitView.bounds.maxX - ColumnMetrics.toggles)
        let tools = trailing - leading - ColumnMetrics.sourceTools
        // A PDF sliding in is already at its width.
        let room = pdfItem.isCollapsed ? tools - ColumnMetrics.separator
            : min(tools, pdfItem.viewController.view.frame.width - (area.maxX - trailing)) - ColumnMetrics.zoom
        let compact = room < ColumnMetrics.compile
        if compact || quieting == 0 { toolbar.compactCompile = compact }
    }

    // MARK: - Layout

    /// A pane opens at its view's frame as it's added, and a collapsed one shows there first.
    private func buildSidebar(height: CGFloat) {
        let filesItem = NSSplitViewItem(viewController: host(FilesList(project: project)))
        filesItem.minimumThickness = 100
        // Hidden only after its first layout, before which it would still inset its pane. The status bar's height, folded or
        // open: it rides the files' foot as the outline opens, one motion with the outline's rows under it.
        let header = hostingView(OutlineHeader())
        header.heightAnchor.constraint(equalToConstant: BarMetrics.height).isActive = true
        // The files draw the edge (`HeaderEdge`); the accessory's own would lay AppKit's glass over them.
        outlineBar = accessory(header, edge: .soft)
        filesItem.addBottomAlignedAccessoryViewController(outlineBar)
        outlineItem = NSSplitViewItem(viewController: host(OutlineList(project: project), height: (height * 0.45).rounded()))
        outlineItem.minimumThickness = 80
        // It keeps its height as the window resizes; the files take the change.
        outlineItem.holdingPriority = .defaultLow + 1
        sidebar.addSplitViewItem(filesItem)
        sidebar.addSplitViewItem(outlineItem)
        // Loaded, the sidebar has restored its autosave, which the model overrules.
        sidebar.view.frame.size.width = inspectorItem.minimumThickness
        if app.outlineState(of: project) != .open { outlineItem.isCollapsed = true }
        sidebar.header = outlineBar

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 222
        sidebarItem.isCollapsed = !app.sidebarVisible
        sidebarSearch = accessory(hostingView(SearchField(text: Bindable(project.search).query, prompt: "Search Project", handle: searchField)))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    private func buildArea(size: CGSize) {
        // As a first launch opens: the autosave puts the columns as they were since.
        let sideColumns = CGFloat([app.sidebarVisible, app.inspectorVisible].filter(\.self).count) * inspectorItem.minimumThickness
        let panes = max(size.width - sideColumns, 2 * ColumnMetrics.paneMinimum)
        let pdfWidth = min((panes * ColumnMetrics.pdfShare).rounded(), panes - ColumnMetrics.paneMinimum)
        panelHeight = max(ColumnMetrics.panelMinimum, (size.height * 0.25).rounded())

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: panes - pdfWidth))
        sourceItem.minimumThickness = ColumnMetrics.paneMinimum
        // PDFKit's view in the pane itself, as Preview's, under SwiftUI's empty states while there is no PDF.
        let pdfPane = NSViewController()
        pdfPane.view = NSView(frame: NSRect(x: 0, y: 0, width: pdfWidth, height: 0))
        let empty = NSHostingView(rootView: Pane(project: project, content: PDFEmptyState(project: project)).environment(app))
        empty.sizingOptions = []
        pdfEmpty = empty
        for pane in [pdf.view, empty] as [NSView] {
            pane.frame = pdfPane.view.bounds
            pane.autoresizingMask = [.width, .height]
            pdfPane.view.addSubview(pane)
        }
        pdf.view.onInverse = { [weak project] page, point, click in
            Task { await project?.inverseSync(page: page, x: point.x, y: point.y, click: click) }
        }
        pdfItem = NSSplitViewItem(viewController: pdfPane)
        pdfItem.minimumThickness = ColumnMetrics.paneMinimum
        pdfFind = accessory(hostingView(PDFFindBar(find: pdf.find)))
        (pdfFind.isHidden, pdfFind.view.isHidden) = (true, true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        // Shown at the first layout whatever the autosave says, as `viewDidAppear` folds it by the model: folded then, it
        // left the source without the toolbar's scroll edge, which no test can see.
        pdfItem.isCollapsed = false

        // As Xcode's editor bar, over an empty accessory in each pane: one across both gave its edge to one only.
        for item in [sourceItem!, pdfItem!] {
            let space = NSView()
            space.heightAnchor.constraint(equalToConstant: BarMetrics.height).isActive = true
            item.addBottomAlignedAccessoryViewController(accessory(space, edge: .hard))
        }
        let bar = hostingView(StatusBar(project: project))
        bar.sizingOptions = []
        // Not the toolbar's inset the columns take.
        bar.safeAreaRegions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        columns.view.addSubview(bar)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: columns.view.leadingAnchor),
                                     bar.trailingAnchor.constraint(equalTo: columns.view.trailingAnchor),
                                     bar.bottomAnchor.constraint(equalTo: columns.view.bottomAnchor),
                                     bar.heightAnchor.constraint(equalToConstant: BarMetrics.height)])

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project), height: panelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        panelItem.holdingPriority = .defaultLow + 1
        // As Xcode's debug area: dragged under its least height it closes.
        panelItem.canCollapse = true
        let columnsItem = NSSplitViewItem(viewController: columns)
        columnsItem.minimumThickness = 200
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)
        areaItem = NSSplitViewItem(viewController: area)
        addSplitViewItem(areaItem)
    }

    /// The toolbar's toggles go through the model, as the menu's do.
    override func toggleSidebar(_ sender: Any?) { app.sidebarShown.toggle() }
    override func toggleInspector(_ sender: Any?) { app.inspectorShown.toggle() }

    /// Sized by the split item's limits: its content never sets the window's minimum.
    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0, mount: Mount? = nil) -> NSViewController {
        let host = NSHostingController(rootView: Pane(project: project, mount: mount, content: content).environment(app))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        return host
    }

    private func hostingView(_ content: some View) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: Pane(project: project, content: content).environment(app))
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return host
    }

    /// `edge` for a bar of its own height: AppKit's insets would pad it, and the pane's safe area with it.
    private func accessory(_ view: NSView, edge: NSScrollEdgeEffectStyle? = nil) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = view
        if let edge {
            accessory.automaticallyAppliesContentInsets = false
            accessory.preferredScrollEdgeEffectStyle = edge
        }
        return accessory
    }

    // MARK: - The models drive the panes

    private func watch() {
        let app = app, project = project, pdf = pdf
        watches = [
            track({ app.sidebarShown }) { [weak self] in if let self { setCollapsed(sidebarItem, !$0) } },
            track({ app.inspectorShown }) { [weak self] in if let self { setCollapsed(inspectorItem, !$0) } },
            track({ [app.showSource, app.showPDF] }) { [weak self] _ in self?.showPanes() },
            track({ project.panel.shown }) { [weak self] in self?.setPanelShown($0) },
            track({ app.outlineState(of: project) }) { [weak self] state in
                guard let self else { return }
                setHidden(outlineBar, state == .hidden)
                setCollapsed(outlineItem, state != .open)
            },
            track({ pdf.find.isOpen }) { [weak self] in if let self { setHidden(pdfFind, !$0) } },
            // Over the pages, which stay laid out for the next PDF.
            track({ project.hasPDF }) { [weak self] in self?.pdfEmpty.isHidden = $0 },
            track({ app.searchFocusToken }, initial: false) { [weak self] _ in
                guard let self else { return }
                setCollapsed(sidebarItem, false)
                focus(searchField, in: sidebarSearch)
            },
            // Closed, as a project opened over it loads, it keeps no keyboard: its panes are off (`Pane`).
            track({ project.closed }, initial: false) { [weak self] _ in self?.view.window?.makeFirstResponder(nil) },
        ]
        app.performPDF = { [weak self] in self?.performPDF($0) }
    }

    /// Until the workspace appears, `viewDidAppear` has them. The one shown opens first and the other closes after it, so
    /// both are never shut and the one closing keeps its own width to come back at.
    private func showPanes() {
        guard appeared else { return }
        let (opening, closing) = app.showSource ? (sourceItem!, pdfItem!) : (pdfItem!, sourceItem!)
        setCollapsed(opening, false) { [weak self] in
            guard let self else { return }
            setCollapsed(closing, !(closing === sourceItem ? app.showSource : app.showPDF))
        }
    }

    /// Each column's change, and with it the area's least width.
    private func follow(_ item: NSSplitViewItem, _ shown: @escaping @MainActor (Bool) -> Void = { _ in }) -> NSKeyValueObservation {
        item.observe(\.isCollapsed, options: .new) { [weak self] _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated {
                shown(!collapsed)
                self?.fitColumns()
            }
        }
    }

    /// Through AppKit's collapse animation, which brings a pane back at the size it was hidden at.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, done: @escaping @MainActor () -> Void = {}) {
        // Repeated model notifications must not snap an animation already heading here.
        guard item.isCollapsed != collapsed else { return done() }
        if item === inspectorItem, !collapsed, !inspectorMount.shown {
            inspectorMount.shown = true
            item.viewController.view.layoutSubtreeIfNeeded()
        }
        // Unanimated, the panel changes layout without the live resize AppKit's animation starts even when instant.
        guard animates || item !== panelItem else {
            item.isCollapsed = collapsed
            view.layoutSubtreeIfNeeded()
            return done()
        }
        quiet(true)
        Task.immediate {
            await NSAnimationContext.runAnimationGroup { context in
                if !animates { context.duration = 0 }
                item.animator().isCollapsed = collapsed
            }
            quiet(false)
            done()
        }
    }

    private var splitViews: [NSSplitView] { [splitView, sidebar.splitView, columns.splitView, area.splitView] }

    /// Scroll bars come with scrolling (HIG, Scroll views), not with a drag's or animation's live resize, which an
    /// animation puts every pane in.
    func quiet(_ resizing: Bool) {
        quieting += resizing ? 1 : -1
        guard quieting == (resizing ? 1 : 0) else { return }
        if resizing { quietScrollViews = view.descendants(of: NSScrollView.self) }
        for scroll in quietScrollViews { scroll.hideOverlayScrollers(resizing) }
        if !resizing {
            quietScrollViews = []
            fitToolbar()
        }
    }

    /// A hidden accessory only folds to no height, and its controls would stay in the key view loop and VoiceOver.
    private func setHidden(_ accessory: NSSplitViewItemAccessoryViewController, _ hidden: Bool) {
        guard accessory.isHidden != hidden else { return }
        if !hidden { accessory.view.isHidden = false }
        guard animates else {
            (accessory.isHidden, accessory.view.isHidden) = (hidden, hidden)
            return
        }
        quiet(true)
        Task.immediate {
            await NSAnimationContext.runAnimationGroup { _ in accessory.animator().isHidden = hidden }
            if hidden, accessory.isHidden { accessory.view.isHidden = true }
            quiet(false)
        }
    }

    /// AppKit brings it back at its hosted view's height, or unanimated at its minimum, so its height is kept here.
    private func setPanelShown(_ shown: Bool) {
        guard shown == panelItem.isCollapsed else { return }
        let split = area.splitView, panel = panelItem.viewController.view
        if !shown { panelHeight = panel.frame.height }
        guard animates else {
            setCollapsed(panelItem, !shown)
            if shown { split.setPosition(split.bounds.height - split.dividerThickness - panelHeight, ofDividerAt: 0) }
            return
        }
        // Not reversing a close midway, which heads back to where it began.
        if shown, split.arrangedSubviews[1].isHidden {
            let room = split.bounds.height - split.dividerThickness - area.view.safeAreaInsets.top - area.splitViewItems[0].minimumThickness
            panel.frame.size.height = min(panelHeight, room)
        }
        setCollapsed(panelItem, !shown)
    }

    private var animates: Bool { view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func focus(_ field: FieldHandle, in accessory: NSSplitViewItemAccessoryViewController) {
        if field.field == nil { accessory.view.layoutSubtreeIfNeeded() }
        field.focus()
    }

    /// A split animation still running finishes after its window has gone and would save its frames over the next window's.
    func close() {
        for split in splitViews { split.autosaveName = nil }
        watches.forEach { $0.cancel() }
        app.performPDF = nil
        // The next workspace's columns are AppKit's to fold afresh.
        (app.sidebarFolded, app.inspectorFolded) = (false, false)
        collapses = []
        resizes = []
        toolbar.close()
    }

    private func performPDF(_ action: PDFAction) {
        setCollapsed(pdfItem, false) { [weak self] in
            guard let self else { return }
            project.perform(action) {
                pdf.find.isOpen = true
                setHidden(pdfFind, false)
                focus(pdf.find.field, in: pdfFind)
            }
        }
    }
}

/// The build panel opens and resizes from the status bar's line, as Xcode's debug area. A split view is flipped.
private final class AreaSplitViewController: ThinSplitViewController {
    override func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        let line = splitView.arrangedSubviews[0].frame.maxY - BarMetrics.height
        return NSRect(x: 0, y: line - 2, width: splitView.bounds.width, height: splitView.dividerThickness + 4)
    }
}

/// The inspector's form, built and laid out as the column starts to open: built while hidden, or laid out only as it
/// opens, the grouped form keeps 10 pt insets and small grey headers (`aHiddenInspectorOpensWithItsFormsLook`).
@Observable private final class Mount {
    var shown: Bool
    init(shown: Bool) { self.shown = shown }
}

/// Off while a project opened over this one loads.
private struct Pane<Content: View>: View {
    let project: ProjectModel
    var mount: Mount?
    let content: Content

    var body: some View { if mount?.shown ?? true { content.disabled(project.closed) } }
}
