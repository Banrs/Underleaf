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
/// Find bars belong to their columns; AppKit animates model-driven collapses.
final class WorkspaceController: DetentSplitViewController {
    let app: AppModel
    let project: ProjectModel
    var pdf: PDFController { project.pdf }
    private(set) var toolbar: WorkspaceToolbar!

    let columns = DetentSplitViewController()
    let area = NSSplitViewController()
    private let sidebar = OutlineSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var outlineItem: NSSplitViewItem!
    private(set) var sourceItem: NSSplitViewItem!
    private(set) var pdfItem: NSSplitViewItem!
    private(set) var panelItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    private var outlineBar: NSSplitViewItemAccessoryViewController!
    private var outlineBarHeight: NSLayoutConstraint!
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
        // Before the area, which opens in the room the side columns leave; added after it.
        buildInspector()
        buildArea(size: size)
        addSplitViewItem(inspectorItem)
        detent = { [unowned self] divider in
            divider == 0 && !sidebarItem.isCollapsed ? ColumnMetrics.sidebarIdeal : nil
        }
        columns.detent = { [unowned columns] _ in
            let split = columns.splitView
            return ((split.bounds.width - split.dividerThickness) / 2).rounded(.down)
        }
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
        // The outline's header, folded or not: its line stands for the divider under it.
        outlineBar = accessory(OutlineHeader(), hidden: !showsOutline, footOf: sidebar.splitView, topAligned: true)
        outlineBarHeight = outlineBar.view.heightAnchor.constraint(equalToConstant:
            (app.outlineCollapsed ? BarMetrics.secondaryBarHeight : OutlineHeader.expandedHeight) + sidebar.splitView.dividerThickness)
        outlineBarHeight.isActive = true
        filesItem.addBottomAlignedAccessoryViewController(outlineBar)
        sidebar.header = outlineBar

        let outline = host(OutlineList(project: project),
                           height: PaneSize.outline.value ?? (height * ColumnMetrics.outlineShare).rounded())
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
        sidebarSearch = accessory(SearchField(text: Bindable(project).searchQuery, prompt: "Search Project", handle: searchField)
            .padding([.horizontal, .bottom], BarMetrics.inset))
        sidebarItem.addTopAlignedAccessoryViewController(sidebarSearch)
        addSplitViewItem(sidebarItem)
    }

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
        pdfItem.isCollapsed = !project.showPDF
        pdfFind = accessory(PDFFindBar(controller: pdf), hidden: true)
        pdfItem.addTopAlignedAccessoryViewController(pdfFind)

        columns.addSplitViewItem(sourceItem)
        columns.addSplitViewItem(pdfItem)
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
        panelItem.isCollapsed = !project.showLogs

        area.splitView.isVertical = false
        let columnsItem = NSSplitViewItem(viewController: columns)
        // The panel dragged up stops short of the find bar and a few lines.
        columnsItem.minimumThickness = ColumnMetrics.columnsMinimum
        area.addSplitViewItem(columnsItem)
        area.addSplitViewItem(panelItem)

        let areaItem = NSSplitViewItem(viewController: area)
        let statusBar = accessory(StatusBar(project: project), footOf: area.splitView, clearsCorners: true)
        statusBar.preferredScrollEdgeEffectStyle = .automatic
        areaItem.addBottomAlignedAccessoryViewController(statusBar)
        addSplitViewItem(areaItem)
    }

    /// Preserve the PDF's share, enforcing its minimum even if the source starts
    /// too narrow; the side columns then make room for both.
    private func keptPDFWidth(in panes: CGFloat) -> CGFloat {
        let share = (panes * (PaneSize.pdfShare.value ?? ColumnMetrics.pdfShare)).rounded()
        return max(min(max(share, ColumnMetrics.pdfMinimum), panes - ColumnMetrics.sourceMinimum), ColumnMetrics.pdfMinimum)
    }

    /// AppKit's fixed inspector width fits its settings and facts.
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

    /// A pane bar sized to its content. A foot bar draws `split`'s divider above
    /// its content; `clearsCorners` protects the window's rounded status-bar corners.
    private func accessory(_ content: some View, hidden: Bool = false, footOf split: NSSplitView? = nil,
                           clearsCorners: Bool = false, topAligned: Bool = false) -> NSSplitViewItemAccessoryViewController {
        let accessory = NSSplitViewItemAccessoryViewController()
        let host = NSHostingView(rootView: content.environment(app))
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // AppKit draws the scroll edge behind this plain container. A separate
        // visual-effect background would cover the system's content sampling.
        let bar = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(host)
        let leading = host.leadingAnchor.constraint(equalTo: bar.leadingAnchor)
        let trailing = bar.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        if clearsCorners {
            // The content's own 8 pt inset completes Xcode's 16 pt corner clearance.
            let corners = bar.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
            leading.priority = .defaultHigh
            trailing.priority = .defaultHigh
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(greaterThanOrEqualTo: corners.leadingAnchor, constant: -BarMetrics.inset),
                corners.trailingAnchor.constraint(greaterThanOrEqualTo: host.trailingAnchor, constant: -BarMetrics.inset),
            ])
        }
        var top = bar.topAnchor
        if let split {
            let hairline = Hairline(split: split)
            hairline.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(hairline)
            NSLayoutConstraint.activate([
                hairline.topAnchor.constraint(equalTo: bar.topAnchor),
                hairline.heightAnchor.constraint(equalToConstant: split.dividerThickness),
                hairline.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            ])
            top = hairline.bottomAnchor
        }
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: top),
            topAligned ? host.bottomAnchor.constraint(lessThanOrEqualTo: bar.bottomAnchor)
                       : host.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            leading, trailing,
        ])
        accessory.view = bar
        // The bars inset their controls by the UI kit's 8 pt themselves.
        accessory.automaticallyAppliesContentInsets = false
        accessory.isHidden = hidden
        accessory.view.isHidden = hidden
        return accessory
    }

    private var showsOutline: Bool { !project.isSearching && project.isLaTeX }

    private func updateOutline() {
        setCollapsed(outlineItem, !showsOutline || app.outlineCollapsed)
        setHidden(outlineBar, !showsOutline)
    }

    // ---------- the models drive the panes ----------

    private func watch() {
        let app = app, project = project, pdf = pdf
        watches = [
            track({ app.sidebarVisible }) { [weak self] visible in if let self { setCollapsed(sidebarItem, !visible) } },
            track({ app.inspectorVisible }) { [weak self] visible in if let self { setCollapsed(inspectorItem, !visible) } },
            track({ project.showPDF }) { [weak self] in self?.setPDFShown($0) },
            track({ project.showLogs }) { [weak self] in self?.setPanelShown($0) },
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
                if message.userResize { self?.saveSizes(in: split) }
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
        let headerHeight = item === outlineItem
            ? (collapsed ? BarMetrics.secondaryBarHeight : OutlineHeader.expandedHeight) + sidebar.splitView.dividerThickness : nil
        // Repeated model notifications must not snap an animation already heading here.
        guard item.isCollapsed != collapsed else { return done?() ?? () }
        // AppKit's split animation marks descendants as live-resizing, revealing
        // their scrollers. A build-panel toggle changes layout without that cue.
        guard animates, item !== panelItem else {
            if let headerHeight { outlineBarHeight.constant = headerHeight }
            item.isCollapsed = collapsed
            view.layoutSubtreeIfNeeded()
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            // One AppKit animation owns the split and the header's lower padding.
            if let headerHeight {
                context.allowsImplicitAnimation = true
                outlineBarHeight.animator().constant = headerHeight
            }
            item.animator().isCollapsed = collapsed
            if headerHeight != nil { sidebar.view.layoutSubtreeIfNeeded() }
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

    /// Restore the panel through its divider after unfolding it. Setting the
    /// hosted view's frame is ambiguous when AppKit adds the accessory insets.
    private func setPanelShown(_ shown: Bool) {
        guard shown == panelItem.isCollapsed else { return }
        guard shown else { return setCollapsed(panelItem, true) }
        let split = area.splitView
        let height = PaneSize.panel.value ?? (split.bounds.height * ColumnMetrics.panelShare).rounded()
        setCollapsed(panelItem, false)
        split.setPosition(split.bounds.height - split.dividerThickness - height, ofDividerAt: 0)
    }

    private var animates: Bool {
        view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Layout makes a newly shown accessory's field ready to take the keyboard.
    private func focusField(_ field: FieldHandle, in accessory: NSSplitViewItemAccessoryViewController) {
        if field.field == nil { accessory.view.layoutSubtreeIfNeeded() }
        field.focus()
    }

    private func focusSearch() {
        let wasCollapsed = sidebarItem.isCollapsed
        setCollapsed(sidebarItem, false) { [weak self] in
            guard let self, wasCollapsed else { return }
            focusField(searchField, in: sidebarSearch)
        }
        // At once too, so typing during the animation lands in the field.
        focusField(searchField, in: sidebarSearch)
    }

    func hostsFindField(_ field: NSTextField) -> Bool {
        field.isDescendant(of: sourceFind.view) || field.isDescendant(of: pdfFind.view)
    }

    // ---------- sizes ----------

    /// Keeps the shown panes' sizes, for this launch's collapses and the next launch:
    /// the sizes they're dragged to, not those a narrowing window squeezes them to.
    private func saveSizes(in split: NSSplitView) {
        let sidebarWidth = sidebarItem.viewController.view.frame.width
        if split === splitView, !sidebarItem.isCollapsed, sidebarWidth >= sidebarItem.minimumThickness {
            PaneSize.sidebar.store(sidebarWidth)
        }
        if split === sidebar.splitView, !outlineItem.isCollapsed { PaneSize.outline.store(outlineItem.viewController.view.frame.height) }
        if split === area.splitView, !panelItem.isCollapsed { PaneSize.panel.store(panelItem.viewController.view.frame.height) }
        if split === columns.splitView, !pdfItem.isCollapsed {
            let source = sourceItem.viewController.view.frame.width, pdf = pdfItem.viewController.view.frame.width
            if source + pdf > 0 { PaneSize.pdfShare.store(pdf / (source + pdf)) }
        }
    }

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
        setPDFShown(true) { [weak self] in
            guard let self, project.pdfVersion > 0 else { return }
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
        case .inverseFromView:
            if case let (page, point)? = pdf.sourcePoint() {
                Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
            }
        }
    }
}

/// AppKit has no split detents; this controller stops nearby drags at the
/// opening size and plays an alignment haptic on arrival.
class DetentSplitViewController: NSSplitViewController {
    var detent: (_ divider: Int) -> CGFloat? = { _ in nil }

    /// NSSplitViewController doesn't implement this, so there's no super to call.
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
    weak var header: NSSplitViewItemAccessoryViewController?

    init() {
        super.init(nibName: nil, bundle: nil)
        splitView = QuietSplitView()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard let header, !header.isHidden, splitViewItems.last?.isCollapsed == false else { return .zero }
        let frame = header.view.convert(header.view.bounds, to: splitView)
        let line = splitView.isFlipped ? frame.minY : frame.maxY
        return proposedEffectiveRect.offsetBy(dx: 0, dy: line - drawnRect.minY)
    }
}

private final class QuietSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {}
}

/// A bar's hairline uses its split view's divider colour.
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
    /// Catches a drag aimed at the detent without trapping one passing through.
    static let detentReach: CGFloat = 8
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
                                       height: columnsMinimum + divider + BuildPanelHeader.height + panelMinimum + divider + BarMetrics.secondaryBarHeight)
}

/// Pane sizes kept across launches in one defaults dictionary.
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
