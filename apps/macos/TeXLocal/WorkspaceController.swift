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
final class WorkspaceController: DetentSplitViewController {
    let app: AppModel
    let project: ProjectModel
    let pdf = PDFController()
    private(set) var toolbar: WorkspaceToolbar!

    /// Source | PDF: the toolbar's second section follows its divider.
    let columns = DetentSplitViewController()
    /// The columns over the build panel.
    let area = NSSplitViewController()
    /// The files over the File Outline.
    private let sidebar = OutlineSplitViewController()
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
    private var collapses: [NSKeyValueObservation] = []
    private var drags: [NotificationCenter.ObservationToken] = []

    init(app: AppModel, project: ProjectModel, size: CGSize) {
        self.app = app
        self.project = project
        super.init(nibName: nil, bundle: nil)
        buildSidebar(height: size.height)
        buildInspector()
        buildArea(size: size)
        // Made before the area, which opens in the room the side columns leave.
        addSplitViewItem(inspectorItem)
        // The sidebar's opening width, and source and PDF at half each.
        detent = { [unowned self] divider in
            divider == 0 && !sidebarItem.isCollapsed ? ColumnMetrics.sidebarIdeal : nil
        }
        columns.detent = { [unowned columns] _ in
            let split = columns.splitView
            return ((split.bounds.width - split.dividerThickness) / 2).rounded(.down)
        }
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
        // The outline's header, folded or not: its line stands for the divider under it,
        // and folded, it's level with the status bar's.
        outlineBar = accessory(OutlineHeader(), hidden: !showsOutline, footOf: sidebar.splitView)
        filesItem.addBottomAlignedAccessoryViewController(outlineBar)
        sidebar.header = outlineBar

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
        sidebarItem.isCollapsed = !app.sidebarVisible
        sidebarSearch = accessory(SidebarSearch(project: project, field: searchField))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

    /// Source | PDF over the build panel, the status bar at their foot.
    private func buildArea(size: CGSize) {
        let sidebarWidth = app.sidebarVisible ? sidebar.view.frame.width : 0
        let inspectorWidth = inspectorItem.isCollapsed ? 0 : inspectorItem.viewController.view.frame.width
        let room = max(size.width - sidebarWidth - inspectorWidth, ColumnMetrics.contentMinimumWidth)
        let panes = room - ColumnMetrics.divider
        let pdfWidth = keptPDFWidth(in: panes)
        let panelHeight = PaneSize.panel.value ?? size.height * ColumnMetrics.panelShare

        sourceItem = NSSplitViewItem(viewController: host(SourceColumn(project: project), width: panes - pdfWidth))
        sourceItem.minimumThickness = ColumnMetrics.sourceMinimum
        sourceFind = accessory(SourceFindBar(project: project, field: sourceFindField), hidden: !project.findShown)
        sourceItem.addTopAlignedAccessoryViewController(sourceFind)

        pdfItem = NSSplitViewItem(viewController: host(PDFPane(project: project, controller: pdf), width: pdfWidth))
        pdfItem.minimumThickness = ColumnMetrics.pdfMinimum
        pdfItem.isCollapsed = !project.showPDF
        pdfFind = accessory(PDFFindBar(controller: pdf), hidden: true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)

        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)

        panelItem = NSSplitViewItem(viewController: host(BuildPanel(project: project), height: panelHeight))
        panelItem.minimumThickness = ColumnMetrics.panelMinimum
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
        areaItem.addBottomAlignedAccessoryViewController(accessory(StatusBar(project: project, pdf: pdf),
                                                                   footOf: area.splitView, clearsCorners: true))
        addSplitViewItem(areaItem)
    }

    /// The PDF's kept share of `panes` (source and PDF, less the divider), leaving
    /// both their minimums.
    private func keptPDFWidth(in panes: CGFloat) -> CGFloat {
        let share = (panes * (PaneSize.pdfShare.value ?? ColumnMetrics.pdfShare)).rounded()
        return min(max(share, ColumnMetrics.pdfMinimum), panes - ColumnMetrics.sourceMinimum)
    }

    /// The project's settings and facts, at AppKit's fixed inspector width: a column
    /// of settings needs no more.
    private func buildInspector() {
        inspectorItem = NSSplitViewItem(inspectorWithViewController: host(InspectorView(project: project)))
        inspectorItem.viewController.view.frame.size.width = inspectorItem.minimumThickness
        inspectorItem.isCollapsed = !app.inspectorVisible
    }

    /// The fixed inspector's divider takes no drag, so it shows no resize cursor.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard dividerIndex != splitViewItems.firstIndex(of: inspectorItem)! - 1 else { return .zero }
        return super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect,
                               ofDividerAt: dividerIndex)
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
    /// A foot bar has a line over it, `split`'s divider as it would be there, and its
    /// content under the line; with `clearsCorners` its ends keep clear of the
    /// window's rounded corners where they meet them (the status bar's).
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
            let leading = host.leadingAnchor.constraint(equalTo: bar.leadingAnchor)
            let trailing = bar.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            if clearsCorners {
                // At a corner, the content (inset 8 pt itself) 16 pt from the window's
                // edge, where the corner-adapted safe area ends: Xcode's bottom bars.
                let corners = bar.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
                leading.priority = .defaultHigh
                trailing.priority = .defaultHigh
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(greaterThanOrEqualTo: corners.leadingAnchor, constant: -BarMetrics.inset),
                    corners.trailingAnchor.constraint(greaterThanOrEqualTo: host.trailingAnchor, constant: -BarMetrics.inset),
                ])
            }
            NSLayoutConstraint.activate([
                hairline.topAnchor.constraint(equalTo: bar.topAnchor),
                hairline.heightAnchor.constraint(equalToConstant: split.dividerThickness),
                hairline.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                host.topAnchor.constraint(equalTo: hairline.bottomAnchor),
                host.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                leading, trailing,
            ])
            accessory.view = bar
        } else {
            accessory.view = host
        }
        // The bars inset their controls by the UI kit's 8 pt themselves.
        accessory.automaticallyAppliesContentInsets = false
        accessory.isHidden = hidden
        accessory.view.isHidden = hidden
        return accessory
    }

    /// Search results take the whole sidebar; only LaTeX has an outline.
    private var showsOutline: Bool { !project.isSearching && project.isLaTeX }

    // ---------- the models drive the panes ----------

    private func watch() {
        let app = app, project = project, pdf = pdf
        watches = [
            track({ app.sidebarVisible }) { [weak self] visible in if let self { setCollapsed(sidebarItem, !visible) } },
            track({ app.inspectorVisible }) { [weak self] visible in if let self { setCollapsed(inspectorItem, !visible) } },
            track({ project.showPDF }) { [weak self] in self?.setPDFShown($0) },
            track({ project.showLogs }) { [weak self] in self?.setPanelShown($0) },
            track({ OutlineState(shown: !project.isSearching && project.isLaTeX,
                                   collapsed: app.outlineCollapsed) }) { [weak self] state in
                guard let self else { return }
                setCollapsed(outlineItem, !state.shown || state.collapsed)
                setHidden(outlineBar, !state.shown)
            },
            track({ project.findShown }) { [weak self] shown in if let self { setHidden(sourceFind, !shown) } },
            // ⌘F, or Find and Replace…, again while the bar shows: back to its field.
            track({ project.findFocus }) { [weak self] focus in
                guard let self, focus > 0 else { return }
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
        // Sizes as they're dragged to, not as a resized window squeezes them or a
        // collapse passes through them.
        drags = [splitView, sidebar.splitView, columns.splitView, area.splitView].map { split in
            NotificationCenter.default.addObserver(of: split, for: .didResizeSubviews) { [weak self] message in
                if message.userResize { self?.saveSizes() }
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

    /// With AppKit's collapse animation, unless the window isn't on screen or
    /// Reduce Motion is on. `done` runs once the pane is at its size.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, done: (@MainActor () -> Void)? = nil) {
        guard item.isCollapsed != collapsed else { return done?() ?? () }
        guard animates else {
            item.isCollapsed = collapsed
            view.layoutSubtreeIfNeeded()
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup { _ in
            item.animator().isCollapsed = collapsed
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
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

    /// Show PDF brings it back at its kept share, as it opens with the project.
    /// macOS 27.2 uncollapses a pane to its frame, 27.0 to its minimum, so the PDF
    /// has both until it's back.
    private func setPDFShown(_ shown: Bool, done: (@MainActor () -> Void)? = nil) {
        guard shown, pdfItem.isCollapsed else { return setCollapsed(pdfItem, !shown, done: done) }
        let split = columns.splitView
        let width = keptPDFWidth(in: split.bounds.width - split.dividerThickness)
        pdfItem.viewController.view.frame.size.width = width
        pdfItem.minimumThickness = width
        setCollapsed(pdfItem, false) { [weak self] in
            self?.pdfItem.minimumThickness = ColumnMetrics.pdfMinimum
            done?()
        }
    }

    /// Show Build Panel brings it back at its kept height, its frame. On macOS 27.2
    /// that's enough, and lowering a minimum raised for it jumped the panel a status
    /// bar's height for a frame; 27.0 uncollapses to the minimum, so there it holds
    /// the height as its minimum until it's back, as the PDF does its width. It rises
    /// from and sinks under the status bar, whose glass showed its header: faded in
    /// slowly and out quickly, it's clear by then.
    private func setPanelShown(_ shown: Bool) {
        guard shown == panelItem.isCollapsed else { return }
        let panel = panelItem.viewController.view
        if animates {
            panel.alphaValue = shown ? 0 : 1
            NSAnimationContext.runAnimationGroup { context in
                context.timingFunction = CAMediaTimingFunction(name: shown ? .easeIn : .easeOut)
                panel.animator().alphaValue = shown ? 1 : 0
            }
        }
        guard shown else { return setCollapsed(panelItem, true) { panel.alphaValue = 1 } }
        let split = area.splitView
        let room = split.bounds.height - split.dividerThickness - ColumnMetrics.columnsMinimum
        let height = min(PaneSize.panel.value ?? split.bounds.height * ColumnMetrics.panelShare, room)
        panel.frame.size.height = height
        if #available(macOS 27.2, *) { return setCollapsed(panelItem, false) }
        panelItem.minimumThickness = max(height, ColumnMetrics.panelMinimum)
        setCollapsed(panelItem, false) { [weak self] in
            self?.panelItem.minimumThickness = ColumnMetrics.panelMinimum
        }
    }

    private var animates: Bool {
        view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A field in an accessory: in the window as soon as its bar shows, so it takes
    /// the keyboard at once.
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
    private func saveSizes() {
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
        guard action.showsPDF else { return perform(action) }
        setPDFShown(true) { [weak self] in
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

/// A split view controller whose dividers can have a detent: a drag that comes
/// within reach stops there, with the system's alignment haptic as it arrives, so
/// a pane goes back to its opening size without measuring. AppKit's split views
/// have none of their own.
class DetentSplitViewController: NSSplitViewController {
    /// A divider's detent, if it has one now, in the split view's coordinates.
    var detent: (_ divider: Int) -> CGFloat? = { _ in nil }

    /// NSSplitViewController doesn't answer this delegate method itself, so
    /// there's no super to call.
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

/// Files over the File Outline, whose header sits at the files' foot, so the
/// divider runs under the header. The header's line, over it, stands for the
/// divider: the divider draws nothing, and its drags are taken on the line.
private final class OutlineSplitViewController: NSSplitViewController {
    /// The outline's header, whose line takes the drags while the outline shows.
    weak var header: NSSplitViewItemAccessoryViewController?

    init() {
        super.init(nibName: nil, bundle: nil)
        splitView = QuietSplitView()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The divider's own reach, moved up onto the header's line.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard let header, !header.isHidden, splitViewItems.last?.isCollapsed == false else { return .zero }
        let frame = header.view.convert(header.view.bounds, to: splitView)
        let line = splitView.isFlipped ? frame.minY : frame.maxY
        return proposedEffectiveRect.offsetBy(dx: 0, dy: line - drawnRect.minY)
    }
}

/// A split view whose dividers draw nothing: something else draws their line.
private final class QuietSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {}
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
    /// AppKit's inspector width (NSSplitViewItem.h), so the side columns open alike.
    static let sidebarIdeal: CGFloat = 270
    /// About 40 columns of the editor's default font, and a page still legible
    /// fitted to the width. Source and PDF share it, so at their narrowest they
    /// split the room evenly, as they open.
    static let sourceMinimum: CGFloat = 320
    static let pdfMinimum: CGFloat = sourceMinimum
    /// The PDF's share of the room past the side columns, until one is dragged.
    static let pdfShare: CGFloat = 0.5
    /// How near a dragged divider comes to its detent before it stops there:
    /// enough to catch a drag aimed at it, little enough to drag straight past.
    static let detentReach: CGFloat = 8
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
    /// The window's content at its narrowest: the source and the PDF, a divider
    /// between. A narrowing window folds the sidebar first (AppKit's way with
    /// sidebars), so two windows tile side by side on the smallest Mac display.
    static let contentMinimumWidth = sourceMinimum + divider + pdfMinimum
    /// And at its shortest: the columns over the build panel, then the status bar
    /// under its line.
    static let contentMinimumHeight = columnsMinimum + divider + panelMinimum + divider + BarMetrics.secondaryBarHeight
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
