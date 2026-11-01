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
    private let area = ThinSplitViewController(isVertical: false)
    private var sidebarItem, sourceItem, pdfItem, panelItem, inspectorItem, areaItem: NSSplitViewItem!
    private var pdfFind: NSSplitViewItemAccessoryViewController!
    private var pdfEmpty: NSView!
    private let searchField = FieldHandle()
    private let inspectorMount = Mount()

    private var appeared = false
    private var quieting = 0
    private var quietScrollViews: [NSScrollView] = []
    private var watches: [Task<Void, Never>] = []

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
        for item in [sidebarItem, sourceItem, pdfItem, panelItem, inspectorItem] {
            item!.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        }
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        inspectorMount.shown = !inspectorItem.isCollapsed
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

    override func viewDidLayout() {
        super.viewDidLayout()
        if views.inspectorShown == inspectorItem.isCollapsed { views.inspectorShown.toggle() }
    }

    func fitToolbar() {
        func edges(_ item: NSSplitViewItem) -> NSRect { item.viewController.view.convert(item.viewController.view.bounds, to: splitView) }
        let source = edges(sourceItem), area = edges(areaItem)
        let leading = max(source.minX, ColumnMetrics.windowControls)
        let trailing = min(area.maxX, splitView.bounds.maxX - ColumnMetrics.toggles)
        let tools = trailing - leading - ColumnMetrics.sourceTools + (window.showSource ? 0 : ColumnMetrics.editingTools)
        let room = pdfItem.isCollapsed ? tools - ColumnMetrics.separator
            : min(tools, pdfItem.viewController.view.frame.width - (area.maxX - trailing)) - ColumnMetrics.zoom
        let compact = room < ColumnMetrics.compile
        let dragged = splitViews.contains { ($0 as? DraggedSplitView)?.dragging == true }
        if compact || quieting == (dragged ? 1 : 0) { toolbar.compactCompile = compact }
    }

    private func buildSidebar() {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: host(NavigatorPane(project: project, field: searchField), width: Self.sidebarWidth))
        sidebarItem.minimumThickness = 222
        sidebarItem.addTopAlignedAccessoryViewController(accessory(NavigatorBar(project: project), edge: .soft))
        sidebarItem.addBottomAlignedAccessoryViewController(accessory(hostingView(NavigatorFilter(project: project)), edge: .soft))
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
        sourceItem.addTopAlignedAccessoryViewController(accessory(hostingView(EditorJumpBar(project: project)), edge: .soft))
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
        pdfItem.addTopAlignedAccessoryViewController(accessory(hostingView(PDFJumpBar(project: project, pdf: pdf)), edge: .soft))
        pdfFind = accessory(hostingView(PDFFindBar(find: pdf.find)))
        (pdfFind.isHidden, pdfFind.view.isHidden) = (true, true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)
        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project), height: app.buildPanelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
        panelItem.holdingPriority = .defaultLow + 1
        panelItem.canCollapse = true
        panelItem.isCollapsed = true
        let columnsItem = NSSplitViewItem(viewController: columns)
        columnsItem.minimumThickness = 200
        columnsItem.addBottomAlignedAccessoryViewController(accessory(hostingView(StatusBar(project: project)), edge: .hard))
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
        views.inspectorShown = inspectorItem.isCollapsed
        super.toggleInspector(sender)
    }

    func revealSidebar() { setCollapsed(sidebarItem, false) }

    func focusSearch() {
        project.navigator.shown = .search
        revealSidebar()
        sidebarItem.viewController.view.layoutSubtreeIfNeeded()
        searchField.focus()
    }

    func dragged(_ split: NSSplitView) {
        if split === area.splitView, project.panel.shown == panelItem.isCollapsed { project.panel.shown.toggle() }
    }

    private func host(_ content: some View, width: CGFloat = 0, height: CGFloat = 0, mount: Mount? = nil) -> NSViewController {
        let host = NSHostingController(rootView: Pane(project: project, mount: mount, content: content)
            .environment(app).environment(window).environment(views))
        host.sizingOptions = []
        host.view.frame.size = CGSize(width: width, height: height)
        return host
    }

    private func hostingView(_ content: some View) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: Pane(project: project, content: content).environment(app).environment(window).environment(views))
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return host
    }

    private func accessory(_ view: NSView, edge: NSScrollEdgeEffectStyle? = nil) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = view
        if let edge {
            accessory.automaticallyAppliesContentInsets = false
            accessory.preferredScrollEdgeEffectStyle = edge
        }
        return accessory
    }

    private func watch() {
        let window = window, project = project, pdf = pdf
        watches = [
            track({ [window.showSource, window.showPDF] }) { [weak self] _ in self?.showPanes() },
            track({ project.panel.shown }) { [weak self] in self?.setPanelShown($0) },
            track({ pdf.find.isOpen }) { [weak self] in if let self { setHidden(pdfFind, !$0) } },
            track({ project.hasPDF }) { [weak self] in self?.pdfEmpty.isHidden = $0 },
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
        if let responder = view.window?.firstResponder as? NSView {
            if !window.showSource, responder.isDescendant(of: sourceItem.viewController.view) {
                view.window?.makeFirstResponder(pdf.view)
            } else if !window.showPDF, responder.isDescendant(of: pdfItem.viewController.view) {
                views.focusEditor()
            }
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

    private func focus(_ field: FieldHandle, in accessory: NSSplitViewItemAccessoryViewController) {
        if field.field == nil { accessory.view.layoutSubtreeIfNeeded() }
        field.focus()
    }

    func close() {
        if !panelItem.isCollapsed { keepPanelHeight() }
        for split in splitViews { split.autosaveName = nil }
        watches.forEach { $0.cancel() }
        toolbar.close()
    }

    func performPDF(_ action: PDFAction) {
        fitColumns()
        setCollapsed(pdfItem, false) { [weak self] in
            guard let self else { return }
            views.perform(action) {
                pdf.find.isOpen = true
                setHidden(pdfFind, false)
                focus(pdf.find.field, in: pdfFind)
            }
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
