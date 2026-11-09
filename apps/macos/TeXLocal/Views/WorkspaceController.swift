import AppKit
import SwiftUI

final class WorkspaceController: ThinSplitViewController {
    let window: WindowModel
    private var app: AppModel { window.app }
    let views: WorkspaceViews
    var project: ProjectModel { views.project }
    var pdf: PDFController { views.pdf }
    let toolbar: WorkspaceToolbar

    let columns = ThinSplitViewController(splitView: ColumnsSplitView())
    private let area = AreaSplitViewController(isVertical: false)
    private var sidebarItem, sourceItem, pdfItem, panelItem, inspectorItem, areaItem: NSSplitViewItem!
    private var pdfEmpty: NSView!
    private let searchField = FieldHandle()
    private let inspectorMount = Mount()

    private var appeared = false
    private var quieting = 0
    private var quietScrollViews: [NSScrollView] = []
    private var watches: [Task<Void, Never>] = []
    private var collapses: [NSKeyValueObservation] = []

    init(window: WindowModel, views: WorkspaceViews, size: CGSize) {
        self.window = window
        self.views = views
        toolbar = WorkspaceToolbar(window: window, views: views)
        super.init()
        toolbar.workspace = self
        if app.savesLayout {
            for (split, name) in zip(splitViews, ["Workspace 2", "Columns", "Area"]) {
                split.autosaveName = name
            }
        }
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project), mount: inspectorMount))
        inspectorItem.isCollapsed = true
        inspectorItem.canCollapseFromWindowResize = true
        inspectorItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        buildSidebar()
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
        for item in splitItems {
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        }
        watch()
        collapses = splitItems.map { item in
            let id = ObjectIdentifier(item)
            return item.observe(\.isCollapsed, options: .prior) { [weak self] _, change in
                let before = change.isPrior
                MainActor.assumeIsolated { self?.collapse(id, before: before) }
            }
        }
        NotificationCenter.default.addObserver(toolbar, selector: #selector(WorkspaceToolbar.fit), name: NSView.frameDidChangeNotification, object: area.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        inspectorMount.shown = !inspectorItem.isCollapsed
        views.inspectorShown = !inspectorItem.isCollapsed
        if !panelItem.isCollapsed { project.panel.shown = true }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !appeared else { return }
        appeared = true
        sourceItem.isCollapsed = !window.showSource
        pdfItem.isCollapsed = !window.showPDF
        fitColumns()
    }

    private func fitColumns() {
        let both = window.showSource && window.showPDF
        let area = both ? 2 * ColumnMetrics.paneMinimum + columns.splitView.dividerThickness : ColumnMetrics.paneMinimum
        if areaItem.minimumThickness != area { areaItem.minimumThickness = area }
    }

    var toolbarRoom: CGFloat { areaItem.viewController.view.frame.width }

    private func buildSidebar() {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: NavigatorArea(host(NavigatorPane(project: project, field: searchField), width: Self.sidebarWidth)))
        sidebarItem.minimumThickness = 222
        sidebarItem.addBottomAlignedAccessoryViewController(accessory(NavigatorFilterBar(project: project, window: window), edge: .soft))
        addSplitViewItem(sidebarItem)
    }

    private static let sidebarWidth: CGFloat = 270

    private func buildArea(size: CGSize) {
        let panes = max(size.width - Self.sidebarWidth, 2 * ColumnMetrics.paneMinimum)
        let pdfWidth = min((panes * ColumnMetrics.pdfShare).rounded(), panes - ColumnMetrics.paneMinimum)
        if app.buildPanelHeight < ColumnMetrics.panelMinimum {
            app.buildPanelHeight = max(ColumnMetrics.panelMinimum, (size.height * 0.25).rounded())
        }

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: panes - pdfWidth))
        sourceItem.minimumThickness = ColumnMetrics.paneMinimum
        let pdfPane = NSViewController()
        pdfPane.view = NSView(frame: NSRect(x: 0, y: 0, width: pdfWidth, height: 0))
        let empty = NSHostingView(rootView: Pane(project: project, content: PDFEmptyState(project: project)).environment(app).environment(window))
        empty.sizingOptions = []
        pdfEmpty = empty
        for pane in [pdf.view, empty] as [NSView] {
            pane.frame = pdfPane.view.bounds
            pane.autoresizingMask = [.width, .height]
            pdfPane.view.addSubview(pane)
        }
        pdfItem = NSSplitViewItem(viewController: pdfPane)
        pdfItem.minimumThickness = ColumnMetrics.paneMinimum
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
        for item in [sourceItem!, pdfItem!] {
            let space = NSView()
            space.heightAnchor.constraint(equalToConstant: BarMetrics.height).isActive = true
            item.addBottomAlignedAccessoryViewController(accessory(space, edge: .hard))
        }
        let bar = NSHostingView(rootView: Pane(project: project, content: StatusBar(project: project))
            .environment(app).environment(window).environment(views))
        bar.sizingOptions = []
        bar.safeAreaRegions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        columns.view.addSubview(bar)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: columns.view.leadingAnchor),
                                     bar.trailingAnchor.constraint(equalTo: columns.view.trailingAnchor),
                                     bar.bottomAnchor.constraint(equalTo: columns.view.bottomAnchor),
                                     // Its edge lies on the row above the panes' accessories, over their scroll edges' own line.
                                     bar.heightAnchor.constraint(equalToConstant: BarMetrics.height + BarMetrics.edge.thickness)])

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project), height: app.buildPanelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        panelItem.holdingPriority = .defaultLow + 1
        panelItem.canCollapse = true
        panelItem.isCollapsed = true
        let columnsItem = NSSplitViewItem(viewController: columns)
        columnsItem.minimumThickness = 200
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)
        areaItem = NSSplitViewItem(viewController: area)
        addSplitViewItem(areaItem)
    }

    override func toggleInspector(_ sender: Any?) {
        if !inspectorMount.shown {
            inspectorMount.shown = true
            inspectorItem.viewController.view.layoutSubtreeIfNeeded()
        }
        super.toggleInspector(sender)
    }

    func revealSidebar() { setCollapsed(sidebarItem, false) }

    func focusSearch() {
        project.navigator.shown = .search
        revealSidebar()
        sidebarItem.viewController.view.layoutSubtreeIfNeeded()
        searchField.focus()
    }

    private func collapse(_ id: ObjectIdentifier, before: Bool) {
        guard let item = splitItems.first(where: { ObjectIdentifier($0) == id }) else { return }
        guard before else {
            if item === panelItem, project.panel.shown == item.isCollapsed { project.panel.shown.toggle() }
            if item === inspectorItem { views.inspectorShown = !item.isCollapsed }
            return
        }
        guard !item.isCollapsed, let window = view.window, let responder = window.firstResponder as? NSView,
              ([item.viewController] + item.topAlignedAccessoryViewControllers + item.bottomAlignedAccessoryViewControllers)
                .contains(where: { responder.isDescendant(of: $0.view) }) else { return }
        if item !== sourceItem, !sourceItem.isCollapsed, views.editor.shown {
            views.focusEditor()
        } else {
            window.makeFirstResponder(pdf.view)
        }
    }

    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0, mount: Mount? = nil) -> NSViewController {
        let host = NSHostingController(rootView: Pane(project: project, mount: mount, content: content)
            .environment(app).environment(window).environment(views))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        return host
    }

    private func accessory(_ view: NSView, edge: NSScrollEdgeEffectStyle) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = view
        accessory.automaticallyAppliesContentInsets = false
        accessory.preferredScrollEdgeEffectStyle = edge
        return accessory
    }

    private func watch() {
        let window = window, project = project, pdf = pdf
        watches = [
            track({ [window.showSource, window.showPDF] }) { [weak self] _ in self?.showPanes() },
            track({ project.panel.shown }) { [weak self] in self?.setPanelShown($0) },
            track({ project.hasPDF || pdf.isLoading }) { [weak self] in self?.pdfEmpty.isHidden = $0 },
            track({ project.closed }, initial: false) { [weak self] _ in self?.view.window?.makeFirstResponder(nil) },
        ]
    }

    private func showPanes() {
        guard appeared else { return }
        fitColumns()
        quiet(true)
        Task.immediate {
            await NSAnimationContext.runAnimationGroup { context in
                if !animates { context.duration = 0 }
                sourceItem.animator().isCollapsed = !window.showSource
                pdfItem.animator().isCollapsed = !window.showPDF
            }
            quiet(false)
        }
    }

    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, done: @escaping @MainActor () -> Void = {}) {
        guard item.isCollapsed != collapsed else { return done() }
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

    private var splitViews: [NSSplitView] { [splitView, columns.splitView, area.splitView] }
    private var splitItems: [NSSplitViewItem] { [sidebarItem, sourceItem, pdfItem, panelItem, inspectorItem] }

    func quiet(_ resizing: Bool) {
        quieting += resizing ? 1 : -1
        guard quieting == (resizing ? 1 : 0) else { return }
        if resizing { quietScrollViews = view.descendants(of: NSScrollView.self) }
        for scroll in quietScrollViews { scroll.hideOverlayScrollers(resizing) }
        if !resizing { quietScrollViews = [] }
    }

    private func setPanelShown(_ shown: Bool) {
        guard shown == panelItem.isCollapsed else { return }
        let split = area.splitView, panel = panelItem.viewController.view
        if !shown { keepPanelHeight() }
        guard animates else {
            setCollapsed(panelItem, !shown)
            if shown { split.setPosition(split.bounds.height - split.dividerThickness - app.buildPanelHeight, ofDividerAt: 0) }
            return
        }
        if shown, split.arrangedSubviews[1].isHidden {
            let room = split.bounds.height - split.dividerThickness - area.view.safeAreaInsets.top - area.splitViewItems[0].minimumThickness
            panel.frame.size.height = min(app.buildPanelHeight, room)
        }
        setCollapsed(panelItem, !shown)
    }

    private func keepPanelHeight() { app.buildPanelHeight = panelItem.viewController.view.frame.height }

    private var animates: Bool { view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func close() {
        if !panelItem.isCollapsed { keepPanelHeight() }
        for split in splitViews { split.autosaveName = nil }
        watches.forEach { $0.cancel() }
        collapses = []
        toolbar.close()
    }

    func performPDF(_ action: PDFAction) {
        fitColumns()
        setCollapsed(pdfItem, false) { [weak self] in
            guard let self else { return }
            views.perform(action) { pdf.view.find.perform(.showFindInterface) }
        }
    }
}

@Observable private final class Mount {
    var shown = false
}

private struct Pane<Content: View>: View {
    let project: ProjectModel
    var mount: Mount?
    let content: Content

    var body: some View { if mount?.shown ?? true { content.disabled(!project.isOpen) } }
}

private final class AreaSplitViewController: ThinSplitViewController {
    override func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        let line = splitView.arrangedSubviews[0].frame.maxY - BarMetrics.height
        return NSUnionRect(super.splitView(splitView, additionalEffectiveRectOfDividerAt: dividerIndex),
                           NSRect(x: 0, y: line - 2, width: splitView.bounds.width, height: splitView.dividerThickness + 4))
    }
}
