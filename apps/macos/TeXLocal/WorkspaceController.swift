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

/// Sidebar | source | PDF over the build panel and status bar | inspector.
/// Find bars belong to their columns; AppKit animates model-driven collapses
/// and keeps each split's divider positions across launches (`autosaveName`).
final class WorkspaceController: NSSplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    private(set) var toolbar: WorkspaceToolbar!

    let columns = RestoredSplitViewController()
    let area = RestoredSplitViewController()
    private let sidebar = RestoredSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var outlineItem: NSSplitViewItem!
    private(set) var sourceItem: NSSplitViewItem!
    private(set) var pdfItem: NSSplitViewItem!
    private(set) var panelItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    private var sidebarSearch: NSSplitViewItemAccessoryViewController!
    private var foldedOutline: NSSplitViewItemAccessoryViewController!
    private let foldedLine = separator()
    private var pdfFind: NSSplitViewItemAccessoryViewController!
    private let searchField = FieldHandle()

    /// The panel's height as it was hidden, or its first. Shown without AppKit's
    /// animation (`setCollapsed`), it would come back at its minimum.
    private var panelHeight: CGFloat = 0
    private var watches: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        super.init(nibName: nil, bundle: nil)
        splitView.autosaveName = "Workspace"
        buildSidebar(height: size.height)
        // Before the area, which opens in the room the side columns leave; added after it.
        buildInspector()
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
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
            follow(sidebarItem) { [app] visible in if app.sidebarVisible != visible { app.sidebarVisible = visible } },
            follow(inspectorItem) { [app] visible in if app.inspectorVisible != visible { app.inspectorVisible = visible } },
        ]
    }

    // ---------- layout ----------

    /// Search over the files over the File Outline. A pane's size is its view's frame
    /// as it's added: the split opens it there, and a collapsed one shows there first.
    private func buildSidebar(height: CGFloat) {
        sidebar.splitView.isVertical = false
        sidebar.splitView.autosaveName = "Sidebar"
        let filesItem = NSSplitViewItem(viewController: host(FilesList(project: project)))
        filesItem.minimumThickness = ColumnMetrics.filesMinimum
        // Folded, the outline's pane collapses and its header stays at the foot of the files,
        // under the status bar's line and as tall as the bar, so the two line up.
        foldedOutline = accessory(FoldedOutlineHeader())
        foldedOutline.automaticallyAppliesContentInsets = false
        // The separator draws the line; the sidebar's automatic edge would add its own over it.
        for bar in [foldedLine, foldedOutline!] { bar.preferredScrollEdgeEffectStyle = .soft }
        if OutlineState(app, project) == .folded { addFoldedOutline(to: filesItem) }
        outlineItem = NSSplitViewItem(viewController: host(OutlineList(project: project),
                                                            height: (height * ColumnMetrics.outlineShare).rounded()))
        outlineItem.minimumThickness = ColumnMetrics.outlineMinimum
        // It keeps its height as the window resizes; the files take the change.
        outlineItem.holdingPriority = .defaultLow + 1
        sidebar.addSplitViewItem(filesItem)
        sidebar.addSplitViewItem(outlineItem)
        sidebar.loaded = { [unowned self] in if OutlineState(app, project) != .open { outlineItem.isCollapsed = true } }
        sidebar.view.frame.size.width = ColumnMetrics.sidebarIdeal

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.isCollapsed = !app.sidebarVisible
        sidebarSearch = accessory(SearchField(text: Bindable(project).searchQuery, prompt: "Search Project", handle: searchField))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    private func buildArea(size: CGSize) {
        let sidebarWidth = app.sidebarVisible ? ColumnMetrics.sidebarIdeal : 0
        let inspectorWidth = app.inspectorVisible ? inspectorItem.minimumThickness : 0
        let room = max(size.width - sidebarWidth - inspectorWidth, ColumnMetrics.contentMinimum.width)
        let panes = room - ColumnMetrics.divider
        let pdfWidth = (panes * ColumnMetrics.pdfShare).rounded()
        panelHeight = (size.height * ColumnMetrics.panelShare).rounded()

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: panes - pdfWidth))
        sourceItem.minimumThickness = ColumnMetrics.sourceMinimum

        pdfItem = NSSplitViewItem(viewController: host(PDFPane(project: project), width: pdfWidth))
        pdfItem.minimumThickness = ColumnMetrics.pdfMinimum
        pdfFind = accessory(PDFFindBar(controller: pdf), hidden: true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)

        columns.splitView.autosaveName = "Columns"
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        columns.loaded = { [unowned self] in if !app.showPDF { pdfItem.isCollapsed = true } }
        // The last toolbar section's edge effect needs a safe area ending where the section does (27.2).
        columns.view.additionalSafeAreaInsets.right = ColumnMetrics.toolbarInset

        let panelState = BuildPanelState()
        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project, state: panelState), height: panelHeight))
        let panelHeader = accessory(BuildPanelHeader(project: project, state: panelState))
        panelHeader.preferredScrollEdgeEffectStyle = .automatic
        panelItem.addTopAlignedAccessoryViewController(panelHeader)
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        // It keeps its height as the window resizes; the columns take the change.
        panelItem.holdingPriority = .defaultLow + 1

        area.splitView.isVertical = false
        area.splitView.autosaveName = "Area"
        let columnsItem = NSSplitViewItem(viewController: columns)
        // The panel dragged up stops short of the find bar and a few lines.
        columnsItem.minimumThickness = ColumnMetrics.columnsMinimum
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)
        area.loaded = { [unowned self] in if !project.showLogs { panelItem.isCollapsed = true } }

        let areaItem = NSSplitViewItem(viewController: area)
        // A hard scroll edge draws no line over the build panel's still content.
        areaItem.addBottomAlignedAccessoryViewController(Self.separator())
        // Xcode's bottom bar: its height, and its items to the ends.
        let statusBar = accessory(StatusBar(project: project), clearsCorners: true)
        statusBar.automaticallyAppliesContentInsets = false
        statusBar.preferredScrollEdgeEffectStyle = .automatic
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
        let line = NSBox(frame: NSRect(x: 0, y: 0, width: 100, height: 1))
        line.boxType = .separator
        separator.view = line
        separator.automaticallyAppliesContentInsets = false
        return separator
    }

    /// A pane bar sized to its content, inside AppKit's standard accessory insets.
    /// `clearsCorners` keeps it clear of the window's rounded corners as well.
    private func accessory(_ content: some View, hidden: Bool = false,
                           clearsCorners: Bool = false) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        let host = NSHostingView(rootView: content.environment(app))
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessory.view = host
        if clearsCorners {
            let bar = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(host)
            let corners = bar.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
            let leading = host.leadingAnchor.constraint(equalTo: bar.leadingAnchor)
            let trailing = bar.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            leading.priority = .defaultHigh
            trailing.priority = .defaultHigh
            NSLayoutConstraint.activate([
                leading, trailing,
                host.leadingAnchor.constraint(greaterThanOrEqualTo: corners.leadingAnchor),
                corners.trailingAnchor.constraint(greaterThanOrEqualTo: host.trailingAnchor),
                host.topAnchor.constraint(equalTo: bar.topAnchor),
                host.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            ])
            accessory.view = bar
        }
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
        // AppKit's split animation marks descendants as live-resizing, revealing
        // their scrollers, even when instant. A build-panel toggle changes layout
        // without that cue (`setPanelShown` keeps its height).
        guard item !== panelItem else {
            item.isCollapsed = collapsed
            view.layoutSubtreeIfNeeded()
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            if !animates { context.duration = 0 }
            item.animator().isCollapsed = collapsed
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }

    /// Folding, the pane collapses with its header and the header then stands at the
    /// files' foot; unfolding, the pane opens up from there.
    private func setOutline(_ state: OutlineState) {
        let files = sidebar.splitViewItems[0]
        // Hidden before its first layout, a bottom accessory still insets its pane (27.2).
        if state == .folded, !files.bottomAlignedAccessoryViewControllers.contains(foldedOutline) {
            showFoldedOutline(false)
            addFoldedOutline(to: files)
        }
        if state != .folded { showFoldedOutline(false) }
        setCollapsed(outlineItem, state != .open) { [weak self] in
            guard let self, OutlineState(app, project) == .folded else { return }
            showFoldedOutline(true)
        }
    }

    private func addFoldedOutline(to files: NSSplitViewItem) {
        files.addBottomAlignedAccessoryViewController(foldedLine)
        files.addBottomAlignedAccessoryViewController(foldedOutline)
    }

    private func showFoldedOutline(_ shown: Bool) {
        for bar in [foldedLine, foldedOutline!] {
            bar.isHidden = !shown
            bar.view.isHidden = !shown
        }
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
        NSAnimationContext.runAnimationGroup { _ in
            accessory.animator().isHidden = hidden
        } completionHandler: {
            MainActor.assumeIsolated {
                if hidden, accessory.isHidden { accessory.view.isHidden = true }
            }
        }
    }

    /// The panel comes back through its divider: its hosted view's frame is
    /// ambiguous with the accessory's insets.
    private func setPanelShown(_ shown: Bool) {
        guard shown == panelItem.isCollapsed else { return }
        guard shown else {
            panelHeight = panelItem.viewController.view.frame.height
            return setCollapsed(panelItem, true)
        }
        let split = area.splitView
        setCollapsed(panelItem, false)
        split.setPosition(split.bounds.height - split.dividerThickness - panelHeight, ofDividerAt: 0)
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
        for split in [splitView, sidebar.splitView, columns.splitView, area.splitView] { split.autosaveName = nil }
        watches.forEach { $0.cancel() }
        collapses = []
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
            guard !pdf.matches.isEmpty else { return nil }
            return { [pdf] in pdf.step(action == .nextMatch ? 1 : -1) }
        case .setSearchString:
            guard let text = pdf.view.currentSelection?.string, !text.isEmpty else { return nil }
            return { [weak self] in
                self?.pdf.findText = text
                self?.showPDFFind()
            }
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
        case .fitHeight: pdf.fitHeight()
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
final class RestoredSplitViewController: NSSplitViewController {
    var loaded: () -> Void = {}

    override func viewDidLoad() {
        super.viewDidLoad()
        loaded()
    }
}

/// Content sets pane minimums; AppKit moves toolbar items across dividers or
/// into overflow near the window minimum.
enum ColumnMetrics {
    /// AppKit's inspector width (NSSplitViewItem.h), so the side columns open alike.
    static let sidebarIdeal: CGFloat = 270
    /// About 40 editor columns or a legible fitted page; equal minima split the
    /// narrowest room evenly between source and PDF.
    static let sourceMinimum: CGFloat = 320
    static let pdfMinimum: CGFloat = sourceMinimum
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
    /// The window's content at its narrowest, source | PDF, in the whole points the
    /// split keeps: a narrowing window folds the sidebar first (AppKit's way with
    /// sidebars), so two windows tile side by side on the smallest Mac display. At its
    /// shortest, the columns over the build panel and the status bar under its line.
    static let contentMinimum = CGSize(width: (sourceMinimum + divider + pdfMinimum + toolbarInset).rounded(.up),
                                       height: columnsMinimum + divider + bar(BuildPanelHeader.height) + panelMinimum
                                           + divider + StatusBar.height)

    /// A pane bar's content within AppKit's standard accessory insets (27.2).
    private static func bar(_ content: CGFloat) -> CGFloat { content + 2 * 9 }
}
