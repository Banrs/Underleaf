import AppKit
import PDFKit
import SwiftUI

extension NSView {
    /// TextKit and PDFKit still receive tracking events just inside the panes and replace the divider cursor,
    /// so only the actual divider hit target may choose the resize cursor.
    @discardableResult
    func updateDividerCursor(with event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, let workspace = window.contentView, let content = workspace.superview,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
        // Toolbar cursor tracking owns views outside the workspace content.
        guard hit.isDescendant(of: workspace) else { return true }
        if let split = hit as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2,
           split.arrangedSubviews.allSatisfy({ !split.isSubviewCollapsed($0) }), isDescendant(of: split) {
            let position = split.arrangedSubviews[0].frame.maxX
            var directions: NSHorizontalDirection.Set = []
            if position > split.minPossiblePositionOfDivider(at: 0) { directions.insert(.left) }
            if position < split.maxPossiblePositionOfDivider(at: 0) { directions.insert(.right) }
            guard !directions.isEmpty else { return false }
            NSCursor.columnResize(directions: directions).set()
            return true
        }
        // NSTextView also receives mouse moves over its overlay scroller and, while first responder, over the PDF.
        if hit is NSScroller { NSCursor.arrow.set(); return true }
        if let pdf = sequence(first: hit, next: \.superview).first(where: { $0 is PDFView }) as? PDFView,
           self is NSTextView || NSCursor.isResizingColumn {
            pdf.setCursorFor(pdf.areaOfInterest(forMouse: event))
            return true
        }
        // Crossing the overlap need not enter a new pane tracking area: return a lingering resize cursor to the real hit view.
        if NSCursor.isResizingColumn {
            if hit is NSTextView || hit is NSTextField { NSCursor.iBeam.set() }
            else { NSCursor.arrow.set() }
        }
        return false
    }
}

extension NSCursor {
    static var isResizingColumn: Bool {
        current == .columnResize || current == .columnResize(directions: .left) || current == .columnResize(directions: .right)
    }
}

final class WorkspaceController: RestoredSplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    private(set) var toolbar: WorkspaceToolbar!

    let columns = RestoredSplitViewController(splitView: ColumnsSplitView())
    private let area = RestoredSplitViewController()
    private let sidebar = SidebarSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var outlineItem: NSSplitViewItem!
    private var sourceItem: NSSplitViewItem!
    private var pdfItem: NSSplitViewItem!
    private var panelItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
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

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        super.init()
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
        fixed = { [unowned self] divider in divider == splitViewItems.firstIndex(of: inspectorItem)! - 1 }
        columns.detent = { [unowned columns] _ in (columns.splitView as? ColumnsSplitView)?.openingPosition }
        toolbar = WorkspaceToolbar(app: app, project: project, workspace: self)
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The autosave restores which panes were collapsed as each split loads; the side columns are the split's alone from there.
    override func viewDidLoad() {
        super.viewDidLoad()
        collapses = [
            follow(sidebarItem) { [unowned self] in app.sidebarShown = $0 },
            follow(inspectorItem) { [unowned self] visible in
                if visible { mount(inspectorItem.viewController, true) }
                app.inspectorShown = visible
            },
            follow(pdfItem) { [unowned self] _ in fitColumns() },
        ]
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
        sidebar.loaded = { [unowned self] in if OutlineState(app, project) != .open { outlineItem.isCollapsed = true } }
        sidebar.view.frame.size.width = ColumnMetrics.sidebarIdeal
        sidebar.header = outlineBar

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = ColumnMetrics.sidebarMinimum
        sidebarSearch = accessory(SearchField(text: Bindable(project.search).query, prompt: "Search Project", handle: searchField))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    private func buildArea(size: CGSize) {
        // As a first launch opens: the autosave puts the columns as they were afterwards.
        let sidebarWidth = sidebarItem.isCollapsed ? 0 : ColumnMetrics.sidebarIdeal
        let inspectorWidth = inspectorItem.isCollapsed ? 0 : inspectorItem.minimumThickness
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
        columnsItem.addBottomAlignedAccessoryViewController(statusBar)
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)
        area.loaded = { [unowned self] in if !project.panel.shown { panelItem.isCollapsed = true } }

        areaItem = NSSplitViewItem(viewController: area)
        addSplitViewItem(areaItem)
    }

    /// Hidden until shown once: the autosave brings it back as it was.
    private func buildInspector() {
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project), mounted: false))
        inspectorItem.isCollapsed = true
        inspectorItem.canCollapseFromWindowResize = true
    }

    private var panes: [NSSplitViewItem] { [sidebarItem, outlineItem, pdfItem, panelItem, inspectorItem] }

    override func toggleSidebar(_ sender: Any?) {
        setCollapsed(sidebarItem, !sidebarItem.isCollapsed)
    }

    override func toggleInspector(_ sender: Any?) {
        setCollapsed(inspectorItem, !inspectorItem.isCollapsed)
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
        outlineBarHeight = bar.heightAnchor.constraint(equalToConstant: outlineBarHeight(folded: OutlineState(app, project) != .open))
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
            // Until the workspace appears, `viewDidAppear` has it.
            track({ app.showPDF }) { [weak self] visible in if let self, appeared { setCollapsed(pdfItem, !visible) } },
            track({ project.panel.shown }) { [weak self] in self?.setPanelShown($0) },
            track({ OutlineState(app, project) }) { [weak self] in self?.setOutline($0) },
            track({ pdf.finding }) { [weak self] finding in if let self { setHidden(pdfFind, !finding) } },
            track({ app.searchFocusToken }, initial: false) { [weak self] _ in self?.focusSearch() },
        ]
        app.performPDF = { [weak self] in self?.performPDF($0) }
        app.showSideColumn = { [weak self] column, shown in
            guard let self else { return }
            setCollapsed(column == .sidebar ? sidebarItem : inspectorItem, !shown)
        }
    }

    private func follow(_ item: NSSplitViewItem, _ shown: @escaping @MainActor (Bool) -> Void) -> NSKeyValueObservation {
        item.observe(\.isCollapsed, options: [.initial, .new]) { _, change in
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
        app.showSideColumn = nil
        collapses = []
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

/// The File Outline: open in its pane, folded to its header, or hidden with its header while the sidebar shows search results.
/// A file that isn't LaTeX folds it to its header, dim (`OutlineHeader`): the sidebar keeps its foot from one file to the next.
private nonisolated enum OutlineState {
    case open, folded, hidden

    @MainActor init(_ app: AppModel, _ project: ProjectModel) {
        self = project.search.isSearching ? .hidden : app.outlineCollapsed || !project.isLaTeX ? .folded : .open
    }
}

/// AppKit has no split detents: a drag that comes near `detent`, a divider's opening position, stops there, with the alignment haptic as it arrives.
class RestoredSplitViewController: NSSplitViewController {
    var loaded: () -> Void = {}
    var detent: (_ divider: Int) -> CGFloat? = { _ in nil }
    /// A divider that takes no drag, and so shows no resize cursor.
    var fixed: (_ divider: Int) -> Bool = { _ in false }

    init(splitView: NSSplitView = NSSplitView()) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        self.splitView = splitView
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        loaded()
    }

    /// 27.2: NSSplitViewController declares this, as the split's delegate, without implementing it, so there is no super to call.
    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                            ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard let detent = detent(dividerIndex),
              abs(proposedPosition - detent) <= ColumnMetrics.detentReach else { return proposedPosition }
        // Once, as the divider arrives: not on each step of a drag held there.
        let pane = splitView.arrangedSubviews[dividerIndex].frame
        if abs((splitView.isVertical ? pane.maxX : pane.maxY) - detent) >= 0.5 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
        }
        return detent
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        fixed(dividerIndex) ? .zero
            : super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
    }
}

/// Files over the File Outline. The files' scroll-edge hairline over the outline's header stands for the divider: AppKit has
/// no thin divider that draws no line, so the divider's own, under the header, isn't drawn, and it takes drags at the hairline.
private final class SidebarSplitViewController: RestoredSplitViewController {
    weak var header: NSSplitViewItemAccessoryViewController?

    private final class SplitView: NSSplitView {
        override func drawDivider(in rect: NSRect) {}
    }

    init() {
        super.init(splitView: SplitView())
    }

    required init?(coder: NSCoder) { fatalError() }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect,
                                   ofDividerAt: dividerIndex)
        // Folded, the outline opens only from its header.
        guard let header, !header.isHidden, splitViewItems.last?.isCollapsed == false else { return .zero }
        // The header's top, in the split view's flipped coordinates.
        let line = header.view.convert(header.view.bounds, to: splitView).minY
        return rect.offsetBy(dx: 0, dy: line - drawnRect.minY)
    }
}

private final class ColumnsSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        var shown = rect
        // Short of the bar and the line over it, at its foot: a split view is flipped.
        shown.size.height -= BarMetrics.height + BarMetrics.line
        super.drawDivider(in: shown)
    }

    /// 27.2: the items' preferred fractions, AppKit's own way, land the divider somewhere else each time.
    override func mouseDown(with event: NSEvent) {
        // On the divider, which takes presses 2 pt either side of its line: a pane passes up its own.
        let past = convert(event.locationInWindow, from: nil).x - (arrangedSubviews.first?.frame.maxX ?? 0)
        guard event.clickCount == 2, -2...dividerThickness + 2 ~= past, arrangedSubviews.allSatisfy({ !isSubviewCollapsed($0) }) else {
            return super.mouseDown(with: event)
        }
        setPosition(openingPosition, ofDividerAt: 0)
    }

    var openingPosition: CGFloat {
        ((bounds.width - dividerThickness) * (1 - ColumnMetrics.pdfShare)).rounded()
    }
}

enum ColumnMetrics {
    /// The sidebar opens at the width of AppKit's inspector (27.2), so the side columns frame the editors alike.
    static let sidebarIdeal: CGFloat = 270
    static let sidebarMinimum: CGFloat = 222
    static let detentReach: CGFloat = 8
    static let windowControls: CGFloat = 132
    static let sourceMinimum: CGFloat = 260
    /// In a narrower window AppKit takes Compile and then Back to the overflow menu too (27.2).
    static let toolbarMinimum: CGFloat = 542
    static let pdfMinimum: CGFloat = 188
    /// With the sidebar open the PDF's tools need more than its minimum (27.2).
    static let pdfRoom: CGFloat = 200
    static let pdfShare: CGFloat = 0.5
    static let columnsMinimum: CGFloat = 200
    static let panelMinimum: CGFloat = 140
    static let panelShare: CGFloat = 0.25
    static let filesMinimum: CGFloat = 100
    static let outlineMinimum: CGFloat = 80
    static let outlineShare: CGFloat = 0.45
    static let toolbarInset: CGFloat = 0.5
    /// A window on its way there folds the sidebar and the inspector, as Mail's does.
    static let contentMinimum = CGSize(width: toolbarMinimum, height: 400)
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
