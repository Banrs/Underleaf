import AppKit
import PDFKit
import Testing
@testable import TeXLocal

/// The project window's split as AppKit lays it out: the build panel and the status
/// bar span source and PDF, a hidden PDF comes back at its width, and panes open at
/// the sizes kept for them. On screen, unseen (split animations need an awake,
/// unlocked display). One at a time: they share the app's defaults.
@MainActor
@Suite(.serialized)
final class WorkspaceLayoutTests {
    /// The app's defaults the tests change, put back after each.
    private static let keys = [DefaultsKey.paneSizes, DefaultsKey.sidebarVisible, DefaultsKey.inspectorVisible,
                               DefaultsKey.showPDF, DefaultsKey.outlineCollapsed, DefaultsKey.outlineFolded]
    private static let size = NSSize(width: 1200, height: 600)
    private let saved: [String: Any]
    private var window: NSWindow?
    private var workspace: WorkspaceController?
    private var project: ProjectModel?

    init() {
        saved = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        UserDefaults.standard.removeObject(forKey: DefaultsKey.paneSizes)
    }

    isolated deinit {
        workspace?.close()
        window?.close()
        window?.contentViewController = nil
        project?.close()
        for key in Self.keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// A project's workspace as a window's content, laid out, as the window shows it.
    private func open(panel: Bool = false, sidebar: Bool = true, inspector: Bool = false,
                      size: NSSize = WorkspaceLayoutTests.size) -> WorkspaceController {
        let app = AppModel()
        app.sidebarVisible = sidebar
        app.inspectorVisible = inspector
        let project = ProjectModel(id: "WorkspaceLayoutTests", app: app)
        project.showPDF = true
        project.showLogs = panel
        let workspace = WorkspaceController(app: app, project: project, size: size)
        let window = UnclampedWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.contentMinSize = ColumnMetrics.contentMinimum
        window.setContentSize(size)
        window.alphaValue = 0
        window.orderFront(nil)
        window.layoutIfNeeded()
        (self.window, self.workspace, self.project) = (window, workspace, project)
        return workspace
    }

    private func width(_ item: NSSplitViewItem) -> CGFloat { item.viewController.view.frame.width }
    private func height(_ item: NSSplitViewItem) -> CGFloat { item.viewController.view.frame.height }
    private func lists(_ view: NSView) -> [NSOutlineView] {
        [view as? NSOutlineView].compactMap(\.self) + view.subviews.flatMap(lists)
    }

    @Test func thePanelSpansSourceAndPDF() async throws {
        let workspace = open(panel: true)
        try await waitUntil { self.height(workspace.panelItem) > 0 }
        let columns = width(workspace.sourceItem) + workspace.columns.splitView.dividerThickness + width(workspace.pdfItem)
        #expect(isClose(width(workspace.panelItem), columns))
        #expect(isClose(width(workspace.panelItem), workspace.area.view.frame.width))
    }

    /// Both side columns open at their own widths; the source and PDF take the rest.
    @Test func theSideColumnsOpenAtTheirWidths() async throws {
        let workspace = open(inspector: true)
        try await waitUntil { self.width(workspace.inspectorItem) > 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(isClose(width(workspace.sidebarItem), ColumnMetrics.sidebarIdeal))
        #expect(isClose(width(workspace.inspectorItem), workspace.inspectorItem.minimumThickness))
    }

    /// Hide PDF gives the source the room; Show PDF brings the PDF back at its width.
    @Test(arguments: [1200.0, 1400.0]) func theHiddenPDFComesBackAtItsWidth(windowWidth: CGFloat) async throws {
        let workspace = open()
        let pdfWidth = width(workspace.pdfItem)
        let share = pdfWidth / (workspace.columns.view.frame.width - workspace.columns.splitView.dividerThickness)
        #expect(pdfWidth > ColumnMetrics.pdfMinimum)
        let state = {
            "collapsed \(workspace.pdfItem.isCollapsed), source \(self.width(workspace.sourceItem)), "
                + "PDF \(self.width(workspace.pdfItem)) (was \(pdfWidth)), columns \(workspace.columns.view.frame.width)"
        }
        workspace.project.showPDF = false
        try await waitUntil {
            workspace.pdfItem.isCollapsed && isClose(self.width(workspace.sourceItem), workspace.columns.view.frame.width)
        } state: { "hiding: " + state() }
        window?.setContentSize(NSSize(width: windowWidth, height: Self.size.height))
        window?.layoutIfNeeded()
        let expectedWidth = ((workspace.columns.view.frame.width - workspace.columns.splitView.dividerThickness) * share).rounded()
        workspace.project.showPDF = true
        try await waitUntil {
            !workspace.pdfItem.isCollapsed && isClose(self.width(workspace.pdfItem), expectedWidth, within: 1)
        } state: { "showing: " + state() }
    }

    /// The PDF toggle keeps its label, as the system's toggles beside it do; its
    /// tooltip says what it will do.
    @Test func thePDFToggleKeepsItsLabel() throws {
        let workspace = open()
        let bar = workspace.toolbar!
        for shown in [true, false] {
            workspace.project.showPDF = shown
            let item = try #require(bar.toolbar(bar.toolbar, itemForItemIdentifier: .togglePDF, willBeInsertedIntoToolbar: true))
            #expect(item.label == "PDF")
            #expect(item.toolTip == workspace.app.title(.viewTogglePdf, on: workspace.project))
        }
    }

    /// Zoom's and Math's menu segments open on a click: AppKit does that only in a
    /// control without an action, so the others send theirs as control events.
    @Test func theSegmentMenusOpenOnAClick() throws {
        let bar = open().toolbar!
        for id in [NSToolbarItem.Identifier.zoom, .math] {
            let item = try #require(bar.toolbar(bar.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true))
            let control = try #require(item.view as? NSSegmentedControl)
            #expect(control.action == nil)
            #expect(control.menu(forSegment: 1) != nil)
        }
    }

    /// The displayed toolbar label follows native magnification synchronously,
    /// without waiting for another layout or the model's observation task.
    @Test func theToolbarShowsNativeMagnificationImmediately() async throws {
        let workspace = open(), window = try #require(window)
        window.toolbar = workspace.toolbar.toolbar
        workspace.project.pdfURL = URL(filePath: "/dev/null")
        workspace.project.pdfVersion = 1
        try await waitUntil { workspace.pdf.view?.window === window }
        let view = try #require(workspace.pdf.view)
        let label = NSTextField(labelWithString: "Native Zoom")
        let document = try #require(PDFDocument(data: label.dataWithPDF(inside: NSRect(x: 0, y: 0, width: 612, height: 792))))
        workspace.pdf.setDocument(document)
        workspace.pdf.setScale(1)
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier == .zoom })
        let control = try #require(item.view as? NSSegmentedControl)
        let scroll = try #require(view.documentView?.enclosingScrollView)
        for scale: CGFloat in [1.25, 0.75] {
            let before = control.label(forSegment: 1)
            scroll.magnification = scale
            #expect(workspace.pdf.scale == view.scaleFactor)
            #expect(control.label(forSegment: 1) == Double(view.scaleFactor).formatted(.percent.precision(.fractionLength(0))))
            #expect(control.label(forSegment: 1) != before)
        }
    }

    /// The build panel opens at the height kept for it, not at its minimum.
    @Test func thePanelOpensAtItsKeptHeight() async throws {
        PaneSize.panel.store(210)
        let workspace = open()
        #expect(workspace.panelItem.isCollapsed)
        workspace.project.showLogs = true
        try await waitUntil { isClose(self.height(workspace.panelItem), 210, within: 1) }
    }

    /// A divider dragged is kept; an unrelated pane squeezed by window resizing isn't.
    @Test func aDraggedDividerIsKept() async throws {
        PaneSize.panel.store(250)
        let workspace = open()
        workspace.project.showLogs = true
        try await waitUntil { !workspace.panelItem.isCollapsed && isClose(self.height(workspace.panelItem), 250, within: 1) }
        window?.setContentSize(NSSize(width: Self.size.width, height: 400))
        window?.layoutIfNeeded()
        try await waitUntil { self.height(workspace.panelItem) < 240 }
        try await waitUntil { self.width(workspace.pdfItem) > 0 }
        let split = workspace.columns.splitView, window = try #require(window)
        let start = split.convert(NSPoint(x: width(workspace.sourceItem) + 0.5, y: split.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + dx, y: start.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for dx in stride(from: 10.0, through: 100, by: 10) { NSApp.postEvent(event(.leftMouseDragged, dx), atStart: false) }
        NSApp.postEvent(event(.leftMouseUp, 100), atStart: false)
        split.mouseDown(with: event(.leftMouseDown, 0))
        let share = width(workspace.pdfItem) / (width(workspace.sourceItem) + width(workspace.pdfItem))
        #expect(share < 0.45)
        #expect(isClose(PaneSize.pdfShare.value ?? 0, share, within: 0.01))
        #expect(workspace.panelItem.minimumThickness == ColumnMetrics.panelMinimum)
        workspace.close()
        #expect(PaneSize.panel.value == 250)
    }

    /// Window hit testing reaches the native split at its actual divider, rather
    /// than an overlapping hosted source or PDF view. This does not test cursors.
    @Test func theWindowRoutesTheSourcePDFDividerToAppKit() async throws {
        let workspace = open(panel: true), window = try #require(window)
        workspace.project.openPath = "main.tex"
        try await waitUntil { self.width(workspace.pdfItem) > 0 }
        for size in [Self.size, NSSize(width: 1000, height: 500)] {
            window.setContentSize(size)
            window.layoutIfNeeded()
            let split = workspace.columns.splitView
            let source = workspace.sourceItem.viewController.view.convert(workspace.sourceItem.viewController.view.bounds, to: split)
            let pdf = workspace.pdfItem.viewController.view.convert(workspace.pdfItem.viewController.view.bounds, to: split)
            #expect(isClose(pdf.minX - source.maxX, split.dividerThickness))
            let content = try #require(window.contentView)
            let root = content.superview ?? content
            for fraction in [0.25, 0.5, 0.75] {
                let center = NSPoint(x: (source.maxX + pdf.minX) / 2,
                                     y: split.bounds.minY + split.bounds.height * fraction)
                let point = split.convert(center, to: root.superview)
                #expect(root.hitTest(point) === split)
            }
        }
    }

    /// The list collapses natively while the same header stays in the window,
    /// with the same native row spacing in both states.
    @Test func theOutlineFoldsWithAPersistentNativeHeader() async throws {
        PaneSize.outline.store(200)
        let workspace = open()
        workspace.project.openPath = "main.tex"
        workspace.app.outlineCollapsed = false
        try await waitUntil {
            !workspace.outlineItem.isCollapsed && isClose(self.height(workspace.outlineItem), 200, within: 1)
                && workspace.outlineItem.minimumThickness == ColumnMetrics.outlineMinimum
        } state: {
            "first reveal: collapsed \(workspace.outlineItem.isCollapsed), height \(self.height(workspace.outlineItem)), min \(workspace.outlineItem.minimumThickness)"
        }
        let expanded = height(workspace.outlineItem)
        let sidebar = try #require(workspace.outlineItem.viewController.parent as? NSSplitViewController)
        let split = sidebar.splitView
        let files = try #require(sidebar.splitViewItems.first)
        let header = try #require(files.bottomAlignedAccessoryViewControllers.first)
        try await waitUntil { self.lists(header.view).first?.numberOfRows == 1 } state: {
            "header rows: \(self.lists(header.view).map(\.numberOfRows))"
        }
        let list = try #require(lists(header.view).first)
        func rowRect() -> NSRect { list.convert(list.rect(ofRow: 0), to: header.view) }
        func rowTop() -> CGFloat {
            let row = rowRect()
            return header.view.isFlipped ? row.minY - header.view.bounds.minY : header.view.bounds.maxY - row.maxY
        }
        let spacing = rowTop(), headerHeight = header.view.frame.height
        #expect(split.dividerThickness > 0)
        #expect(spacing > 0)
        #expect(isClose(rowRect().midY, header.view.bounds.midY))
        let boundary = header.view.convert(header.view.bounds, to: split)
        let content = try #require(window?.contentView)
        let root = content.superview ?? content
        let dividerPoint = split.convert(NSPoint(x: boundary.midX, y: boundary.minY), to: root.superview)
        #expect(root.hitTest(dividerPoint) === split)
        workspace.app.outlineCollapsed = true
        try await waitUntil { workspace.outlineItem.isCollapsed && split.isSubviewCollapsed(split.arrangedSubviews[1]) } state: {
            "outline collapsed \(workspace.outlineItem.isCollapsed), pane \(split.arrangedSubviews[1].frame)"
        }
        #expect(workspace.outlineItem.isCollapsed)
        #expect(!header.isHidden && !header.view.isHidden)
        #expect(header.view.window === window)
        #expect(lists(header.view).first === list)
        #expect(isClose(header.view.frame.height, headerHeight))
        #expect(isClose(rowTop(), spacing))
        #expect(isClose(rowRect().midY, header.view.bounds.midY))
        let status = try #require(workspace.splitViewItems[1].bottomAlignedAccessoryViewControllers.first)
        #expect(isClose(status.view.frame.height, headerHeight))
        #expect(isClose(status.view.convert(status.view.bounds, to: nil).minY,
                        header.view.convert(header.view.bounds, to: nil).minY))
        workspace.app.outlineCollapsed = false
        try await waitUntil {
            !workspace.outlineItem.isCollapsed && isClose(self.height(workspace.outlineItem), expanded, within: 1)
                && workspace.outlineItem.minimumThickness == ColumnMetrics.outlineMinimum
        } state: {
            "reveal: outline \(self.height(workspace.outlineItem)), expected \(expanded), min \(workspace.outlineItem.minimumThickness)"
        }
        #expect(lists(header.view).first === list)
        #expect(isClose(rowTop(), spacing))
        #expect(isClose(rowRect().midY, header.view.bounds.midY))

        workspace.app.outlineCollapsed = true
        try await waitUntil { workspace.outlineItem.isCollapsed && split.isSubviewCollapsed(split.arrangedSubviews[1]) } state: {
            "second fold: collapsed \(workspace.outlineItem.isCollapsed), pane \(split.arrangedSubviews[1].frame)"
        }
        // Enough for both native minima and their accessory insets, but not the
        // remembered outline height. A smaller window must grow to fit its panes.
        let shortHeight = split.arrangedSubviews[0].fittingSize.height + ColumnMetrics.outlineMinimum
            + split.dividerThickness + 20
        window?.setContentSize(NSSize(width: Self.size.width, height: shortHeight))
        window?.layoutIfNeeded()
        let sidebarHeight = split.bounds.height
        workspace.app.outlineCollapsed = false
        try await waitUntil {
            let panes = split.arrangedSubviews
            return !workspace.outlineItem.isCollapsed && !split.isSubviewCollapsed(panes[1])
                && panes[1].frame.height >= ColumnMetrics.outlineMinimum
                && isClose(panes[1].frame.height, self.height(workspace.outlineItem))
                && isClose(panes[0].frame.height + split.dividerThickness + panes[1].frame.height, split.bounds.height)
                && workspace.outlineItem.minimumThickness == ColumnMetrics.outlineMinimum
                && workspace.outlineItem.maximumThickness == NSSplitViewItem.unspecifiedDimension
        } state: {
            "short reveal: collapsed \(workspace.outlineItem.isCollapsed), panes \(split.arrangedSubviews.map(\.frame)), min \(workspace.outlineItem.minimumThickness), split \(split.bounds.height)"
        }
        #expect(isClose(split.bounds.height, sidebarHeight), "split \(split.bounds.height), before \(sidebarHeight), files \(files.viewController.view.frame.height), outline \(self.height(workspace.outlineItem))")
        #expect(files.viewController.view.frame.height >= files.minimumThickness)
    }

    /// The sidebar shows the open file: its folders open, and a heading that gains
    /// subheadings opens as its fold says, not as the leaf it was.
    @Test func theSidebarShowsTheOpenFile() async throws {
        let workspace = open(), project = workspace.project
        workspace.app.outlineCollapsed = false
        let file = { (path: String) in TreeNode(type: "file", name: (path as NSString).lastPathComponent, path: path, children: nil) }
        project.tree = [TreeNode(type: "dir", name: "chapters", path: "chapters", children: [file("chapters/results.tex")]),
                        file("main.tex")]
        project.outline = [OutlineItem(id: 0, level: 1, title: "Introduction", line: 1, file: "main.tex"),
                           OutlineItem(id: 1, level: 1, title: "Methods", line: 9, file: "main.tex")]
        project.openPath = "main.tex"
        // Files, the File Outline's header, the File Outline.
        func rows() -> [Int] { lists(workspace.view).map(\.numberOfRows) }
        // Files: its header, the folder and main.tex.
        try await waitUntil { rows() == [3, 1, 2] } state: { "\(rows())" }

        // The folder opens. The headings come after the file, as the core's analysis does.
        project.openPath = "chapters/results.tex"
        try await waitUntil { rows().first == 4 } state: { "\(rows())" }
        project.outline = [OutlineItem(id: 0, level: 1, title: "Results", line: 1, file: "chapters/results.tex"),
                           OutlineItem(id: 1, level: 2, title: "Discussion", line: 9, file: "chapters/results.tex")]
        let outline = try #require(lists(workspace.view).last)
        try await waitUntil { outline.isExpandable(outline.item(atRow: 0)) }
        #expect(outline.isItemExpanded(outline.item(atRow: 0)))
    }

    /// No pane's content raises the window's minimum: it goes down to the app's own,
    /// the sidebar folded (a user's narrowing folds it; setting the size doesn't).
    @Test func theWindowReachesItsMinimum() {
        let workspace = open(panel: true, sidebar: false)
        window?.setContentSize(ColumnMetrics.contentMinimum)
        window?.layoutIfNeeded()
        #expect(isClose(workspace.view.frame.width, ColumnMetrics.contentMinimum.width))
        let columns = workspace.columns.view, panel = workspace.panelItem.viewController.view
        #expect(isClose(columns.frame.height - columns.safeAreaInsets.top - columns.safeAreaInsets.bottom, ColumnMetrics.columnsMinimum))
        #expect(isClose(panel.frame.height - panel.safeAreaInsets.top - panel.safeAreaInsets.bottom, ColumnMetrics.panelMinimum))
    }
}

/// A window kept at the size it's given. Ordered front, a titled window shrinks
/// to the screen's visible frame, and a CI runner's screen is smaller than the
/// tests' window: the workspace, made for the size asked, would be squeezed after.
private final class UnclampedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
