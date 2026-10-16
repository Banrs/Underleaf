import AppKit
import SwiftUI

final class WorkspaceController: DetentSplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    let toolbar: WorkspaceToolbar

    let columns = DetentSplitViewController(splitView: ColumnsSplitView())
    private let area = DetentSplitViewController()
    private let sidebar = SidebarSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var outlineItem: NSSplitViewItem!
    private var sourceItem: NSSplitViewItem!
    private var pdfItem: NSSplitViewItem!
    private var panelItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var areaItem: NSSplitViewItem!
    private var sidebarSearch: NSSplitViewItemAccessoryViewController!
    /// The File Outline's header at the files' foot, and its height: as the outline's
    /// first row's room when open, the status bar's when folded.
    private var outlineBar: NSSplitViewItemAccessoryViewController!
    private var outlineBarHeight: NSLayoutConstraint!
    private var pdfFind: NSSplitViewItemAccessoryViewController!
    private var mounts: [ObjectIdentifier: Mount] = [:]
    private let searchField = FieldHandle()

    private var panelHeight: CGFloat = 0
    private var paneAnimations = 0
    private var paneFrames: CADisplayLink?
    private var watches: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []
    /// The panes' frames (`fitColumns`), watched for as long as their tokens are held.
    private var resizes: [NotificationCenter.ObservationToken] = []

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        toolbar = WorkspaceToolbar(app: app, project: project)
        super.init()
        toolbar.workspace = self
        // Not "Workspace", whose saved sidebar is the earlier opening width's.
        splitView.autosaveName = "Workspace 2"
        buildSidebar(height: size.height)
        // Before the area, which opens in the room the side columns leave; added after it.
        buildInspector()
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
        for item in panes {
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        }
        // The opening sizes: the sidebar's width, and the split a double-click on its divider restores.
        detent = { [unowned self] divider in
            divider == 0 && !sidebarItem.isCollapsed ? ColumnMetrics.sidebarIdeal : nil
        }
        // AppKit's fixed inspector takes no drag.
        fixed = { [unowned self] divider in splitViewItems.firstIndex(of: inspectorItem) == divider + 1 }
        columns.detent = { [unowned columns] _ in (columns.splitView as? ColumnsSplitView)?.openingPosition }
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The autosave restores which panes were collapsed as each split loads, but the models say which show, and the side
    /// columns take that at once. Left to the tracks (`watch`), a column the autosave had shut, as a narrow window folds
    /// one, opened with AppKit's animation as the project appeared, and `joinDivider` waits out pane animations. The model
    /// follows the side columns from here on.
    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarItem.isCollapsed = !app.sidebarVisible
        inspectorItem.isCollapsed = !app.inspectorVisible
        collapses = [
            follow(sidebarItem) { [unowned self] visible in
                fold(visible, shown: \.sidebarVisible, folded: \.sidebarFolded)
            },
            follow(inspectorItem) { [unowned self] visible in
                if visible { mount(inspectorItem.viewController, true) }
                fold(visible, shown: \.inspectorVisible, folded: \.inspectorFolded)
            },
            follow(pdfItem) { [unowned self] _ in fitColumns() },
        ]
        // The panes' own frames: the splits tell of a resize before the nested panes have theirs.
        resizes = [sourceItem, pdfItem].map { pane in
            let view = pane!.viewController.view
            view.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(of: view, for: .frameDidChange) { [weak self] _ in self?.fitColumns() }
        }
    }

    /// A side column that shut without the model's asking was dragged shut, which hides it, or folded by a window too narrow
    /// for it, which doesn't: AppKit brings that one back as the window widens, and the model keeps it as shown.
    private func fold(_ visible: Bool, shown: ReferenceWritableKeyPath<AppModel, Bool>,
                      folded: ReferenceWritableKeyPath<AppModel, Bool>) {
        let dragged = NSApp.currentEvent?.type == .leftMouseDragged && view.window?.inLiveResize != true
        if visible || dragged {
            if app[keyPath: folded] { app[keyPath: folded] = false }
            if app[keyPath: shown] != visible { app[keyPath: shown] = visible }
        } else if app[keyPath: shown], !app[keyPath: folded] {
            app[keyPath: folded] = true
        }
        fitColumns()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !appeared else { return }
        appeared = true
        if !app.showPDF { pdfItem.isCollapsed = true }
        fitColumns()
    }

    private var appeared = false

    /// AppKit folds the side columns on the way to the toolbar's least width, by the area's own minimum.
    private func fitColumns() {
        let pdf = pdfItem.isCollapsed ? 0 : columns.splitView.dividerThickness + ColumnMetrics.pdfRoom
        let panes = sourceItem.minimumThickness + pdf + ColumnMetrics.toolbarInset
        let area = max(panes, ColumnMetrics.toolbarMinimum - ColumnMetrics.windowControls)
        if areaItem.minimumThickness != area { areaItem.minimumThickness = area }
        fitToolbar()
        joinDividerSoon()
    }

    private var joining = false

    /// A turn on, once the toolbar has laid its sections out for the panes as they now are.
    private func joinDividerSoon() {
        guard appeared, !joining else { return }
        joining = true
        Task { @MainActor [weak self] in
            self?.joining = false
            self?.joinDivider()
        }
    }

    /// The source|PDF divider goes to the toolbar's separator where the two have parted. AppKit's separator follows the
    /// divider only as far as each section's tools leave it room: under a source narrower than Back, the title and its
    /// tools, or a PDF narrower than its own, it stops and the tools stand over the neighbouring pane (27.2), and it
    /// sends tools to its overflow menu by the room between the side columns' separators, not a section's. So the
    /// divider keeps to where the separator can be, which the toolbar alone knows: its line is found by its class, and
    /// without it nothing moves. It is among the toolbar's views beside the content view, under the window's frame view
    /// (27.2), so the search runs at each layout without the panes' views.
    private func joinDivider() {
        guard paneAnimations == 0, !pdfItem.isCollapsed, let content = view.window?.contentView,
              let frame = content.superview else { return }
        let split = columns.splitView, divider = split.arrangedSubviews[0].frame.maxX
        let lines = frame.subviews.filter { $0 !== content }.flatMap { $0.descendants(named: "NSSeparatorToolbarItemView") }
            .map { split.convert($0.bounds, from: $0).minX }
        guard let line = lines.min(by: { abs($0 - divider) < abs($1 - divider) }), abs(line - divider) >= 0.5 else { return }
        split.setPosition(line, ofDividerAt: 0)
    }

    /// Customize Toolbar has put a tool in or taken one out, and Compile's form goes by which are there. Until the
    /// workspace appears its panes have no frames to reckon from.
    func toolbarItemsChanged() {
        if appeared { fitToolbar() }
    }

    /// Compile gives up its word where that is the first tool without room: over a PDF narrower than Zoom and Compile,
    /// or once the source's tools have outgrown their pane and take the PDF's room. It takes the word back once no pane
    /// is moving, as a pane's animation can widen the room on its way to less. The room is reckoned from the default
    /// tools' widths (`ColumnMetrics`). In a toolbar customised to others their widths aren't known and AppKit's
    /// overflow menu alone takes what has no room, so there Compile keeps its word until the tools that never leave have
    /// no room for it: AppKit would take Compile itself next (27.2).
    private func fitToolbar() {
        func edges(_ item: NSSplitViewItem) -> NSRect {
            let view = item.viewController.view
            return view.convert(view.bounds, to: splitView)
        }
        let source = edges(sourceItem), area = edges(areaItem)
        // Short of the window controls with the sidebar's toggle, and of the PDF and Inspector toggles.
        let leading = max(source.minX, ColumnMetrics.windowControls)
        let trailing = min(area.maxX, splitView.bounds.maxX - ColumnMetrics.toggles)
        var room = trailing - leading - ColumnMetrics.sourceTools
        if pdfItem.isCollapsed {
            room -= ColumnMetrics.separator
        } else {
            // A PDF sliding in is already at its width.
            room = min(room, pdfItem.viewController.view.frame.width - (area.maxX - trailing)) - ColumnMetrics.zoom
        }
        let fixed = ColumnMetrics.toolbarMinimum - ColumnMetrics.windowControls - ColumnMetrics.toggles
        let compact = toolbar.holdsDefaultItems ? room < ColumnMetrics.compile
            : trailing - leading < fixed + ColumnMetrics.compileWord
        if compact || paneAnimations == 0 { toolbar.compactCompile = compact }
    }

    // MARK: - Layout

    /// A pane's size is its view's frame as it's added: the split opens it there, and a collapsed one shows there first.
    private func buildSidebar(height: CGFloat) {
        sidebar.splitView.isVertical = false
        sidebar.splitView.autosaveName = "Sidebar"
        let filesItem = NSSplitViewItem(viewController: host(FilesList(project: project)))
        filesItem.minimumThickness = ColumnMetrics.filesMinimum
        // The outline's header stays at the files' foot, over the outline's pane or, folded, at the sidebar's: one view, which
        // the pane's collapse carries down and back. Only search results hide it, and a workspace opens with none: hidden
        // before its first layout, a bottom accessory still insets its pane (27.2).
        buildOutlineBar()
        filesItem.addBottomAlignedAccessoryViewController(outlineBar)
        outlineItem = NSSplitViewItem(viewController: host(OutlineList(project: project),
                                                            height: (height * ColumnMetrics.outlineShare).rounded()))
        outlineItem.minimumThickness = ColumnMetrics.outlineMinimum
        // It keeps its height as the window resizes; the files take the change.
        outlineItem.holdingPriority = .defaultLow + 1
        sidebar.addSplitViewItem(filesItem)
        sidebar.addSplitViewItem(outlineItem)
        sidebar.loaded = { [unowned self] in if app.outlineState(of: project) != .open { outlineItem.isCollapsed = true } }
        sidebar.view.frame.size.width = ColumnMetrics.sidebarIdeal
        sidebar.header = outlineBar

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = ColumnMetrics.sidebarMinimum
        sidebarItem.isCollapsed = !app.sidebarVisible
        sidebarSearch = accessory(SearchField(text: Bindable(project.search).query, prompt: "Search Project", handle: searchField))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    private func buildArea(size: CGSize) {
        // As a first launch opens: the autosave puts the columns as they were afterwards.
        let sidebarWidth = app.sidebarVisible ? ColumnMetrics.sidebarIdeal : 0
        let inspectorWidth = app.inspectorVisible ? inspectorItem.minimumThickness : 0
        let panes = max(size.width - sidebarWidth - inspectorWidth, ColumnMetrics.sourceMinimum + ColumnMetrics.pdfMinimum)
        let pdfWidth = min((panes * ColumnMetrics.pdfShare).rounded(), panes - ColumnMetrics.sourceMinimum)
        panelHeight = max(ColumnMetrics.panelMinimum, (size.height * ColumnMetrics.panelShare).rounded())

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: panes - pdfWidth))
        sourceItem.minimumThickness = ColumnMetrics.sourceMinimum

        pdfItem = NSSplitViewItem(viewController: host(PDFPane(project: project), width: pdfWidth))
        pdfItem.minimumThickness = ColumnMetrics.pdfMinimum
        pdfFind = accessory(PDFFindBar(controller: pdf), hidden: true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)

        columns.splitView.autosaveName = "Columns"
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        // 27.2: shown, even if the autosave hid it, until the workspace appears: with the PDF collapsed as the window first lays
        // out the columns, the source never gets the toolbar's scroll edge, and its text stays sharp under the toolbar.
        columns.loaded = { [unowned self] in pdfItem.isCollapsed = false }
        // The last toolbar section's edge effect needs a safe area ending where the section does (27.2).
        columns.view.additionalSafeAreaInsets.right = ColumnMetrics.toolbarInset

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project), height: panelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        panelItem.holdingPriority = .defaultLow + 1

        area.splitView.isVertical = false
        area.splitView.autosaveName = "Area"
        let columnsItem = NSSplitViewItem(viewController: columns)
        columnsItem.minimumThickness = ColumnMetrics.columnsMinimum
        // Their text and the PDF's pages scroll on beneath it, and it rides up with them as the panel opens.
        let statusBar = accessory(StatusBar(project: project))
        // 27.2: AppKit's insets pad the bar but leave the panes' scrollers and safe area at the padded height.
        statusBar.automaticallyAppliesContentInsets = false
        // 27.2: AppKit gives an accessory's scroll edge to the scroll view of one toolbar section, and keeps it there once the
        // PDF has been hidden, so the other pane's text went sharp under the bar. The ground is the bar's own: a blur on a
        // plain view over the panes, as a background filter draws nothing on the accessory or inside it.
        statusBar.preferredScrollEdgeEffectStyle = .soft
        let ground = NSView()
        ground.blurBackdrop()
        ground.translatesAutoresizingMaskIntoConstraints = false
        columns.view.addSubview(ground)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: columns.view.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: columns.view.trailingAnchor),
            ground.bottomAnchor.constraint(equalTo: columns.view.bottomAnchor),
            ground.heightAnchor.constraint(equalToConstant: BarMetrics.height + BarMetrics.line),
        ])
        columnsItem.addBottomAlignedAccessoryViewController(statusBar)
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)
        area.loaded = { [unowned self] in if !project.panel.shown { panelItem.isCollapsed = true } }

        areaItem = NSSplitViewItem(viewController: area)
        addSplitViewItem(areaItem)
    }

    private func buildInspector() {
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project), mounted: app.inspectorVisible))
        inspectorItem.isCollapsed = !app.inspectorVisible
        // As the sidebar: a window too narrow for it folds it, and brings it back.
        inspectorItem.canCollapseFromWindowResize = true
    }

    private var panes: [NSSplitViewItem] { [sidebarItem, outlineItem, pdfItem, panelItem, inspectorItem] }

    /// The toolbar's toggles go through the model, as the menu's do.
    override func toggleSidebar(_ sender: Any?) {
        app.sidebarShown.toggle()
    }

    override func toggleInspector(_ sender: Any?) {
        app.inspectorShown.toggle()
    }

    /// SwiftUI whose sizes stay out of Auto Layout, so the split item's limits size it and its content never sets the window's minimum.
    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0, mounted: Bool? = nil) -> NSViewController {
        let mount = mounted.map(Mount.init)
        let host = NSHostingController(rootView: Mounted(mount: mount, content: content.environment(app)))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        if let mount { mounts[ObjectIdentifier(host)] = mount }
        return host
    }

    private func mount(_ controller: NSViewController, _ shown: Bool) {
        guard let mount = mounts[ObjectIdentifier(controller)], mount.shown != shown else { return }
        mount.shown = shown
        if shown { controller.view.layoutSubtreeIfNeeded() }
    }

    /// The header under the files' scroll edge, whose hairline stands for the sidebar split's divider (`SidebarSplitViewController`).
    /// Its content keeps one place under the line as the bar's height animates with the split, so folded it lines up with the
    /// status bar.
    private func buildOutlineBar() {
        let bar = NSView()
        let header = NSHostingView(rootView: OutlineHeader().environment(app))
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

    private func outlineBarHeight(folded: Bool) -> CGFloat {
        folded ? BarMetrics.height : OutlineHeader.openHeight
    }

    private func accessory(_ content: some View, hidden: Bool = false) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        let mount = hidden ? Mount(false) : nil
        if let mount { mounts[ObjectIdentifier(accessory)] = mount }
        let host = NSHostingView(rootView: Mounted(mount: mount, content: content.environment(app)))
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
            // Until the workspace appears, `viewDidAppear` has it.
            track({ app.showPDF }) { [weak self] visible in if let self, appeared { setCollapsed(pdfItem, !visible) } },
            track({ project.panel.shown }) { [weak self] in self?.setPanelShown($0) },
            track({ app.outlineState(of: project) }) { [weak self] in self?.setOutline($0) },
            track({ pdf.finding }) { [weak self] finding in if let self { setHidden(pdfFind, !finding) } },
            track({ app.searchFocusToken }, initial: false) { [weak self] _ in self?.focusSearch() },
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
        // Unanimated, the build panel changes layout without the live resize AppKit's animation starts even when instant (`setPanelShown` keeps its height).
        guard animates || item !== panelItem else {
            item.isCollapsed = collapsed
            view.layoutSubtreeIfNeeded()
            done()
            return
        }
        let id = ObjectIdentifier(item)
        if !collapsed { mount(item.viewController, true) }
        paneAnimation(true)
        NSAnimationContext.runAnimationGroup { context in
            if !animates { context.duration = 0 }
            // One animation carries the outline's pane and its header's height.
            if item === outlineItem {
                context.allowsImplicitAnimation = true
                outlineBarHeight.animator().constant = outlineBarHeight(folded: collapsed)
            }
            item.animator().isCollapsed = collapsed
            if item === outlineItem { sidebar.view.layoutSubtreeIfNeeded() }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return done() }
                if let item = self.panes.first(where: { ObjectIdentifier($0) == id }), item.isCollapsed {
                    self.mount(item.viewController, false)
                }
                self.paneAnimation(false)
                done()
            }
        }
    }

    /// 27.2: AppKit's split animation doesn't always reach the screen: with nothing else waking the run loop, a pane would hold still, then jump to its end.
    private func paneAnimation(_ running: Bool) {
        paneAnimations += running ? 1 : -1
        guard paneAnimations == (running ? 1 : 0) else { return }
        if running {
            paneFrames = view.displayLink(target: self, selector: #selector(paneFrame))
            paneFrames?.add(to: .main, forMode: .common)
        } else {
            paneFrames?.invalidate()
            paneFrames = nil
            fitColumns()
        }
    }

    @objc private func paneFrame(_ link: CADisplayLink) {
        for split in splitViews { split.needsLayout = true }
    }

    private var splitViews: [NSSplitView] { [splitView, sidebar.splitView, columns.splitView, area.splitView] }

    /// The pane folds down under its header to the sidebar's foot, and opens up from there.
    private func setOutline(_ state: OutlineState) {
        setHidden(outlineBar, state == .hidden)
        setCollapsed(outlineItem, state != .open)
    }

    /// A hidden accessory only folds to no height, and its controls would stay in the key view loop and VoiceOver.
    private func setHidden(_ accessory: NSSplitViewItemAccessoryViewController, _ hidden: Bool) {
        guard accessory.isHidden != hidden else { return }
        if !hidden {
            mount(accessory, true)
            accessory.view.isHidden = false
        }
        guard animates else {
            accessory.isHidden = hidden
            accessory.view.isHidden = hidden
            if hidden { mount(accessory, false) }
            return
        }
        paneAnimation(true)
        NSAnimationContext.runAnimationGroup { _ in
            accessory.animator().isHidden = hidden
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if hidden, accessory.isHidden {
                    accessory.view.isHidden = true
                    self?.mount(accessory, false)
                }
                self?.paneAnimation(false)
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

    private var animates: Bool {
        view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func focusField(_ field: FieldHandle, in accessory: NSSplitViewItemAccessoryViewController) {
        if field.field == nil { accessory.view.layoutSubtreeIfNeeded() }
        field.focus()
    }

    private func focusSearch() {
        setCollapsed(sidebarItem, false)
        focusField(searchField, in: sidebarSearch)
    }

    func hostsFindField(_ field: NSTextField) -> Bool {
        field.isDescendant(of: pdfFind.view)
    }

    /// A split animation still running finishes after its window has gone and would save its frames over the next window's.
    func close() {
        for split in splitViews { split.autosaveName = nil }
        paneFrames?.invalidate()
        paneFrames = nil
        watches.forEach { $0.cancel() }
        app.performPDF = nil
        // The next workspace's columns are AppKit's to fold afresh: it brings back only what it folded.
        (app.sidebarFolded, app.inspectorFolded) = (false, false)
        collapses = []
        resizes = []
        toolbar.close()
    }

    // MARK: - Find

    func findAction(_ item: any NSValidatedUserInterfaceItem) -> (() -> Void)? {
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return nil }
        guard pdfHasKeyboard else {
            guard project.editsText else {
                guard action == .showFindInterface, project.hasPDF else { return nil }
                return { [weak self] in self?.app.requestPDF(.find) }
            }
            let editor = project.editor
            guard editor.textView.validateUserInterfaceItem(item) else { return nil }
            return {
                editor.focus()
                editor.textView.performFindPanelAction(item)
            }
        }
        guard project.hasPDF else { return nil }
        switch action {
        case .showFindInterface:
            return { [weak self] in self?.showPDFFind() }
        case .nextMatch, .previousMatch:
            guard pdf.canFindNext else { return nil }
            return { [pdf] in pdf.findNext(action == .nextMatch ? 1 : -1) }
        case .setSearchString:
            guard pdf.canUseSelectionForFind else { return nil }
            return { [pdf] in pdf.useSelectionForFind() }
        default:
            return nil
        }
    }

    private var pdfHasKeyboard: Bool {
        guard !pdfItem.isCollapsed, let first = view.window?.firstResponder as? NSView else { return false }
        return first.isDescendant(of: pdfItem.viewController.view) || first.isDescendant(of: pdfFind.view)
    }

    var pdfPagesHaveKeyboard: Bool {
        (view.window?.firstResponder as? NSView)?.isDescendant(of: pdf.view) == true
    }

    private func showPDFFind() {
        pdf.finding = true
        setHidden(pdfFind, false)
        focusField(pdf.findField, in: pdfFind)
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
            case .find: showPDFFind()
            case let .reveal(loc, source): pdf.reveal(loc, from: source)
            case .inverseFromView:
                if case let (page, point)? = pdf.sourcePoint() {
                    Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
                }
            }
        }
    }
}

/// Hidden, a hosting view still updates all of its content for every appearance or environment change (27.2: 20 ms for the folded inspector).
@Observable final class Mount {
    var shown: Bool
    init(_ shown: Bool) { self.shown = shown }
}

private struct Mounted<Content: View>: View {
    let mount: Mount?
    let content: Content

    var body: some View {
        if mount?.shown ?? true { content }
    }
}
