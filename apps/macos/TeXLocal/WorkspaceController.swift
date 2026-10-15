import AppKit
import PDFKit
import SwiftUI

extension NSView {
    /// Native thin dividers accept drags just inside their panes. TextKit and
    /// PDFKit still receive tracking events there and replace the divider cursor.
    /// Only the actual divider hit target may choose the resize cursor.
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
        // NSTextView also receives mouse moves over its overlay scroller and,
        // while first responder, over the PDF. Keep the actual hit view in charge.
        if hit is NSScroller { NSCursor.arrow.set(); return true }
        if let pdf = sequence(first: hit, next: \.superview).first(where: { $0 is PDFView }) as? PDFView,
           self is NSTextView || NSCursor.isResizingColumn {
            pdf.setCursorFor(pdf.areaOfInterest(forMouse: event))
            return true
        }
        // Crossing the overlap need not enter a new pane tracking area. Return
        // a lingering resize cursor to the real hit view, including scrollers.
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

/// Sidebar | source | PDF, with their status bar, over the build panel | inspector.
/// Find bars belong to their columns; AppKit animates model-driven collapses
/// and keeps each split's divider positions across launches (`autosaveName`).
final class WorkspaceController: RestoredSplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    private(set) var toolbar: WorkspaceToolbar!

    let columns = RestoredSplitViewController(splitView: ColumnsSplitView())
    private let area = RestoredSplitViewController()
    private let sidebar = RestoredSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var outlineItem: NSSplitViewItem!
    /// The File Outline's height open, kept while it is folded (`foldOutline`).
    private var outlineHeight: CGFloat = 0
    private var sourceItem: NSSplitViewItem!
    private var pdfItem: NSSplitViewItem!
    private var panelItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    /// Source and PDF, with their status bar, over the build panel.
    private var areaItem: NSSplitViewItem!
    private var sidebarSearch: NSSplitViewItemAccessoryViewController!
    private var pdfFind: NSSplitViewItemAccessoryViewController!
    /// Content there only while it shows (`Mount`): the panes that hide (`host(mounted:)`) and
    /// the PDF find bar's.
    private var mounts: [ObjectIdentifier: Mount] = [:]
    private let searchField = FieldHandle()

    /// The panel's height as it was hidden, or its first (`setPanelShown`).
    private var panelHeight: CGFloat = 0
    /// Pane animations running and the frames laying out the split views (`paneAnimation`).
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
        // AppKit's fixed inspector takes no drag, nor the folded File Outline.
        fixed = { [unowned self] divider in divider == splitViewItems.firstIndex(of: inspectorItem)! - 1 }
        sidebar.fixed = { [unowned self] _ in outlineItem.maximumThickness == ColumnMetrics.outlineFolded }
        columns.detent = { [unowned columns] _ in (columns.splitView as? ColumnsSplitView)?.openingPosition }
        toolbar = WorkspaceToolbar(app: app, project: project, workspace: self)
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The autosave restores which panes were collapsed as each split loads. The side columns are
    /// the split's alone, saved by it, folded and brought back by AppKit as the window narrows and
    /// widens; the menus are told as they open and shut, whoever asked.
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

    /// The PDF the model hides goes once the columns have been laid out in the window (`buildArea`).
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !appeared else { return }
        appeared = true
        if !app.showPDF { pdfItem.isCollapsed = true }
        fitColumns()
    }

    private var appeared = false

    /// The window stops at the toolbar's least (`ColumnMetrics.contentMinimum`), which is wider
    /// than the panes' whichever of them show. AppKit folds the side columns on the way there, by
    /// the area's own minimum; with the sidebar open the window controls are over it.
    private func fitColumns() {
        let pdf = pdfItem.isCollapsed ? 0 : columns.splitView.dividerThickness + ColumnMetrics.pdfRoom
        let panes = sourceItem.minimumThickness + pdf + ColumnMetrics.toolbarInset
        let area = max(panes, ColumnMetrics.toolbarMinimum - ColumnMetrics.windowControls)
        if areaItem.minimumThickness != area { areaItem.minimumThickness = area }
    }

    // ---------- layout ----------

    /// Search over the files over the File Outline. A pane's size is its view's frame
    /// as it's added: the split opens it there, and a collapsed one shows there first.
    private func buildSidebar(height: CGFloat) {
        sidebar.splitView.isVertical = false
        sidebar.splitView.autosaveName = "Sidebar"
        let filesItem = NSSplitViewItem(viewController: host(FilesList(project: project)))
        filesItem.minimumThickness = ColumnMetrics.filesMinimum
        outlineHeight = (height * ColumnMetrics.outlineShare).rounded()
        outlineItem = NSSplitViewItem(viewController: host(OutlineList(project: project), height: outlineHeight))
        outlineItem.minimumThickness = ColumnMetrics.outlineMinimum
        // It keeps its height as the window resizes; the files take the change.
        outlineItem.holdingPriority = .defaultLow + 1
        sidebar.addSplitViewItem(filesItem)
        sidebar.addSplitViewItem(outlineItem)
        // A workspace opens with no search results, which alone hide the outline.
        sidebar.loaded = { [unowned self] in foldOutline(OutlineState(app, project) != .open) }
        sidebar.view.frame.size.width = ColumnMetrics.sidebarIdeal

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
        // Shown, even if the autosave hid it, until the workspace appears (`viewDidAppear`): with the PDF
        // collapsed as the window first lays out the columns, the source never gets the toolbar's
        // scroll edge, and its text stays sharp under the toolbar (27.2).
        columns.loaded = { [unowned self] in pdfItem.isCollapsed = false }
        // The last toolbar section's edge effect needs a safe area ending where the section does (27.2).
        columns.view.additionalSafeAreaInsets.right = ColumnMetrics.toolbarInset

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project), height: panelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        // It keeps its height as the window resizes; the columns take the change.
        panelItem.holdingPriority = .defaultLow + 1

        area.splitView.isVertical = false
        area.splitView.autosaveName = "Area"
        let columnsItem = NSSplitViewItem(viewController: columns)
        // The panel dragged up stops short of the find bar and a few lines.
        columnsItem.minimumThickness = ColumnMetrics.columnsMinimum
        // The editors' own bar, at their foot: their text and the PDF's pages scroll on beneath it
        // and their scrollers end at its top. It rides up with them as the panel opens, as Xcode's
        // does over its debug area, so nothing under it changes and it never changes its look.
        let statusBar = accessory(StatusBar(project: project))
        // Its own height, the bar's under its line's, and the folded File Outline's header is as high
        // as the bar (`BarMetrics.height`): AppKit's insets pad the bar but leave the panes' scrollers
        // and safe area at the padded height (27.2).
        statusBar.automaticallyAppliesContentInsets = false
        // Under the bar, AppKit's own scroll edge, its automatic style, as under the toolbar over
        // the same panes: the bar draws no ground of its own, only its line (`StatusBar`).
        columnsItem.addBottomAlignedAccessoryViewController(statusBar)
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)
        area.loaded = { [unowned self] in if !project.panel.shown { panelItem.isCollapsed = true } }

        areaItem = NSSplitViewItem(viewController: area)
        addSplitViewItem(areaItem)
    }

    /// AppKit's fixed inspector width fits its settings and facts. Hidden until shown once: the
    /// autosave brings it back as it was.
    private func buildInspector() {
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project), mounted: false))
        inspectorItem.isCollapsed = true
        // As the sidebar: a window too narrow for it folds it, and brings it back.
        inspectorItem.canCollapseFromWindowResize = true
    }

    /// The panes that collapse.
    private var panes: [NSSplitViewItem] { [sidebarItem, outlineItem, pdfItem, panelItem, inspectorItem] }

    /// The toolbar's toggles and the menu's go through `setCollapsed`, so the panes animate and the
    /// inspector's content leaves once it has shut.
    override func toggleSidebar(_ sender: Any?) {
        setCollapsed(sidebarItem, !sidebarItem.isCollapsed)
    }

    override func toggleInspector(_ sender: Any?) {
        setCollapsed(inspectorItem, !inspectorItem.isCollapsed)
    }

    /// A pane: SwiftUI whose sizes stay out of Auto Layout, so the split item's
    /// limits size it and its content never sets the window's minimum.
    /// `mounted`, for a pane that hides: its content there only while it shows.
    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0, mounted: Bool? = nil) -> NSViewController {
        let mount = mounted.map(Mount.init)
        let host = NSHostingController(rootView: Mounted(mount: mount, content: content.environment(app)))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        if let mount { mounts[ObjectIdentifier(host)] = mount }
        return host
    }

    /// A pane's or bar's content goes in before it shows, and out once it has hidden.
    private func mount(_ controller: NSViewController, _ shown: Bool) {
        guard let mount = mounts[ObjectIdentifier(controller)], mount.shown != shown else { return }
        mount.shown = shown
        // In at its size before AppKit measures it to show.
        if shown { controller.view.layoutSubtreeIfNeeded() }
    }

    /// A pane bar sized to its content, inside AppKit's standard accessory insets. `hidden`, for
    /// one that comes and goes: its content there only while it shows.
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

    // ---------- the models drive the panes ----------

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

    /// A pane as it shuts or opens, whoever asked: the model, a drag or the window.
    private func follow(_ item: NSSplitViewItem, _ shown: @escaping @MainActor (Bool) -> Void) -> NSKeyValueObservation {
        item.observe(\.isCollapsed, options: [.initial, .new]) { _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated { shown(!collapsed) }
        }
    }

    /// Through AppKit's collapse animation, which brings a pane back at the size it
    /// was hidden at; instantly when the window isn't on screen or Reduce Motion is
    /// on. `done` runs once the pane is at its size.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, done: @escaping @MainActor () -> Void = {}) {
        // Repeated model notifications must not snap an animation already heading here.
        guard item.isCollapsed != collapsed else { return done() }
        // Unanimated, the build panel changes layout without the live resize AppKit's
        // animation starts even when instant (`setPanelShown` keeps its height).
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
            item.animator().isCollapsed = collapsed
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

    /// AppKit's split animation doesn't always reach the screen: with nothing else waking the
    /// run loop, a pane would hold still, then jump to its end (27.2). Laid out on every frame
    /// meanwhile, the panes keep up with it.
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

    /// Search results take the whole sidebar; otherwise the outline is there, open or folded.
    private func setOutline(_ state: OutlineState) {
        guard state != .hidden else { return setCollapsed(outlineItem, true) }
        setCollapsed(outlineItem, false) { [weak self] in self?.foldOutline(state == .folded) }
    }

    /// Folded, the outline is its header at the sidebar's foot, as high as the status bar, whose
    /// line its divider meets; open, it goes up from there to the height it had.
    private func foldOutline(_ folded: Bool) {
        guard folded != (outlineItem.maximumThickness == ColumnMetrics.outlineFolded) else { return }
        if folded {
            let height = outlineItem.viewController.view.frame.height
            if height >= ColumnMetrics.outlineMinimum { outlineHeight = height }
            (outlineItem.minimumThickness, outlineItem.maximumThickness) = (ColumnMetrics.outlineFolded, ColumnMetrics.outlineFolded)
        } else {
            (outlineItem.minimumThickness, outlineItem.maximumThickness) = (ColumnMetrics.outlineMinimum, NSSplitViewItem.unspecifiedDimension)
            let split = sidebar.splitView
            split.setPosition(split.bounds.height - split.dividerThickness - outlineHeight, ofDividerAt: 0)
        }
    }

    /// The bar's view hides too: a hidden accessory only folds to no height, and its
    /// controls would stay in the key view loop and VoiceOver.
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

    /// The panel rises under the editors and their status bar through AppKit's animation, which
    /// brings it back at its hosted view's height, and unanimated at its minimum, so the height it was hidden
    /// at is kept here.
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

    /// Layout makes a newly shown accessory's field ready to take the keyboard.
    private func focusField(_ field: FieldHandle, in accessory: NSSplitViewItemAccessoryViewController) {
        if field.field == nil { accessory.view.layoutSubtreeIfNeeded() }
        field.focus()
    }

    /// The field takes the keyboard at once, so typing during the sidebar's animation lands in it.
    private func focusSearch() {
        setCollapsed(sidebarItem, false)
        focusField(searchField, in: sidebarSearch)
    }

    func hostsFindField(_ field: NSTextField) -> Bool {
        field.isDescendant(of: pdfFind.view)
    }

    /// A split animation still running finishes after its window has gone and
    /// would save its frames as they stood then, over the next window's.
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

    // ---------- find ----------

    /// Edit › Find's items when the source text, which answers them itself, doesn't
    /// have the keyboard: the PDF's while its pages or its find bar have it, else
    /// the source's find bar, or the PDF's over a preview. Nil turns an item off.
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

    /// The pages alone, where Jump to Selection is the PDF's (`MainWindowController`): in the
    /// find bar the field's editor centres its own selection.
    var pdfPagesHaveKeyboard: Bool {
        (view.window?.firstResponder as? NSView)?.isDescendant(of: pdf.view) == true
    }

    private func showPDFFind() {
        pdf.finding = true
        setHidden(pdfFind, false)
        focusField(pdf.findField, in: pdfFind)
    }

    // ---------- the menus' PDF requests ----------

    /// After a hidden column has opened to its width.
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
            case let .reveal(loc, word): pdf.reveal(loc, word: word)
            case .inverseFromView:
                if case let (page, point)? = pdf.sourcePoint() {
                    Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
                }
            }
        }
    }
}

/// The File Outline: open in its pane, folded to its header, or hidden with its header while
/// the sidebar shows search results. A file with no outline, one that isn't LaTeX, folds it to
/// its header, dim (`OutlineList`): the sidebar keeps its foot from one file to the next.
private nonisolated enum OutlineState {
    case open, folded, hidden

    @MainActor init(_ app: AppModel, _ project: ProjectModel) {
        self = project.search.isSearching ? .hidden : app.outlineCollapsed || !project.isLaTeX ? .folded : .open
    }
}

/// A split whose autosave has restored its panes as its view loads; `loaded`
/// then hides the ones its owner's models hide.
///
/// AppKit has no split detents: a drag that comes near `detent`, a divider's opening
/// position, stops there, with the alignment haptic as it arrives.
class RestoredSplitViewController: NSSplitViewController {
    var loaded: () -> Void = {}
    var detent: (_ divider: Int) -> CGFloat? = { _ in nil }
    /// A divider that takes no drag, and so shows no resize cursor.
    var fixed: (_ divider: Int) -> Bool = { _ in false }

    /// NSSplitViewController's own: side by side, with the thin divider.
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

    /// NSSplitViewController declares this, as the split's delegate, without implementing it (27.2:
    /// its instances don't respond to it), so there is no super to call.
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

/// Source | PDF. The status bar spans both panes as one bar, so their divider stops at its top.
private final class ColumnsSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        var shown = rect
        // Short of the bar and the line over it, at its foot: a split view is flipped.
        shown.size.height -= BarMetrics.height + BarMetrics.line
        super.drawDivider(in: shown)
    }

    /// A double-click on the divider brings the first split back. The items' preferred
    /// fractions, AppKit's own way, land it somewhere else each time (27.2).
    override func mouseDown(with event: NSEvent) {
        // On the divider, which takes presses 2 pt either side of its line: a pane passes up its own.
        let past = convert(event.locationInWindow, from: nil).x - (arrangedSubviews.first?.frame.maxX ?? 0)
        guard event.clickCount == 2, -2...dividerThickness + 2 ~= past, arrangedSubviews.allSatisfy({ !isSubviewCollapsed($0) }) else {
            return super.mouseDown(with: event)
        }
        setPosition(openingPosition, ofDividerAt: 0)
    }

    /// Where the divider stands at first: a double-click brings it back, and a drag stops there (`detent`).
    var openingPosition: CGFloat {
        ((bounds.width - dividerThickness) * (1 - ColumnMetrics.pdfShare)).rounded()
    }
}

/// Pane sizes, from what each pane shows, and the toolbar's least, measured (27.2).
enum ColumnMetrics {
    /// The sidebar opens at the width of AppKit's inspector (27.2), so the side columns frame
    /// the editors alike; its narrowest is Xcode's navigator's.
    static let sidebarIdeal: CGFloat = 270
    static let sidebarMinimum: CGFloat = 222
    /// Catches a drag aimed at a detent without trapping one passing through.
    static let detentReach: CGFloat = 8
    /// The window controls and the sidebar toggle, over the source while the sidebar is hidden.
    static let windowControls: CGFloat = 132
    /// The line numbers and some 25 characters at the default size.
    static let sourceMinimum: CGFloat = 260
    /// The toolbar with all it can spare in its overflow menu: the window controls, Back, AppKit's
    /// narrowest title, the menu's chevron, Compile and the toggles. In a narrower window AppKit
    /// takes Compile and then Back there too (27.2), measured.
    static let toolbarMinimum: CGFloat = 542
    /// A page readable at Fit Width, and room for Compile and the toggles: what the narrowest
    /// window leaves beside the source's section of the toolbar (542 less 352 and the divider).
    static let pdfMinimum: CGFloat = 188
    /// What the area keeps for the PDF beside the source at its least: with the sidebar open the
    /// PDF's tools need more than its minimum (27.2).
    static let pdfRoom: CGFloat = 200
    static let pdfShare: CGFloat = 0.5
    /// Source and PDF over the build panel: a find bar and a few lines.
    static let columnsMinimum: CGFloat = 200
    /// The build panel: a few rows over its bar; a quarter of the window at first.
    static let panelMinimum: CGFloat = 140
    static let panelShare: CGFloat = 0.25
    /// The sidebar's panes: a few rows each; the outline nearly half at first.
    static let filesMinimum: CGFloat = 100
    static let outlineMinimum: CGFloat = 80
    static let outlineShare: CGFloat = 0.45
    /// The File Outline folded to its header: the status bar's height, so their lines meet.
    static let outlineFolded = BarMetrics.height
    /// The columns' trailing safe-area inset, for the last column's toolbar section (`buildArea`).
    static let toolbarInset: CGFloat = 0.5
    /// The narrowest window, with the PDF or without: the toolbar's least is wider than the
    /// panes'. A window on its way there folds the sidebar and the inspector, as Mail's does
    /// (HIG, Sidebars). The height holds the sidebar's two lists under its search field, and the
    /// editors over the build panel at its least.
    static let contentMinimum = CGSize(width: toolbarMinimum, height: 400)
}

/// Whether a pane's SwiftUI content is there: hidden, a hosting view still updates all of it
/// for every appearance or environment change (measured on 27.2: 20 ms for the folded inspector).
@Observable final class Mount {
    var shown: Bool
    init(_ shown: Bool) { self.shown = shown }
}

/// The content, while its `Mount` shows it; always, without one.
private struct Mounted<Content: View>: View {
    let mount: Mount?
    let content: Content

    var body: some View {
        if mount?.shown ?? true { content }
    }
}
