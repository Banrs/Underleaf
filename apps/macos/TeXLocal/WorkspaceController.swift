import AppKit
import SwiftUI

/// An open project's window content, as AppKit's split view controllers lay it out:
/// the sidebar | the rest | the inspector; in the rest, source | PDF over the build
/// panel, which spans both, and the status bar at their foot (the item's bottom
/// accessory). Each column's find bar is its top accessory, and the toolbar's sections
/// follow the sidebar's, the source/PDF and the inspector's dividers
/// (`WorkspaceToolbar`). SwiftUI draws every pane.
///
/// AppKit, not `NavigationSplitView`, which can't hide its last column (the PDF), run a
/// panel under two of its columns, or put bars in its columns' accessories; and only
/// an AppKit split gives the toolbar a section per column (`WorkspaceToolbar`).
///
/// The models say what shows: a change they make (View › Hide PDF, a find, a failed
/// build) collapses or shows an item with AppKit's own animation, and the sidebar or
/// the inspector dragged or toggled shut goes back to them.
final class WorkspaceController: NSSplitViewController {
    let app: AppModel
    let project: ProjectModel
    let pdf = PDFController()
    private(set) var toolbar: WorkspaceToolbar!

    /// Source | PDF: the toolbar's second section follows its divider.
    let columns = NSSplitViewController()
    /// The columns over the build panel.
    let area = NSSplitViewController()
    /// The files over the File Outline.
    private let sidebar = NSSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var outlineItem: NSSplitViewItem!
    private(set) var sourceItem: NSSplitViewItem!
    private(set) var pdfItem: NSSplitViewItem!
    private(set) var panelItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    private var outlineBar: NSSplitViewItemAccessoryViewController!
    private var sidebarSearch: NSSplitViewItemAccessoryViewController!
    private var sourceFind: NSSplitViewItemAccessoryViewController!
    private var pdfFind: NSSplitViewItemAccessoryViewController!
    private let sourceFindField = FieldHandle()
    private let searchField = FieldHandle()

    private var watches: [Task<Void, Never>] = []
    private var resizes: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []
    /// Collapses and shows under way: the sizes they pass through aren't kept.
    private var animating = 0
    /// Sizes are kept once the panes have appeared at their own.
    private var keepsSizes = false

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        super.init(nibName: nil, bundle: nil)
        buildSidebar(height: size.height)
        buildInspector()
        buildArea(size: size)
        // Made before the area, which opens in the room the side columns leave.
        addSplitViewItem(inspectorItem)
        toolbar = WorkspaceToolbar(app: app, project: project, pdf: pdf, workspace: self)
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
        // Its line is where the unfolded outline's divider would be, level with the status bar's.
        outlineBar = accessory(OutlineFoldedBar(), hidden: !(showsOutline && app.outlineCollapsed),
                               footOf: sidebar.splitView)
        filesItem.addBottomAlignedAccessoryViewController(outlineBar)

        let outline = host(OutlineList(project: project),
                           height: PaneSize.outline.value ?? height * ColumnMetrics.outlineShare)
        outlineItem = NSSplitViewItem(viewController: outline)
        outlineItem.minimumThickness = ColumnMetrics.outlineMinimum
        // It keeps its height as the window resizes; the files take the change.
        outlineItem.holdingPriority = .defaultLow + 1
        outlineItem.isCollapsed = !showsOutline || app.outlineCollapsed

        sidebar.addSplitViewItem(filesItem)
        sidebar.addSplitViewItem(outlineItem)
        sidebar.view.frame.size.width = PaneSize.sidebar.value ?? ColumnMetrics.sidebarIdeal

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = ColumnMetrics.sidebarWidth.lowerBound
        sidebarItem.maximumThickness = ColumnMetrics.sidebarWidth.upperBound
        sidebarItem.isCollapsed = !app.sidebarVisible
        sidebarSearch = accessory(SidebarSearch(project: project, field: searchField))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    /// Source | PDF over the build panel, the status bar at their foot.
    private func buildArea(size: CGSize) {
        let sidebarWidth = app.sidebarVisible ? sidebar.view.frame.width : 0
        let inspectorWidth = inspectorItem.isCollapsed ? 0 : inspectorItem.viewController.view.frame.width
        let room = max(size.width - sidebarWidth - inspectorWidth, ColumnMetrics.sourceMinimum + ColumnMetrics.pdfMinimum)
        let share = (room * (PaneSize.pdfShare.value ?? ColumnMetrics.pdfShare)).rounded()
        let pdfWidth = min(max(share, ColumnMetrics.pdfMinimum), room - ColumnMetrics.sourceMinimum)
        let panelHeight = PaneSize.panel.value ?? size.height * ColumnMetrics.panelShare

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: room - pdfWidth))
        sourceItem.minimumThickness = ColumnMetrics.sourceMinimum
        sourceFind = accessory(SourceFindBar(project: project, field: sourceFindField), hidden: !project.findShown)
        sourceItem.addTopAlignedAccessoryViewController(sourceFind)

        pdfItem = NSSplitViewItem(viewController: host(PDFPane(project: project, controller: pdf), width: pdfWidth))
        pdfItem.minimumThickness = ColumnMetrics.pdfMinimum
        // Hide PDF alone collapses it, never a drag (the default for a plain item):
        // collapsed at the window's edge, its divider would sit under the resize edge.
        pdfItem.canCollapse = false
        pdfItem.isCollapsed = !project.showPDF
        pdfFind = accessory(PDFFindBar(controller: pdf), hidden: true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)

        columns.splitView.isVertical = true
        columns.splitView.dividerStyle = .thin
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)

        panelItem = NSSplitViewItem(viewController: host(PanelView(project: project), height: panelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        // It keeps its height as the window resizes; the columns take the change.
        panelItem.holdingPriority = .defaultLow + 1
        panelItem.isCollapsed = !project.showLogs

        area.splitView.isVertical = false
        area.splitView.dividerStyle = .thin
        let columnsItem = NSSplitViewItem(viewController: columns)
        // The panel dragged up stops short of the find bar and a few lines.
        columnsItem.minimumThickness = ColumnMetrics.columnsMinimum
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)

        let areaItem = NSSplitViewItem(viewController: area)
        areaItem.addBottomAlignedAccessoryViewController(accessory(StatusBar(project: project, pdf: pdf),
                                                                   footOf: area.splitView, clearsCorners: true))
        addSplitViewItem(areaItem)
    }

    /// The project's settings and facts, at AppKit's fixed inspector width, as the
    /// Format inspector in Pages and Keynote.
    private func buildInspector() {
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project)))
        inspectorItem.viewController.view.frame.size.width = inspectorItem.minimumThickness
        inspectorItem.isCollapsed = !app.inspectorVisible
    }

    /// The fixed inspector's divider takes no drag, so it shows no resize cursor.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect,
                                   ofDividerAt: dividerIndex)
        let inspectorDivider = splitViewItems.firstIndex { $0 === inspectorItem }.map { $0 - 1 }
        return splitView === self.splitView && dividerIndex == inspectorDivider ? .zero : rect
    }

    /// A pane: SwiftUI whose sizes stay out of Auto Layout, so the split item's
    /// limits size it and its content never sets the window's minimum.
    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0) -> NSViewController {
        let host = NSHostingController(rootView: content.environment(app))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        return host
    }

    /// A bar along a pane's top or foot, as tall as its content, as wide as the pane.
    /// A foot bar has a line over it, `split`'s divider as it would be there; with
    /// `clearsCorners` its ends keep clear of the window's rounded corners where they
    /// meet them (the status bar's).
    private func accessory(_ content: some View, hidden: Bool = false, footOf split: NSSplitView? = nil,
                           clearsCorners: Bool = false) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        let host = NSHostingView(rootView: content.environment(app))
        host.sizingOptions = [.intrinsicContentSize]
        // Its height from its content; its width is the pane's.
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let split {
            let bar = NSView()
            let hairline = Hairline(split: split)
            for view in [host, hairline] {
                view.translatesAutoresizingMaskIntoConstraints = false
                bar.addSubview(view)
            }
            let ends = clearsCorners ? bar.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal)) : nil
            NSLayoutConstraint.activate([
                hairline.topAnchor.constraint(equalTo: bar.topAnchor),
                hairline.heightAnchor.constraint(equalToConstant: split.dividerThickness),
                hairline.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                host.topAnchor.constraint(equalTo: bar.topAnchor),
                host.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: ends?.leadingAnchor ?? bar.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: ends?.trailingAnchor ?? bar.trailingAnchor),
            ])
            accessory.view = bar
        } else {
            accessory.view = host
        }
        // The bars inset their controls by the UI kit's 8 pt themselves.
        accessory.automaticallyAppliesContentInsets = false
        accessory.isHidden = hidden
        return accessory
    }

    /// Search results take the whole sidebar; only LaTeX has an outline.
    private var showsOutline: Bool { project.searchQuery.isEmpty && project.isLaTeX }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The editor has the keyboard as the project opens.
        if let window = view.window, window.firstResponder === window { project.editor.focus() }
        // After this turn: the first layout places the panes at the sizes they were made with.
        Task { [weak self] in self?.keepsSizes = true }
    }

    // ---------- the models drive the panes ----------

    private func watch() {
        let app = app, project = project, pdf = pdf
        watches = [
            track({ app.sidebarVisible }) { [weak self] visible in
                guard let self else { return }
                setCollapsed(sidebarItem, !visible)
            },
            track({ app.inspectorVisible }) { [weak self] visible in
                guard let self else { return }
                setCollapsed(inspectorItem, !visible)
            },
            track({ project.showPDF }) { [weak self] shown in
                guard let self else { return }
                setCollapsed(pdfItem, !shown)
            },
            track({ project.showLogs }) { [weak self] shown in
                guard let self else { return }
                setCollapsed(panelItem, !shown)
            },
            track({ OutlineState(shown: project.searchQuery.isEmpty && project.isLaTeX,
                                   collapsed: app.outlineCollapsed) }) { [weak self] state in
                guard let self else { return }
                setCollapsed(outlineItem, !state.shown || state.collapsed)
                setHidden(outlineBar, !(state.shown && state.collapsed))
            },
            track({ project.findShown }) { [weak self] shown in
                guard let self else { return }
                setHidden(sourceFind, !shown)
            },
            // ⌘F, or Find and Replace…, again while the bar shows: back to its field.
            track({ project.findFocus }) { [weak self] focus in
                guard let self, focus > 0 else { return }
                setHidden(sourceFind, false)
                focusField(sourceFindField, in: sourceFind)
            },
            track({ pdf.finding }) { [weak self] finding in
                guard let self else { return }
                setHidden(pdfFind, !finding)
            },
            track({ app.pdfRequest?.token }) { [weak self] _ in self?.takePDFRequest() },
            track({ app.searchFocusToken }, initial: false) { [weak self] _ in self?.focusSearch() },
        ]
        collapses = [
            follow(sidebarItem) { [app] visible in if app.sidebarVisible != visible { app.sidebarVisible = visible } },
            follow(inspectorItem) { [app] visible in if app.inspectorVisible != visible { app.inspectorVisible = visible } },
        ]
        for split in [splitView, sidebar.splitView, columns.splitView, area.splitView] {
            resizes.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSSplitView.didResizeSubviewsNotification,
                                                                        object: split) {
                    guard let self else { return }
                    if keepsSizes, animating == 0 { saveSizes() }
                }
            })
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

    /// With AppKit's collapse animation, unless the window isn't on screen or
    /// Reduce Motion is on. `done` runs once the pane is at its size.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, done: (@MainActor () -> Void)? = nil) {
        guard item.isCollapsed != collapsed, animates else {
            item.isCollapsed = collapsed
            view.layoutSubtreeIfNeeded()
            done?()
            return
        }
        animating += 1
        NSAnimationContext.runAnimationGroup { _ in
            item.animator().isCollapsed = collapsed
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.animating -= 1
                done?()
            }
        }
    }

    private func setHidden(_ accessory: NSSplitViewItemAccessoryViewController, _ hidden: Bool) {
        guard accessory.isHidden != hidden else { return }
        guard animates else {
            accessory.isHidden = hidden
            return
        }
        animating += 1
        NSAnimationContext.runAnimationGroup { _ in
            accessory.animator().isHidden = hidden
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.animating -= 1 }
        }
    }

    private var animates: Bool {
        view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A field in an accessory: always in the window, so it takes the keyboard at once.
    private func focusField(_ field: FieldHandle, in accessory: NSSplitViewItemAccessoryViewController) {
        if field.field == nil { accessory.view.layoutSubtreeIfNeeded() }
        field.focus()
    }

    /// Find in Project…: the sidebar opens with its search field taking the keyboard.
    private func focusSearch() {
        let wasCollapsed = sidebarItem.isCollapsed
        setCollapsed(sidebarItem, false) { [weak self] in
            guard let self, wasCollapsed else { return }
            focusField(searchField, in: sidebarSearch)
        }
        // At once too, so typing during the animation lands in the field.
        focusField(searchField, in: sidebarSearch)
    }

    /// Whether a text field is one of the find bars': it gets `FindFieldEditor`.
    func hostsFindField(_ field: NSTextField) -> Bool {
        field.isDescendant(of: sourceFind.view) || field.isDescendant(of: pdfFind.view)
    }

    // ---------- sizes ----------

    /// Keeps the shown panes' sizes, for this launch's collapses and the next launch:
    /// the sizes they're dragged to, not those a narrowing window squeezes them to.
    func saveSizes() {
        guard let window = view.window, !window.inLiveResize else { return }
        let sidebarWidth = sidebarItem.viewController.view.frame.width
        if !sidebarItem.isCollapsed, sidebarWidth >= sidebarItem.minimumThickness {
            PaneSize.sidebar.store(sidebarWidth)
        }
        if !outlineItem.isCollapsed { PaneSize.outline.store(outlineItem.viewController.view.frame.height) }
        if !panelItem.isCollapsed { PaneSize.panel.store(panelItem.viewController.view.frame.height) }
        if !pdfItem.isCollapsed {
            let source = sourceItem.viewController.view.frame.width, pdf = pdfItem.viewController.view.frame.width
            if source + pdf > 0 { PaneSize.pdfShare.store(pdf / (source + pdf)) }
        }
    }

    /// The window is leaving the project: nothing more to watch.
    func close() {
        saveSizes()
        watches.forEach { $0.cancel() }
        resizes.forEach { $0.cancel() }
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
        guard action.showsPDF else { return perform(action) }
        setCollapsed(pdfItem, false) { [weak self] in
            guard let self, project.pdfVersion > 0 else { return }
            switch action {
            case .find, .share: perform(action)
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
        case .share: sharePDF()
        case .inverseFromView:
            if case let (page, point)? = pdf.sourcePoint() {
                Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
            }
        }
    }

    /// File › Share…: the share picker under the top of the PDF, or the source while
    /// the PDF is hidden. AppKit: SwiftUI opens a share picker only from a `ShareLink`.
    private func sharePDF() {
        guard project.pdfVersion > 0, let url = project.pdfURL else { return }
        let column = (pdfItem.isCollapsed ? sourceItem : pdfItem).viewController.view
        let area = column.safeAreaRect
        let top = NSRect(x: area.midX, y: column.isFlipped ? area.minY : area.maxY - 1, width: 1, height: 1)
        NSSharingServicePicker(items: [url]).show(relativeTo: top, of: column,
                                                   preferredEdge: column.isFlipped ? .maxY : .minY)
    }
}

/// A split view's thin divider, drawn along a bar's top: the same colour and
/// thickness as the dividers it continues.
private final class Hairline: NSView {
    private weak var split: NSSplitView?

    init(split: NSSplitView) {
        self.split = split
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        (split?.dividerColor ?? .separatorColor).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// Whether the File Outline shows, and whether it's folded to its header.
private nonisolated struct OutlineState: Equatable {
    let shown: Bool
    let collapsed: Bool
}

/// Column and pane limits. Each minimum is its content's: the toolbar is the
/// system's to fit, its tools crossing a divider or going into its overflow menu
/// near the window's minimum.
enum ColumnMetrics {
    static let sidebarWidth: ClosedRange<CGFloat> = 200...400
    /// AppKit's inspector width (NSSplitViewItem.h), so the side columns open alike.
    static let sidebarIdeal: CGFloat = 270
    /// About 40 columns of the editor's default font.
    static let sourceMinimum: CGFloat = 320
    /// A page still legible, fitted to the width.
    static let pdfMinimum: CGFloat = 280
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
    /// The window's content at its narrowest: the source and the PDF, a divider
    /// between. The sidebar folds first, as a narrowing window folds Mail's, so two
    /// windows tile side by side on the smallest Mac display (1470 pt wide).
    static let contentMinimumWidth = sourceMinimum + 1 + pdfMinimum
    /// And at its shortest: the columns over the build panel, then the status bar.
    static let contentMinimumHeight = columnsMinimum + 1 + panelMinimum + BarMetrics.secondaryBarHeight
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
