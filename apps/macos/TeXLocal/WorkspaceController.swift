import AppKit
import SwiftUI

/// An open project's window content: sidebar | source | PDF over the build panel, the
/// status bar at their foot | inspector; each find bar is its column's top accessory.
/// The models collapse and show the items through AppKit; a column dragged or
/// toggled shut goes back to them.
final class WorkspaceController: NSSplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    private(set) var toolbar: WorkspaceToolbar!

    /// Source | PDF: the toolbar's second section follows its divider.
    let columns = NSSplitViewController()
    /// The columns over the build panel.
    let area = NSSplitViewController()
    /// The files over the File Outline.
    private let sidebar = NSSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var outlineItem: NSSplitViewItem!
    private(set) var sourceItem: NSSplitViewItem!
    private(set) var pdfItem: NSSplitViewItem!
    private(set) var panelItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    private var sidebarSearch: NSSplitViewItemAccessoryViewController!
    private var sourceFind: NSSplitViewItemAccessoryViewController!
    private var pdfFind: NSSplitViewItemAccessoryViewController!
    private let sourceFindField = FieldHandle()
    private let searchField = FieldHandle()

    private var watches: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []
    private var drags: [NotificationCenter.ObservationToken] = []

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        columns.splitView.isVertical = true
        columns.splitView.dividerStyle = .thin
        area.splitView.dividerStyle = .thin
        buildSidebar(height: size.height)
        // Before the area, which opens in the room the side columns leave; added after it.
        buildInspector()
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
        toolbar = WorkspaceToolbar(app: app, project: project, workspace: self)
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    // ---------- layout ----------

    /// Search over the files over the File Outline. A pane's size is its view's frame
    /// as it's added: the split opens it there, and a collapsed one shows there first.
    private func buildSidebar(height: CGFloat) {
        sidebar.splitView.isVertical = false
        sidebar.splitView.dividerStyle = .thin
        let files = host(FilesList(project: project))
        let filesItem = NSSplitViewItem(viewController: files)
        filesItem.minimumThickness = ColumnMetrics.filesMinimum
        let height = app.outlineCollapsed ? BarMetrics.secondaryBarHeight
            : PaneSize.outline.value ?? (height * ColumnMetrics.outlineShare).rounded()
        let outline = host(OutlinePane(project: project), height: height)
        outlineItem = NSSplitViewItem(viewController: outline)
        outlineItem.minimumThickness = app.outlineCollapsed ? BarMetrics.secondaryBarHeight
            : BarMetrics.secondaryBarHeight + ColumnMetrics.outlineMinimum
        if app.outlineCollapsed { outlineItem.maximumThickness = BarMetrics.secondaryBarHeight }
        // It keeps its height as the window resizes; the files take the change.
        outlineItem.holdingPriority = .defaultLow + 1
        outlineItem.isCollapsed = !showsOutline

        sidebar.addSplitViewItem(filesItem)
        sidebar.addSplitViewItem(outlineItem)
        sidebar.view.frame.size.width = PaneSize.sidebar.value ?? ColumnMetrics.sidebarIdeal

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.isCollapsed = !app.sidebarVisible
        sidebarSearch = accessory(SearchField(text: Bindable(project).searchQuery, prompt: "Search Project", handle: searchField))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    /// Source | PDF over the build panel, the status bar at their foot.
    private func buildArea(size: CGSize) {
        let sidebarWidth = app.sidebarVisible ? sidebar.view.frame.width : 0
        let inspectorWidth = inspectorItem.isCollapsed ? 0 : inspectorItem.viewController.view.frame.width
        let room = max(size.width - sidebarWidth - inspectorWidth, ColumnMetrics.contentMinimum.width)
        let panes = room - ColumnMetrics.divider
        let pdfWidth = keptPDFWidth(in: panes)
        let panelHeight = PaneSize.panel.value ?? (size.height * ColumnMetrics.panelShare).rounded()

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: panes - pdfWidth))
        sourceItem.minimumThickness = ColumnMetrics.sourceMinimum
        sourceFind = accessory(SourceFindBar(project: project, field: sourceFindField),
                               hidden: !(project.findShown && project.editsText))
        sourceItem.addTopAlignedAccessoryViewController(sourceFind)

        pdfItem = NSSplitViewItem(viewController: host(PDFPane(project: project), width: pdfWidth))
        pdfItem.minimumThickness = ColumnMetrics.pdfMinimum
        pdfItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        pdfItem.isCollapsed = !project.showPDF
        pdfFind = accessory(PDFFindBar(controller: pdf), hidden: true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)

        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        // The last toolbar section's edge effect needs a safe area ending where the section does (27.2).
        columns.view.additionalSafeAreaInsets.right = ColumnMetrics.toolbarInset

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project), height: panelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        panelItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // It keeps its height as the window resizes; the columns take the change.
        panelItem.holdingPriority = .defaultLow + 1
        panelItem.isCollapsed = !project.showLogs

        area.splitView.isVertical = false
        let columnsItem = NSSplitViewItem(viewController: columns)
        // The panel dragged up stops short of the find bar and a few lines.
        columnsItem.minimumThickness = ColumnMetrics.columnsMinimum
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)

        let areaItem = NSSplitViewItem(viewController: area)
        areaItem.addBottomAlignedAccessoryViewController(accessory(StatusBar(project: project)))
        addSplitViewItem(areaItem)
    }

    /// The PDF's kept share of `panes` (source and PDF, less the divider), leaving
    /// both their minimums; never under its own, when the source alone had less
    /// room than both need (the side columns then make it).
    private func keptPDFWidth(in panes: CGFloat) -> CGFloat {
        let share = (panes * (PaneSize.pdfShare.value ?? ColumnMetrics.pdfShare)).rounded()
        return max(min(max(share, ColumnMetrics.pdfMinimum), panes - ColumnMetrics.sourceMinimum), ColumnMetrics.pdfMinimum)
    }

    /// The project's settings and facts, at AppKit's fixed inspector width: a column
    /// of settings needs no more.
    private func buildInspector() {
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project)))
        inspectorItem.viewController.view.frame.size.width = inspectorItem.minimumThickness
        inspectorItem.isCollapsed = !app.inspectorVisible
    }

    /// A pane: SwiftUI whose sizes stay out of Auto Layout, so the split item's
    /// limits size it and its content never sets the window's minimum.
    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0) -> NSViewController {
        let host = NSHostingController(rootView: content.environment(app))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        return host
    }

    /// AppKit supplies each accessory's standard content insets and edge effect.
    private func accessory(_ content: some View, hidden: Bool = false) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        let host = NSHostingView(rootView: content.environment(app))
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessory.view = host
        accessory.isHidden = hidden
        host.isHidden = hidden
        return accessory
    }

    /// Search results take the whole sidebar; only LaTeX has an outline.
    private var showsOutline: Bool { !project.isSearching && project.isLaTeX }

    private func updateOutline() {
        let folded = app.outlineCollapsed
        let header = BarMetrics.secondaryBarHeight
        // Relax the old limit before installing a smaller maximum or a larger minimum.
        outlineItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        outlineItem.minimumThickness = folded ? header : header + ColumnMetrics.outlineMinimum
        if folded { outlineItem.maximumThickness = header }
        outlineItem.viewController.view.layoutSubtreeIfNeeded()
        setCollapsed(outlineItem, !showsOutline)
        guard showsOutline else { return }
        let split = sidebar.splitView
        let height = folded ? header : max(PaneSize.outline.value ?? split.bounds.height * ColumnMetrics.outlineShare,
                                           outlineItem.minimumThickness)
        split.setPosition(split.bounds.height - height - split.dividerThickness, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
    }

    // ---------- the models drive the panes ----------

    private func watch() {
        let app = app, project = project, pdf = pdf
        watches = [
            track({ app.sidebarVisible }) { [weak self] visible in if let self { setCollapsed(sidebarItem, !visible) } },
            track({ app.inspectorVisible }) { [weak self] visible in if let self { setCollapsed(inspectorItem, !visible) } },
            track({ project.showPDF }) { [weak self] shown in if let self { setCollapsed(pdfItem, !shown) } },
            track({ project.showLogs }) { [weak self] shown in if let self { setCollapsed(panelItem, !shown) } },
            track({ project.isSearching || !project.isLaTeX }) { [weak self] _ in self?.updateOutline() },
            track({ app.outlineCollapsed }) { [weak self] _ in self?.updateOutline() },
            // Only over the text: over a preview or No File Open, it would search and
            // replace in the hidden editor, whose edits aren't saved.
            track({ project.findShown && project.editsText }) { [weak self] shown in if let self { setHidden(sourceFind, !shown) } },
            // ⌘F, or Find and Replace…, again while the bar shows: back to its field.
            track({ project.findFocus }) { [weak self] focus in
                guard let self, focus > 0, project.editsText else { return }
                setHidden(sourceFind, false)
                focusField(sourceFindField, in: sourceFind)
            },
            track({ pdf.finding }) { [weak self] finding in if let self { setHidden(pdfFind, !finding) } },
            track({ app.pdfRequest?.token }) { [weak self] _ in self?.takePDFRequest() },
            track({ app.searchFocusToken }, initial: false) { [weak self] _ in self?.focusSearch() },
        ]
        collapses = [
            follow(sidebarItem) { [app] visible in if app.sidebarVisible != visible { app.sidebarVisible = visible } },
            follow(inspectorItem) { [app] visible in if app.inspectorVisible != visible { app.inspectorVisible = visible } },
        ]
        drags = [splitView, sidebar.splitView, columns.splitView, area.splitView].map { split in
            NotificationCenter.default.addObserver(of: split, for: .didResizeSubviews) { [weak self] message in
                if message.userResize { self?.saveSizes(split) }
            }
        }
    }

    /// The model follows a column dragged shut, collapsed by a narrowing window, or
    /// toggled by the toolbar's own button.
    private func follow(_ item: NSSplitViewItem, _ shown: @escaping @MainActor (Bool) -> Void) -> NSKeyValueObservation {
        item.observe(\.isCollapsed, options: .new) { _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated { shown(!collapsed) }
        }
    }

    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, done: (@MainActor () -> Void)? = nil) {
        let split = (item.viewController.parent as? NSSplitViewController)?.splitView
        let revealing = item.isCollapsed && !collapsed && (item === pdfItem || item === panelItem)
        let thickness = item === pdfItem
            ? keptPDFWidth(in: columns.splitView.bounds.width - columns.splitView.dividerThickness)
            : PaneSize.panel.value ?? ((split?.bounds.height ?? 0) * ColumnMetrics.panelShare).rounded()
        item.isCollapsed = collapsed
        view.layoutSubtreeIfNeeded()
        if revealing, let split {
            let length = split.isVertical ? split.bounds.width : split.bounds.height
            split.setPosition(length - thickness - split.dividerThickness, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
        done?()
    }

    /// Hidden accessories also leave the key view loop and accessibility tree.
    private func setHidden(_ accessory: NSSplitViewItemAccessoryViewController, _ hidden: Bool) {
        accessory.isHidden = hidden
        accessory.view.isHidden = hidden
    }

    /// A field in an accessory: in the window as soon as its bar shows, so it takes
    /// the keyboard at once.
    private func focusField(_ field: FieldHandle, in accessory: NSSplitViewItemAccessoryViewController) {
        if field.field == nil { accessory.view.layoutSubtreeIfNeeded() }
        field.focus()
    }

    /// Find in Project…: the sidebar opens with its search field taking the keyboard.
    private func focusSearch() {
        setCollapsed(sidebarItem, false)
        focusField(searchField, in: sidebarSearch)
    }

    /// Whether a text field is one of the find bars': it gets a `FindPassingTextView`.
    func hostsFindField(_ field: NSTextField) -> Bool {
        field.isDescendant(of: sourceFind.view) || field.isDescendant(of: pdfFind.view)
    }

    // ---------- sizes ----------

    /// Keeps the shown panes' sizes, for this launch's collapses and the next launch:
    /// the sizes they're dragged to, not those a narrowing window squeezes them to.
    private func saveSizes(_ split: NSSplitView) {
        let sidebarWidth = sidebarItem.viewController.view.frame.width
        if split === splitView, !sidebarItem.isCollapsed, sidebarWidth >= sidebarItem.minimumThickness {
            PaneSize.sidebar.store(sidebarWidth)
        }
        if split === sidebar.splitView, !outlineItem.isCollapsed, !app.outlineCollapsed {
            PaneSize.outline.store(outlineItem.viewController.view.frame.height)
        }
        if split === area.splitView, !panelItem.isCollapsed { PaneSize.panel.store(panelItem.viewController.view.frame.height) }
        if split === columns.splitView, !pdfItem.isCollapsed {
            let source = sourceItem.viewController.view.frame.width, pdf = pdfItem.viewController.view.frame.width
            if source + pdf > 0 { PaneSize.pdfShare.store(pdf / (source + pdf)) }
        }
    }

    /// The window is leaving the project: nothing more to watch.
    func close() {
        watches.forEach { $0.cancel() }
        drags.forEach(NotificationCenter.default.removeObserver)
        collapses = []
        toolbar.close()
    }

    // ---------- find ----------

    /// Edit › Find's items for the pane with the keyboard: the PDF's while its pages
    /// or its find bar have it, else the source's. Nil turns an item off.
    func findAction(_ action: NSTextFinder.Action) -> (() -> Void)? {
        guard pdfHasKeyboard else { return project.findAction(action) }
        guard project.pdfVersion > 0 else { return nil }
        switch action {
        case .showFindInterface:
            return { [weak self] in self?.showPDFFind() }
        case .nextMatch, .previousMatch:
            guard !pdf.matches.isEmpty else { return nil }
            return { [pdf] in pdf.step(action == .nextMatch ? 1 : -1) }
        case .setSearchString:
            guard let text = pdf.view?.currentSelection?.string, !text.isEmpty else { return nil }
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

    /// Each request once. A hidden column opens first; what needs the pages waits
    /// for it to reach its width and for a PDF it never showed to load.
    private func takePDFRequest() {
        guard let action = app.pdfRequest?.action else { return }
        app.pdfRequest = nil
        setCollapsed(pdfItem, false) { [weak self] in
            guard let self, project.pdfVersion > 0 else { return }
            switch action {
            case .find: perform(action)
            default: pdf.whenShown { [weak self] in self?.perform(action) }
            }
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
        case .print: pdf.view?.print(with: .shared, autoRotate: true)
        case .inverseFromView:
            if case let (page, point)? = pdf.sourcePoint() {
                Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
            }
        }
    }
}

/// Column and pane limits. Each minimum is its content's: the toolbar is the
/// system's to fit, its tools crossing a divider or going into its overflow menu
/// near the window's minimum.
enum ColumnMetrics {
    /// AppKit's inspector width (NSSplitViewItem.h), so the side columns open alike.
    static let sidebarIdeal: CGFloat = 270
    /// About 40 columns of the editor's default font, and a page still legible
    /// fitted to the width. Source and PDF share it, so at their narrowest they
    /// split the room evenly, as they open.
    static let sourceMinimum: CGFloat = 320
    static let pdfMinimum: CGFloat = sourceMinimum
    /// The PDF's share of the room past the side columns, until one is dragged.
    static let pdfShare: CGFloat = 0.5
    /// Source and PDF over the build panel: a find bar and a few lines.
    static let columnsMinimum: CGFloat = 200
    /// The build panel: a header and a few issues; a quarter of the window at first.
    static let panelMinimum: CGFloat = 80
    static let panelShare: CGFloat = 0.25
    /// The sidebar's panes: a few rows each; the outline nearly half at first.
    static let filesMinimum: CGFloat = 100
    static let outlineMinimum: CGFloat = 80
    static let outlineShare: CGFloat = 0.45
    /// The splits' thin dividers (`NSSplitView.DividerStyle.thin`).
    static let divider: CGFloat = 1
    /// The columns' trailing safe-area inset, for the last column's toolbar section
    /// (`buildArea`). That column's minimum counts it.
    static let toolbarInset: CGFloat = 0.5
    /// The window's content at its narrowest, source | PDF, in the whole points the
    /// split keeps: a narrowing window folds the sidebar first (AppKit's way with
    /// sidebars), so two windows tile side by side on the smallest Mac display. At its
    /// shortest, the columns over the build panel. Native accessories contribute
    /// their own minimum rather than a guessed system bar height.
    static let contentMinimum = CGSize(width: (sourceMinimum + divider + pdfMinimum + toolbarInset).rounded(.up),
                                       height: columnsMinimum + divider + panelMinimum)
}

/// Pane sizes, kept across launches in one defaults dictionary.
enum PaneSize: String {
    case sidebar, pdfShare, panel, outline

    var value: CGFloat? {
        (UserDefaults.standard.dictionary(forKey: DefaultsKey.paneSizes)?[rawValue] as? Double).map { CGFloat($0) }
    }

    /// Whole points: a pane half a point off centres its content half a point low.
    func store(_ value: CGFloat) {
        guard value > 0 else { return }
        var sizes = UserDefaults.standard.dictionary(forKey: DefaultsKey.paneSizes) ?? [:]
        sizes[rawValue] = self == .pdfShare ? Double(value) : Double(value.rounded())
        UserDefaults.standard.set(sizes, forKey: DefaultsKey.paneSizes)
    }
}
