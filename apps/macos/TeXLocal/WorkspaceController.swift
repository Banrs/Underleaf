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
    private var outlineBarHeight: NSLayoutConstraint!
    private var mounts: [ObjectIdentifier: Mount] = [:]
    private let searchField = FieldHandle()

    private var appeared = false, joining = false
    private var panelHeight: CGFloat = 0
    private var paneAnimations = 0, quieting = 0
    private var quietScrollViews: [NSScrollView] = []
    private var watches: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []
    private var resizes: [NotificationCenter.ObservationToken] = []

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        toolbar = WorkspaceToolbar(app: app, project: project)
        super.init()
        toolbar.workspace = self
        // Not "Workspace", whose saved sidebar is the earlier opening width's.
        if app.savesLayout {
            for (split, name) in zip(splitViews, ["Workspace 2", "Sidebar", "Columns", "Area"]) {
                split.autosaveName = name
            }
        }
        buildSidebar(height: size.height)
        // Before the area, which opens in the room the side columns leave; added after it.
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project), mounted: app.inspectorVisible))
        // Collapsed before they are added: collapsed only once loaded, the inspector's form loses its grouped insets and
        // large section titles, and opens narrower.
        inspectorItem.isCollapsed = !app.inspectorVisible
        inspectorItem.canCollapseFromWindowResize = true
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
        for item in [sidebarItem, outlineItem, pdfItem, panelItem, inspectorItem] {
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
            follow(inspectorItem) { [unowned self] shown in
                if shown { mount(inspectorItem.viewController, true) }
                app.sideColumn(.inspector, shown: shown, byWindow: foldedByWindow)
            },
            follow(pdfItem),
            // A drag on the status bar's line, not the autosave's restore.
            follow(panelItem) { [unowned self] shown in
                guard [.leftMouseDragged, .leftMouseUp].contains(NSApp.currentEvent?.type), project.panel.shown != shown else { return }
                project.panel.shown = shown
            },
        ]
        // The splits tell of a resize before the nested panes have their frames.
        resizes = [sourceItem, pdfItem].map { pane in
            let view = pane!.viewController.view
            view.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(of: view, for: .frameDidChange) { [weak self] _ in self?.fitColumns() }
        }
    }

    /// Unless a divider was dragged shut: a column AppKit folds as a toggle opens the other has the click as its event.
    private var foldedByWindow: Bool { NSApp.currentEvent?.type != .leftMouseDragged || view.window?.inLiveResize == true }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !appeared else { return }
        appeared = true
        if !app.showPDF { pdfItem.isCollapsed = true }
        fitColumns()
    }

    /// AppKit's fixed inspector takes no drag.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        splitViewItems.firstIndex(of: inspectorItem) == dividerIndex + 1 ? .zero
            : super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
    }

    /// AppKit folds the side columns on the way to the toolbar's least width, by the area's minimum.
    private func fitColumns() {
        let pdf = pdfItem.isCollapsed ? 0 : columns.splitView.dividerThickness + ColumnMetrics.pdfRoom
        let area = max(sourceItem.minimumThickness + pdf + ColumnMetrics.toolbarInset, ColumnMetrics.toolbarMinimum - ColumnMetrics.windowControls)
        if areaItem.minimumThickness != area { areaItem.minimumThickness = area }
        fitToolbar()
        // A turn on, once the toolbar has laid its sections out for the panes as they now are.
        guard appeared, !joining else { return }
        joining = true
        Task { [weak self] in
            self?.joining = false
            self?.joinDivider()
        }
    }

    /// The separator follows the divider only as far as each section's tools leave it room (27.2), so the divider goes to
    /// it. No API tells its place: its view is found by class, and without it nothing moves.
    private func joinDivider() {
        guard paneAnimations == 0, !pdfItem.isCollapsed, let content = view.window?.contentView, let frame = content.superview else { return }
        let split = columns.splitView, divider = split.arrangedSubviews[0].frame.maxX
        let lines = frame.subviews.filter { $0 !== content }.flatMap { $0.descendants(named: "NSSeparatorToolbarItemView") }
            .map { split.convert($0.bounds, from: $0).minX }
        guard let line = lines.min(by: { abs($0 - divider) < abs($1 - divider) }), abs(line - divider) >= 0.5 else { return }
        split.setPosition(line, ofDividerAt: 0)
    }

    /// Customize Toolbar changed the tools, which Compile's form goes by.
    func toolbarItemsChanged() { if appeared { fitToolbar() } }

    /// Compile's word goes where it is the first tool without room, and comes back once no pane moves. With other tools
    /// than the default, whose widths aren't known, it goes only before AppKit would take Compile itself (27.2).
    private func fitToolbar() {
        func edges(_ item: NSSplitViewItem) -> NSRect { item.viewController.view.convert(item.viewController.view.bounds, to: splitView) }
        let source = edges(sourceItem), area = edges(areaItem)
        // Short of the window controls and sidebar toggle, and of the PDF and Inspector toggles.
        let leading = max(source.minX, ColumnMetrics.windowControls)
        let trailing = min(area.maxX, splitView.bounds.maxX - ColumnMetrics.toggles)
        let tools = trailing - leading - ColumnMetrics.sourceTools
        // A PDF sliding in is already at its width.
        let room = pdfItem.isCollapsed ? tools - ColumnMetrics.separator
            : min(tools, pdfItem.viewController.view.frame.width - (area.maxX - trailing)) - ColumnMetrics.zoom
        let fixed = ColumnMetrics.toolbarMinimum - ColumnMetrics.windowControls - ColumnMetrics.toggles
        let compact = toolbar.holdsDefaultItems ? room < ColumnMetrics.compile : trailing - leading < fixed + ColumnMetrics.compileWord
        if compact || paneAnimations == 0 { toolbar.compactCompile = compact }
    }

    // MARK: - Layout

    /// A pane opens at its view's frame as it's added, and a collapsed one shows there first.
    private func buildSidebar(height: CGFloat) {
        let filesItem = NSSplitViewItem(viewController: host(FilesList(project: project)))
        filesItem.minimumThickness = 100
        // Never hidden before its first layout, when it would still inset its pane (27.2).
        let header = hostingView(OutlineHeader())
        header.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSView()
        bar.addSubview(header)
        // Its content keeps one place as the bar's height animates, so folded it lines up with the status bar.
        outlineBarHeight = bar.heightAnchor.constraint(equalToConstant: outlineBarHeight(folded: app.outlineState(of: project) != .open))
        NSLayoutConstraint.activate([outlineBarHeight, header.topAnchor.constraint(equalTo: bar.topAnchor),
                                     header.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                                     header.trailingAnchor.constraint(equalTo: bar.trailingAnchor)])
        // The files draw the edge (`HeaderEdge`); the accessory's own would lay AppKit's glass over them.
        outlineBar = accessory(bar, edge: .soft)
        filesItem.addBottomAlignedAccessoryViewController(outlineBar)
        outlineItem = NSSplitViewItem(viewController: host(OutlineList(project: project), height: (height * 0.45).rounded()))
        outlineItem.minimumThickness = 80
        // It keeps its height as the window resizes; the files take the change.
        outlineItem.holdingPriority = .defaultLow + 1
        sidebar.addSplitViewItem(filesItem)
        sidebar.addSplitViewItem(outlineItem)
        // Loaded, the sidebar has restored its autosave, which the model overrules.
        sidebar.view.frame.size.width = ColumnMetrics.sidebarIdeal
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
        let sidebarWidth = app.sidebarVisible ? ColumnMetrics.sidebarIdeal : 0
        let inspectorWidth = app.inspectorVisible ? inspectorItem.minimumThickness : 0
        let panes = max(size.width - sidebarWidth - inspectorWidth, ColumnMetrics.sourceMinimum + ColumnMetrics.pdfMinimum)
        let pdfWidth = min((panes * ColumnMetrics.pdfShare).rounded(), panes - ColumnMetrics.sourceMinimum)
        panelHeight = max(ColumnMetrics.panelMinimum, (size.height * 0.25).rounded())

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: panes - pdfWidth))
        sourceItem.minimumThickness = ColumnMetrics.sourceMinimum
        pdfItem = NSSplitViewItem(viewController: host(PDFPane(project: project), width: pdfWidth))
        pdfItem.minimumThickness = ColumnMetrics.pdfMinimum
        pdfFind = accessory(hostingView(PDFFindBar(find: pdf.find), mounted: false))
        (pdfFind.isHidden, pdfFind.view.isHidden) = (true, true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        // The last toolbar section's edge effect needs a safe area ending where the section does (27.2).
        columns.view.additionalSafeAreaInsets.right = ColumnMetrics.toolbarInset
        // 27.2: collapsed at the first layout, it leaves the source without the toolbar's scroll edge.
        pdfItem.isCollapsed = false

        // As Xcode's editor bar, over an empty accessory in each pane. 27.2: one across both gave its edge to one only.
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
    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0, mounted: Bool? = nil) -> NSViewController {
        let mount = mounted.map(Mount.init)
        let host = NSHostingController(rootView: Pane(project: project, mount: mount, content: content).environment(app))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        if let mount { mounts[ObjectIdentifier(host.view)] = mount }
        return host
    }

    private func hostingView(_ content: some View, mounted: Bool? = nil) -> NSHostingView<some View> {
        let mount = mounted.map(Mount.init)
        let host = NSHostingView(rootView: Pane(project: project, mount: mount, content: content).environment(app))
        if let mount { mounts[ObjectIdentifier(host)] = mount }
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return host
    }

    /// `edge` for a bar of its own height: AppKit's insets would pad it, and the pane's safe area with it (27.2).
    private func accessory(_ view: NSView, edge: NSScrollEdgeEffectStyle? = nil) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = view
        if let edge {
            accessory.automaticallyAppliesContentInsets = false
            accessory.preferredScrollEdgeEffectStyle = edge
        }
        return accessory
    }

    private func outlineBarHeight(folded: Bool) -> CGFloat { folded ? BarMetrics.height : OutlineHeader.openHeight }

    private func mount(_ controller: NSViewController, _ shown: Bool) {
        guard let mount = mounts[ObjectIdentifier(controller.view)], mount.shown != shown else { return }
        mount.shown = shown
        if shown { controller.view.layoutSubtreeIfNeeded() }
    }

    // MARK: - The models drive the panes

    private func watch() {
        let app = app, project = project, pdf = pdf
        watches = [
            track({ app.sidebarShown }) { [weak self] in if let self { setCollapsed(sidebarItem, !$0) } },
            track({ app.inspectorShown }) { [weak self] in if let self { setCollapsed(inspectorItem, !$0) } },
            // Until the workspace appears, `viewDidAppear` has it.
            track({ app.showPDF }) { [weak self] in if let self, appeared { setCollapsed(pdfItem, !$0) } },
            track({ project.panel.shown }) { [weak self] in self?.setPanelShown($0) },
            track({ app.outlineState(of: project) }) { [weak self] state in
                guard let self else { return }
                setHidden(outlineBar, state == .hidden)
                setCollapsed(outlineItem, state != .open)
            },
            track({ pdf.find.isOpen }) { [weak self] in if let self { setHidden(pdfFind, !$0) } },
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

    /// Each column's change, and with it the room the toolbar has.
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
        // Unanimated, the panel changes layout without the live resize AppKit's animation starts even when instant.
        guard animates || item !== panelItem else {
            item.isCollapsed = collapsed
            view.layoutSubtreeIfNeeded()
            return done()
        }
        if !collapsed { mount(item.viewController, true) }
        paneAnimation(true)
        Task.immediate {
            await NSAnimationContext.runAnimationGroup { context in
                if !animates { context.duration = 0 }
                // One animation carries the outline's pane and its header's height.
                if item === outlineItem {
                    context.allowsImplicitAnimation = true
                    outlineBarHeight.animator().constant = outlineBarHeight(folded: collapsed)
                }
                item.animator().isCollapsed = collapsed
                if item === outlineItem { sidebar.view.layoutSubtreeIfNeeded() }
            }
            if item.isCollapsed { mount(item.viewController, false) }
            paneAnimation(false)
            done()
        }
    }

    private func paneAnimation(_ running: Bool) {
        // It puts every pane in live resize, which shows their overlay scrollers too.
        quiet(running)
        paneAnimations += running ? 1 : -1
        if paneAnimations == 0 { fitColumns() }
    }

    private var splitViews: [NSSplitView] { [splitView, sidebar.splitView, columns.splitView, area.splitView] }

    /// Scroll bars come with scrolling (HIG, Scroll views), not with a drag's or animation's live resize.
    func quiet(_ resizing: Bool) {
        quieting += resizing ? 1 : -1
        guard quieting == (resizing ? 1 : 0) else { return }
        if resizing { quietScrollViews = view.descendants(of: NSScrollView.self) }
        for scroll in quietScrollViews { scroll.hideOverlayScrollers(resizing) }
        if !resizing { quietScrollViews = [] }
    }

    /// A hidden accessory only folds to no height, and its controls would stay in the key view loop and VoiceOver.
    private func setHidden(_ accessory: NSSplitViewItemAccessoryViewController, _ hidden: Bool) {
        guard accessory.isHidden != hidden else { return }
        if !hidden {
            mount(accessory, true)
            accessory.view.isHidden = false
        }
        guard animates else {
            (accessory.isHidden, accessory.view.isHidden) = (hidden, hidden)
            if hidden { mount(accessory, false) }
            return
        }
        paneAnimation(true)
        Task.immediate {
            await NSAnimationContext.runAnimationGroup { _ in accessory.animator().isHidden = hidden }
            if hidden, accessory.isHidden {
                accessory.view.isHidden = true
                mount(accessory, false)
            }
            paneAnimation(false)
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
                focus(pdf.find.field, in: pdfFind)
            case let .reveal(loc, source): pdf.reveal(loc, from: source)
            case .inverseFromView:
                if case let (page, point)? = pdf.sourcePoint() { Task { await project.inverseSync(page: page, x: point.x, y: point.y) } }
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

/// 27.2: a hidden hosting view still updates its content for every environment change (20 ms for the inspector).
@Observable final class Mount {
    var shown: Bool
    init(_ shown: Bool) { self.shown = shown }
}

/// Off while a project opened over this one loads.
private struct Pane<Content: View>: View {
    let project: ProjectModel
    let mount: Mount?
    let content: Content

    var body: some View { if mount?.shown ?? true { content.disabled(project.closed) } }
}
