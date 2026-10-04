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

extension NSScrollView {
    /// Live resize shows overlay scrollers, and they stay a moment after it: a refit on
    /// each step of a drag, or a split's animation, would flash them. They keep out of
    /// sight meanwhile and come back at rest, as a scroller given to a scroll view starts.
    /// Legacy scrollers always show.
    func hideOverlayScrollers(_ hidden: Bool) {
        guard scrollerStyle == .overlay else { return }
        for key in [\NSScrollView.verticalScroller, \NSScrollView.horizontalScroller] {
            guard let scroller = self[keyPath: key] else { continue }
            if !hidden {
                self[keyPath: key] = NSScroller()
                self[keyPath: key] = scroller
            }
            scroller.alphaValue = hidden ? 0 : 1
        }
    }
}

extension NSCursor {
    static var isResizingColumn: Bool {
        current == .columnResize || current == .columnResize(directions: .left) || current == .columnResize(directions: .right)
    }
}

/// Sidebar | source | PDF over the build panel and status bar | inspector.
/// Find bars belong to their columns; AppKit animates model-driven collapses
/// and keeps each split's divider positions across launches (`autosaveName`).
final class WorkspaceController: RestoredSplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    private(set) var toolbar: WorkspaceToolbar!

    let columns = RestoredSplitViewController()
    let area = RestoredSplitViewController()
    private let sidebar = SidebarSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var outlineItem: NSSplitViewItem!
    private(set) var sourceItem: NSSplitViewItem!
    private(set) var pdfItem: NSSplitViewItem!
    private(set) var panelItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    /// Source and PDF over the build panel and status bar.
    private var areaItem: NSSplitViewItem!
    private var sidebarSearch: NSSplitViewItemAccessoryViewController!
    /// The File Outline's header at the files' foot, and its height: as the outline's
    /// first row's room when open, the status bar's when folded.
    private var outlineBar: NSSplitViewItemAccessoryViewController!
    private var outlineBarHeight: NSLayoutConstraint!
    private var pdfFind: NSSplitViewItemAccessoryViewController!
    private var panelHeader: NSSplitViewItemAccessoryViewController!
    private let panelState = BuildPanelState()
    private let searchField = FieldHandle()

    /// The panel's height as it was hidden, or its first (`setPanelShown`).
    private var panelHeight: CGFloat = 0
    /// Pane animations running and the frames laying out the split views (`paneAnimation`);
    /// those and drags keeping the scroll views' scrollers out of sight until the last ends (`quiet`).
    private var paneAnimations = 0
    private var quieting = 0
    private var quietScrollViews: [NSScrollView] = []
    private var paneFrames: CADisplayLink?
    private var watches: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []
    private var resizes: (any NSObjectProtocol)?
    /// The sidebar folded as the window narrowed, rather than hidden (`fitColumnsToToolbar`).
    private var sidebarFoldedByWindow = false

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        super.init()
        splitView.autosaveName = "Workspace"
        buildSidebar(height: size.height)
        // Before the area, which opens in the room the side columns leave; added after it.
        buildInspector()
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
        for item in [sidebarItem, outlineItem, pdfItem, panelItem, inspectorItem] {
            item?.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        }
        // The opening sizes: the sidebar's width, and source and PDF in halves.
        detent = { [unowned self] divider in
            divider == 0 && !sidebarItem.isCollapsed ? ColumnMetrics.sidebarIdeal : nil
        }
        columns.detent = { [unowned columns] _ in
            let split = columns.splitView
            return ((split.bounds.width - split.dividerThickness) / 2).rounded(.down)
        }
        // A drag resizes the panes live, which would show their overlay scrollers: no scrolling happens.
        for split in [self, columns, area, sidebar] as [RestoredSplitViewController] {
            split.dragging = { [weak self] in self?.quiet($0) }
        }
        toolbar = WorkspaceToolbar(app: app, project: project, workspace: self)
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The autosave restores which panes were collapsed as each split loads, but
    /// the models say which show: those they hide collapse at once, and the tracks
    /// (`watch`) bring back those they show at their sizes. The model follows the
    /// side columns from here on.
    override func viewDidLoad() {
        super.viewDidLoad()
        if !app.sidebarVisible { sidebarItem.isCollapsed = true }
        if !app.inspectorVisible { inspectorItem.isCollapsed = true }
        collapses = [
            follow(sidebarItem) { [unowned self] visible in
                // A narrowing window folds it during its live resize; a toggle, or a drag, doesn't.
                sidebarFoldedByWindow = !visible && view.window?.inLiveResize == true
                fitColumnsToToolbar()
                if app.sidebarVisible != visible { app.sidebarVisible = visible }
            },
            follow(inspectorItem) { [unowned self] visible in
                fitColumnsToToolbar()
                if app.inspectorVisible != visible { app.inspectorVisible = visible }
            },
        ]
        resizes = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                                         object: splitView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitColumnsToToolbar() }
        }
    }

    /// The columns' minimums follow the toolbar sections over them. A hidden sidebar hands its
    /// section, the window controls and its toggle, on to the source's, and a shown inspector
    /// takes the PDF's toggles over it. A minimum drops as soon as its pane's section shrinks,
    /// before AppKit makes room for the side column, and rises once the columns have the room,
    /// at the end of the side column's fold. A sidebar the window folded comes back at the width
    /// it folded at, where the source can narrow again: AppKit brings it back once the panes'
    /// minimums fit beside it.
    private func fitColumnsToToolbar() {
        let inspector = !inspectorItem.isCollapsed
        let returning = sidebarFoldedByWindow && splitView.bounds.width >= ColumnMetrics.inlineSidebar(inspectorShown: inspector)
        let source = ColumnMetrics.sourceMinimum(sidebarHidden: sidebarItem.isCollapsed && !returning)
        let pdf = ColumnMetrics.pdfMinimum(inspectorShown: inspector)
        guard source != sourceItem.minimumThickness || pdf != pdfItem.minimumThickness else { return }
        let width = { (source: CGFloat, pdf: CGFloat) in source + ColumnMetrics.divider + pdf + ColumnMetrics.toolbarInset }
        let room = splitView.arrangedSubviews[1].frame.width
        if source <= sourceItem.minimumThickness || room >= width(source, pdfItem.minimumThickness) {
            sourceItem.minimumThickness = source
        }
        if pdf <= pdfItem.minimumThickness || room >= width(sourceItem.minimumThickness, pdf) {
            pdfItem.minimumThickness = pdf
        }
        areaItem.minimumThickness = width(sourceItem.minimumThickness, pdfItem.minimumThickness)
    }

    // ---------- layout ----------

    /// Search over the files over the File Outline. A pane's size is its view's frame
    /// as it's added: the split opens it there, and a collapsed one shows there first.
    private func buildSidebar(height: CGFloat) {
        sidebar.splitView.isVertical = false
        sidebar.splitView.autosaveName = "Sidebar"
        let filesItem = NSSplitViewItem(viewController: host(FilesList(project: project)))
        filesItem.minimumThickness = ColumnMetrics.filesMinimum
        // The outline's header stays at the files' foot, over the outline's pane or, folded,
        // at the sidebar's: one view, which the pane's collapse carries down and back.
        buildOutlineBar()
        if OutlineState(app, project) != .hidden { filesItem.addBottomAlignedAccessoryViewController(outlineBar) }
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
        sidebarItem.isCollapsed = !app.sidebarVisible
        sidebarSearch = accessory(SearchField(text: Bindable(project).searchQuery, prompt: "Search Project", handle: searchField))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    private func buildArea(size: CGSize) {
        let sidebarWidth = app.sidebarVisible ? ColumnMetrics.sidebarIdeal : 0
        let inspectorWidth = app.inspectorVisible ? inspectorItem.minimumThickness : 0
        // As the side columns leave the toolbar (`fitColumnsToToolbar`).
        let sourceMinimum = ColumnMetrics.sourceMinimum(sidebarHidden: !app.sidebarVisible)
        let pdfMinimum = ColumnMetrics.pdfMinimum(inspectorShown: app.inspectorVisible)
        let columnsWidth = ColumnMetrics.columnsWidth(sidebarHidden: !app.sidebarVisible, inspectorShown: app.inspectorVisible)
        let room = max(size.width - sidebarWidth - inspectorWidth, columnsWidth)
        let panes = room - ColumnMetrics.divider
        let pdfWidth = min((panes * ColumnMetrics.pdfShare).rounded(), panes - sourceMinimum)
        panelHeight = max(ColumnMetrics.panelMinimum, (size.height * ColumnMetrics.panelShare).rounded() - ColumnMetrics.panelHeader)

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: panes - pdfWidth))
        sourceItem.minimumThickness = sourceMinimum

        pdfItem = NSSplitViewItem(viewController: host(PDFPane(project: project), width: pdfWidth))
        pdfItem.minimumThickness = pdfMinimum
        pdfFind = accessory(PDFFindBar(controller: pdf), hidden: true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)

        columns.splitView.autosaveName = "Columns"
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        columns.loaded = { [unowned self] in if !app.showPDF { pdfItem.isCollapsed = true } }
        // The last toolbar section's edge effect needs a safe area ending where the section does (27.2).
        columns.view.additionalSafeAreaInsets.right = ColumnMetrics.toolbarInset

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project, state: panelState), height: panelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        // It keeps its height as the window resizes; the columns take the change.
        panelItem.holdingPriority = .defaultLow + 1

        area.splitView.isVertical = false
        area.splitView.autosaveName = "Area"
        let columnsItem = NSSplitViewItem(viewController: columns)
        // The panel dragged up stops short of the find bar and a few lines.
        columnsItem.minimumThickness = ColumnMetrics.columnsMinimum + ColumnMetrics.panelHeader
        panelHeader = accessory(BuildPanelHeader(project: project, filter: Bindable(panelState).filter,
                                                showWarnings: Bindable(panelState).showWarnings), hidden: !project.showLogs)
        panelHeader.automaticallyAppliesContentInsets = false
        panelHeader.preferredScrollEdgeEffectStyle = .hard
        columnsItem.addBottomAlignedAccessoryViewController(panelHeader)
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)
        area.loaded = { [unowned self] in
            if !project.showLogs { panelItem.isCollapsed = true }
        }

        areaItem = NSSplitViewItem(viewController: area)
        // The PDF hidden, the source keeps its room: the toolbar's items stay where they were.
        areaItem.minimumThickness = columnsWidth
        // One look whether the panel shows or not: the system's hard edge under a hairline, over
        // the editors' text and the panel's rows alike. The edge draws no line of its own here.
        areaItem.addBottomAlignedAccessoryViewController(Self.separator())
        let statusBar = accessory(StatusBar(project: project))
        statusBar.preferredScrollEdgeEffectStyle = .hard
        areaItem.addBottomAlignedAccessoryViewController(statusBar)
        addSplitViewItem(areaItem)
    }

    /// AppKit's fixed inspector width fits its settings and facts.
    private func buildInspector() {
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project)))
        inspectorItem.isCollapsed = !app.inspectorVisible
    }

    /// The fixed inspector's divider takes no drag, so it shows no resize cursor.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect,
                                   ofDividerAt: dividerIndex)
        return dividerIndex == splitViewItems.firstIndex(of: inspectorItem)! - 1 ? .zero : rect
    }

    /// A pane: SwiftUI whose sizes stay out of Auto Layout, so the split item's
    /// limits size it and its content never sets the window's minimum.
    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0) -> NSViewController {
        let host = NSHostingController(rootView: content.environment(app))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        return host
    }

    /// The system separator, edge to edge over a bar, outside its insets.
    private static func separator() -> NSSplitViewItemAccessoryViewController {
        let separator = NSSplitViewItemAccessoryViewController()
        let line = NSHostingView(rootView: Divider())
        line.sizingOptions = [.intrinsicContentSize]
        separator.view = line
        separator.automaticallyAppliesContentInsets = false
        separator.preferredScrollEdgeEffectStyle = .hard
        return separator
    }

    /// The header under the system separator, which stands for the sidebar split's divider
    /// (`SidebarSplitViewController`). Its content keeps one place under the line as the
    /// bar's height animates with the split, so folded it lines up with the status bar.
    private func buildOutlineBar() {
        let bar = NSView()
        let line = NSBox()
        line.boxType = .separator
        let header = NSHostingView(rootView: OutlineHeader().environment(app))
        header.sizingOptions = [.intrinsicContentSize]
        for view in [line, header] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        outlineBarHeight = bar.heightAnchor.constraint(equalToConstant: outlineBarHeight(folded: app.outlineCollapsed))
        NSLayoutConstraint.activate([
            outlineBarHeight,
            line.topAnchor.constraint(equalTo: bar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            header.topAnchor.constraint(equalTo: line.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        outlineBar = NSSplitViewItemAccessoryViewController()
        outlineBar.view = bar
        outlineBar.automaticallyAppliesContentInsets = false
        // The separator is the line; the sidebar's automatic edge would draw another.
        outlineBar.preferredScrollEdgeEffectStyle = .soft
    }

    private func outlineBarHeight(folded: Bool) -> CGFloat {
        (folded ? StatusBar.height : OutlineHeader.openHeight) + sidebar.splitView.dividerThickness
    }

    /// A pane bar sized to its content, inside AppKit's standard accessory insets.
    private func accessory(_ content: some View, hidden: Bool = false) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        let host = NSHostingView(rootView: content.environment(app))
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
            track({ app.sidebarVisible }) { [weak self] visible in if let self { setCollapsed(sidebarItem, !visible) } },
            track({ app.inspectorVisible }) { [weak self] visible in if let self { setCollapsed(inspectorItem, !visible) } },
            track({ app.showPDF }) { [weak self] visible in if let self { setCollapsed(pdfItem, !visible) } },
            track({ project.showLogs }) { [weak self] in self?.setPanelShown($0) },
            track({ OutlineState(app, project) }) { [weak self] in self?.setOutline($0) },
            track({ pdf.finding }) { [weak self] finding in if let self { setHidden(pdfFind, !finding) } },
            track({ app.pdfRequest?.token }) { [weak self] _ in self?.takePDFRequest() },
            track({ app.searchFocusToken }, initial: false) { [weak self] _ in self?.focusSearch() },
        ]
    }

    /// The model follows a column dragged shut, collapsed by a narrowing window, or
    /// toggled by the toolbar's own button.
    private func follow(_ item: NSSplitViewItem, _ shown: @escaping @MainActor (Bool) -> Void) -> NSKeyValueObservation {
        item.observe(\.isCollapsed, options: .new) { _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated { shown(!collapsed) }
        }
    }

    /// Through AppKit's collapse animation, which brings a pane back at the size it
    /// was hidden at; instantly when the window isn't on screen or Reduce Motion is
    /// on. `done` runs once the pane is at its size.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, done: (@MainActor () -> Void)? = nil) {
        // Repeated model notifications must not snap an animation already heading here.
        guard item.isCollapsed != collapsed else { return done?() ?? () }
        // Unanimated, the build panel changes layout without the live resize AppKit's
        // animation starts even when instant (`setPanelShown` keeps its height).
        guard animates || item !== panelItem else {
            item.isCollapsed = collapsed
            view.layoutSubtreeIfNeeded()
            done?()
            return
        }
        let panel = item === panelItem, id = ObjectIdentifier(item)
        paneAnimation(true)
        NSAnimationContext.runAnimationGroup { context in
            if !animates { context.duration = 0 }
            // One animation carries the outline's pane and its header's height, and the
            // build panel and its header.
            if item === outlineItem {
                context.allowsImplicitAnimation = true
                outlineBarHeight.animator().constant = outlineBarHeight(folded: collapsed)
            }
            if panel {
                if !collapsed { panelHeader.view.isHidden = false }
                panelHeader.animator().isHidden = collapsed
            }
            if !collapsed, let frame = widenedFrame(showing: item) { view.window?.animator().setFrame(frame, display: true) }
            item.animator().isCollapsed = collapsed
            if item === outlineItem { sidebar.view.layoutSubtreeIfNeeded() }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return done?() ?? () }
                if panel, self.panelHeader.isHidden { self.panelHeader.view.isHidden = true }
                self.paneAnimation(false)
                if collapsed { self.giveBackWidth(hiding: id) } else { self.widenedSettled(showing: id) }
                done?()
            }
        }
    }

    /// The window a side column widened, from and to (`widenedFrame`).
    private var widened: (item: NSSplitViewItem, from: NSRect, to: NSRect)?

    /// A side column shown in a window too narrow for it beside the panes' minimums widens the
    /// window by only the width missing, from the column's own edge and within the screen, as
    /// Pages does for its inspector. Left to AppKit, the window would take the column's whole
    /// width, and the room over would bring back a sidebar the window folded. Nil leaves the window.
    private func widenedFrame(showing item: NSSplitViewItem) -> NSRect? {
        guard item === sidebarItem || item === inspectorItem, let window = view.window,
              !window.styleMask.contains(.fullScreen) else { return nil }
        let sidebar = item === sidebarItem || !sidebarItem.isCollapsed
        let inspector = item === inspectorItem || !inspectorItem.isCollapsed
        let needed = (sidebar ? ColumnMetrics.sidebarMinimum + ColumnMetrics.divider : 0)
            + ColumnMetrics.columnsWidth(sidebarHidden: !sidebar, inspectorShown: inspector)
            + (inspector ? ColumnMetrics.divider + ColumnMetrics.inspector : 0)
        let missing = (needed - splitView.bounds.width).rounded(.up)
        guard missing > 0 else { return nil }
        var frame = window.frame
        frame.size.width += missing
        if item === sidebarItem { frame.origin.x -= missing }
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        }
        widened = (item, window.frame, frame)
        return frame
    }

    /// The window as AppKit settled it around the shown column, which can differ from the frame
    /// asked for by a point.
    private func widenedSettled(showing item: ObjectIdentifier) {
        guard let window = view.window, let widened, ObjectIdentifier(widened.item) == item else { return }
        self.widened?.to = window.frame
    }

    /// Hidden again, the column gives that width back, unless the window has changed since; once
    /// it's shut, or the narrowing window would fold the sidebar on the way.
    private func giveBackWidth(hiding item: ObjectIdentifier) {
        guard let widened, ObjectIdentifier(widened.item) == item else { return }
        self.widened = nil
        // Within the point AppKit's split rounding can move it.
        guard let window = view.window, abs(window.frame.minX - widened.to.minX) <= 1,
              abs(window.frame.width - widened.to.width) <= 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            if !animates { context.duration = 0 }
            window.animator().setFrame(widened.from, display: true)
        }
    }

    /// AppKit's split animation puts every pane in live resize (`quiet`). And its steps
    /// don't always reach the screen: with nothing else waking the run loop, a pane would
    /// hold still, then jump to its end (27.2). Laid out on every frame meanwhile, the
    /// panes keep up with it.
    private func paneAnimation(_ running: Bool) {
        quiet(running)
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

    /// Panes in live resize show their overlay scrollers, though nothing scrolls; scroll
    /// bars come with scrolling (HIG, Scroll views). They keep out of sight until the last
    /// animation or drag ends.
    private func quiet(_ resizing: Bool) {
        quieting += resizing ? 1 : -1
        guard quieting == (resizing ? 1 : 0) else { return }
        if resizing { quietScrollViews = Self.scrollViews(in: view) }
        for scroll in quietScrollViews { scroll.hideOverlayScrollers(resizing) }
        if !resizing { quietScrollViews = [] }
    }

    @objc private func paneFrame(_ link: CADisplayLink) {
        for split in splitViews { split.needsLayout = true }
    }

    private var splitViews: [NSSplitView] { [splitView, sidebar.splitView, columns.splitView, area.splitView] }

    /// Hidden ones too: the build panel's appear as it opens.
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        [view as? NSScrollView].compactMap(\.self) + view.subviews.flatMap(scrollViews)
    }

    /// The pane folds down under its header to the sidebar's foot, and opens up from there.
    private func setOutline(_ state: OutlineState) {
        let files = sidebar.splitViewItems[0]
        // Hidden before its first layout, a bottom accessory still insets its pane (27.2).
        if state != .hidden, !files.bottomAlignedAccessoryViewControllers.contains(outlineBar) {
            files.addBottomAlignedAccessoryViewController(outlineBar)
        }
        setHidden(outlineBar, state == .hidden)
        setCollapsed(outlineItem, state != .open)
    }

    /// The bar's view hides too: a hidden accessory only folds to no height, and its
    /// controls would stay in the key view loop and VoiceOver.
    private func setHidden(_ accessory: NSSplitViewItemAccessoryViewController, _ hidden: Bool) {
        guard accessory.isHidden != hidden else { return }
        if !hidden { accessory.view.isHidden = false }
        guard animates else {
            accessory.isHidden = hidden
            accessory.view.isHidden = hidden
            return
        }
        paneAnimation(true)
        NSAnimationContext.runAnimationGroup { _ in
            accessory.animator().isHidden = hidden
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if hidden, accessory.isHidden { accessory.view.isHidden = true }
                self?.paneAnimation(false)
            }
        }
    }

    /// The panel rises from the status bar through AppKit's animation. Its header
    /// belongs to the columns' bottom edge, where their content scrolls underneath it.
    /// AppKit brings it back at its hosted view's height, and unanimated at its minimum, so
    /// the height it was hidden at is kept here.
    private func setPanelShown(_ shown: Bool) {
        guard shown == panelItem.isCollapsed else { return }
        let split = area.splitView, panel = panelItem.viewController.view
        // Opening, the hosted view is already at the height the pane is heading for.
        if !shown { panelHeight = panel.frame.height }
        guard animates else {
            setHidden(panelHeader, !shown)
            setCollapsed(panelItem, !shown)
            if shown { split.setPosition(split.bounds.height - split.dividerThickness - panelHeight, ofDividerAt: 0) }
            return
        }
        // Not reversing a close midway, which heads back to where it began.
        if shown, split.arrangedSubviews[1].isHidden {
            let room = split.bounds.height - split.dividerThickness - splitViewItems[1].viewController.view.safeAreaInsets.top
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
        quietScrollViews.forEach { $0.hideOverlayScrollers(false) }
        quietScrollViews = []
        paneFrames?.invalidate()
        paneFrames = nil
        watches.forEach { $0.cancel() }
        collapses = []
        resizes.map(NotificationCenter.default.removeObserver)
        resizes = nil
        toolbar.close()
    }

    // ---------- find ----------

    /// Edit › Find's items when the source text, which answers them itself, doesn't
    /// have the keyboard: the PDF's while its pages or its find bar have it, else
    /// the source's find bar, or the PDF's over a preview. Nil turns an item off.
    func findAction(_ item: NSValidatedUserInterfaceItem) -> (() -> Void)? {
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

    private func showPDFFind() {
        pdf.finding = true
        setHidden(pdfFind, false)
        focusField(pdf.findField, in: pdfFind)
    }

    // ---------- the menus' PDF requests ----------

    /// Each request once, after a hidden column has opened to its width.
    private func takePDFRequest() {
        guard let action = app.pdfRequest?.action else { return }
        app.pdfRequest = nil
        setCollapsed(pdfItem, false) { [weak self] in
            guard let self, project.hasPDF else { return }
            perform(action)
        }
    }

    private func perform(_ action: PDFAction) {
        switch action {
        case .zoomIn: pdf.zoom(in: true)
        case .zoomOut: pdf.zoom(in: false)
        case .actualSize: pdf.setScale(1)
        case .fitWidth: pdf.fitWidth()
        case .fitPage: pdf.fitPage()
        case .goToPage(let page): pdf.go(toPage: page)
        case .find: showPDFFind()
        case .print: pdf.view.print(with: .shared, autoRotate: true)
        case let .reveal(loc, word): pdf.reveal(loc, word: word)
        case .inverseFromView:
            if case let (page, point)? = pdf.sourcePoint() {
                Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
            }
        }
    }
}

/// The File Outline: open in its pane, folded to its header, or hidden with its
/// header while the sidebar shows search results or the project isn't LaTeX.
private nonisolated enum OutlineState {
    case open, folded, hidden

    @MainActor init(_ app: AppModel, _ project: ProjectModel) {
        self = project.isSearching || !project.isLaTeX ? .hidden : app.outlineCollapsed ? .folded : .open
    }
}

/// A split whose autosave has restored its panes as its view loads; `loaded`
/// then hides the ones its owner's models hide.
///
/// AppKit has no split detents: a drag that comes near `detent`, the opening
/// position, stops there with an alignment haptic on arrival.
class RestoredSplitViewController: NSSplitViewController {
    var loaded: () -> Void = {}
    var detent: (_ divider: Int) -> CGFloat? = { _ in nil }
    /// As a divider's drag starts, and as it ends.
    var dragging: (Bool) -> Void = { _ in }
    private var dragResizes: (any NSObjectProtocol)?
    private var dragEnd: DispatchWorkItem?

    /// NSSplitViewController's own: side by side, with the thin divider.
    init(splitView: NSSplitView = NSSplitView()) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        self.splitView = splitView
        // A drag's resizes name their divider; other resizes don't. Watched rather than
        // caught in `mouseDown`, which would turn off the split's gesture recognizers and
        // with them Sidecar's touch (#31).
        dragResizes = NotificationCenter.default.addObserver(forName: NSSplitView.willResizeSubviewsNotification,
                                                             object: splitView, queue: nil) { [weak self] note in
            guard note.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
            MainActor.assumeIsolated { self?.dividerMoved() }
        }
    }

    isolated deinit {
        dragResizes.map(NotificationCenter.default.removeObserver)
        dragEnd?.cancel()
    }

    /// The drag ends once the divider rests with the button up, or, for a touch, a moment after it last moved.
    private func dividerMoved() {
        if dragEnd == nil { dragging(true) }
        dragEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { return dividerMoved() }
            dragEnd = nil
            dragging(false)
        }
        dragEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        loaded()
    }

    /// NSSplitViewController declares this without acting on it, so super isn't called.
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
}

/// Files over the File Outline. The separator over the outline's header, at the foot of
/// the files, stands for the divider: AppKit has no thin divider that draws no line, so
/// the divider's own, under the header, isn't drawn, and it takes drags at the separator.
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
        // Folded, the outline opens only from its header.
        guard let header, !header.isHidden, splitViewItems.last?.isCollapsed == false else { return .zero }
        let frame = header.view.convert(header.view.bounds, to: splitView)
        let line = splitView.isFlipped ? frame.minY : frame.maxY
        return proposedEffectiveRect.offsetBy(dx: 0, dy: line - drawnRect.minY)
    }
}

/// Pane minimums, which hold each pane's toolbar section: a tracking separator keeps its
/// section over its pane only while the items fit there. Squeezed, AppKit lets the separator
/// leave the divider, pushing items over the next pane or, mid-resize, onto one another.
enum ColumnMetrics {
    /// Xcode's navigator: its default width, and its narrowest.
    static let sidebarIdeal: CGFloat = 256
    static let sidebarMinimum: CGFloat = 222
    /// Catches a drag aimed at a detent without trapping one passing through.
    static let detentReach: CGFloat = 8
    /// The source's toolbar section, Back, AppKit's narrowest title (160 pt) and the editing
    /// capsule, and the PDF's, Zoom, Compile and the toggles (338 pt), as AppKit lays them out
    /// (27.2). About 33 columns of the editor's 13 pt text; equal minima split the narrowest
    /// room evenly between source and PDF.
    static let sourceMinimum: CGFloat = 348
    static let pdfMinimum: CGFloat = sourceMinimum
    /// The window controls and the sidebar toggle, which a hidden sidebar's toolbar section
    /// hands on to the source's, as AppKit lays them out (27.2).
    static let windowControls: CGFloat = 136
    /// The PDF and Inspector toggles, which a shown inspector's section takes over from the PDF's.
    static let inspectorToggles: CGFloat = 92
    /// AppKit's standard inspector width (`NSSplitViewItem(inspectorWithViewController:)`).
    static let inspector: CGFloat = 270
    static let pdfShare: CGFloat = 0.5
    /// Source and PDF over the build panel: a find bar and a few lines.
    static let columnsMinimum: CGFloat = 200
    /// The build panel's content below its header; a quarter of the window at first.
    static let panelMinimum: CGFloat = 80
    static let panelShare: CGFloat = 0.25
    /// The sidebar's panes: a few rows each; the outline nearly half at first.
    static let filesMinimum: CGFloat = 100
    static let outlineMinimum: CGFloat = 80
    static let outlineShare: CGFloat = 0.45
    /// The splits' thin divider (`NSSplitView.DividerStyle.thin`).
    static let divider: CGFloat = 1
    /// The columns' trailing safe-area inset, for the last column's toolbar section
    /// (`buildArea`). That column's minimum counts it.
    static let toolbarInset: CGFloat = 0.5
    /// The source's minimum: wider with the sidebar hidden, by the controls its section takes on.
    static func sourceMinimum(sidebarHidden: Bool) -> CGFloat {
        sourceMinimum + (sidebarHidden ? windowControls : 0)
    }
    /// The PDF's: narrower with the inspector shown, by the toggles its section gives up.
    static func pdfMinimum(inspectorShown: Bool) -> CGFloat {
        pdfMinimum - (inspectorShown ? inspectorToggles : 0)
    }
    static func columnsWidth(sidebarHidden: Bool, inspectorShown: Bool = false) -> CGFloat {
        sourceMinimum(sidebarHidden: sidebarHidden) + divider + pdfMinimum(inspectorShown: inspectorShown) + toolbarInset
    }
    /// The narrowest window: source and PDF at their minimums, every default toolbar item over
    /// its pane. It stays as the sidebar shows: a narrower window folds the sidebar instead, as
    /// Mail's does (HIG, Sidebars). With the PDF hidden the source keeps the room, and the
    /// inspector, which AppKit doesn't fold for a narrowing window, adds its width. The height is
    /// the app's own.
    static let contentMinimum = CGSize(width: columnsWidth(sidebarHidden: true).rounded(.up), height: 600)
    /// The width below which the sidebar folds: it and the columns at their minimums.
    static func inlineSidebar(inspectorShown: Bool) -> CGFloat {
        sidebarMinimum + divider + columnsWidth(sidebarHidden: false, inspectorShown: inspectorShown)
            + (inspectorShown ? divider + inspector : 0)
    }
    /// The build panel's header, its content within a bar's standard insets.
    static let panelHeader = bar(BuildPanelHeader.height)

    /// A pane bar's content within AppKit's standard accessory insets (27.2).
    static func bar(_ content: CGFloat) -> CGFloat { content + 2 * 9 }
    /// Those insets at the bar's sides.
    static let barSideInset: CGFloat = 10
}
