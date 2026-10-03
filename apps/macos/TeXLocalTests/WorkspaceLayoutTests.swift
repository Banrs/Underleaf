import AppKit
import PDFKit
import Testing
@testable import TeXLocal

/// The project window's split as AppKit lays it out: the build panel and the status
/// bar span source and PDF, hidden panes come back at their sizes, and the splits
/// keep their dividers for the next window. On screen, unseen (split animations
/// need an awake, unlocked display). One at a time: they share the app's defaults.
@MainActor
@Suite(.serialized)
final class WorkspaceLayoutTests {
    /// AppKit's autosaved divider positions, by split (`WorkspaceController`).
    private static let splits = ["Workspace", "Sidebar", "Columns", "Area"].map { "NSSplitView Subview Frames \($0)" }
    /// The app's defaults the tests change, put back after each.
    private static let keys = [DefaultsKey.sidebarVisible, DefaultsKey.inspectorVisible,
                               DefaultsKey.showPDF, DefaultsKey.outlineCollapsed] + splits
    /// The app's own new window (`MainWindowController`).
    private static let size = NSSize(width: 1200, height: 760)
    private let saved: [String: Any]
    private var window: NSWindow?
    private var workspace: WorkspaceController?
    private var project: ProjectModel?

    init() {
        saved = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        for key in Self.splits { UserDefaults.standard.removeObject(forKey: key) }
    }

    isolated deinit {
        closeWindow()
        for key in Self.keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func closeWindow() {
        workspace?.close()
        window?.close()
        window?.contentViewController = nil
        project?.close()
    }

    /// A project's workspace as a window's content, laid out, as the window shows it.
    private func open(panel: Bool = false, sidebar: Bool = true, inspector: Bool = false,
                      size: NSSize = WorkspaceLayoutTests.size) -> WorkspaceController {
        let app = AppModel()
        app.sidebarVisible = sidebar
        app.inspectorVisible = inspector
        app.showPDF = true
        let project = ProjectModel(id: "WorkspaceLayoutTests", app: app)
        project.showLogs = panel
        let window = UnclampedWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // Sized as the app sizes it: below the titlebar.
        let workspace = WorkspaceController(app: app, project: project, size: window.contentLayoutRect.size)
        window.contentViewController = workspace
        window.setContentSize(size)
        window.alphaValue = 0
        window.orderFront(nil)
        window.layoutIfNeeded()
        (self.window, self.workspace, self.project) = (window, workspace, project)
        return workspace
    }

    /// A pane as its split lays it out: the split's subview holding the item's view
    /// and bars. The view itself can stay at its width while the pane animates.
    private func pane(_ item: NSSplitViewItem) -> NSView {
        let view = item.viewController.view
        return sequence(first: view, next: \.superview).first { $0.superview is NSSplitView } ?? view
    }
    /// The lists shown in a view, in order.
    private static func lists(_ view: NSView) -> [NSOutlineView] {
        guard !view.isHidden else { return [] }
        return [view as? NSOutlineView].compactMap(\.self) + view.subviews.flatMap(lists)
    }
    /// The workspace's toolbar in its window, its layout not saved over the app's.
    private func showToolbar(_ workspace: WorkspaceController) throws -> NSToolbar {
        let window = try #require(window)
        let toolbar = workspace.toolbar.toolbar
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        return toolbar
    }
    private func width(_ item: NSSplitViewItem) -> CGFloat { pane(item).frame.width }
    private func height(_ item: NSSplitViewItem) -> CGFloat { pane(item).frame.height }

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
    @Test func theHiddenPDFComesBackAtItsWidth() async throws {
        let workspace = open()
        let pdfWidth = width(workspace.pdfItem)
        #expect(pdfWidth > ColumnMetrics.pdfMinimum)
        let state = {
            "collapsed \(workspace.pdfItem.isCollapsed), source \(self.width(workspace.sourceItem)), "
                + "PDF \(self.width(workspace.pdfItem)) (was \(pdfWidth)), columns \(workspace.columns.view.frame.width)"
        }
        workspace.app.showPDF = false
        try await waitUntil {
            workspace.pdfItem.isCollapsed && isClose(self.width(workspace.sourceItem), workspace.columns.view.frame.width)
        } state: { "hiding: " + state() }
        workspace.app.showPDF = true
        try await waitUntil {
            !workspace.pdfItem.isCollapsed && isClose(self.width(workspace.pdfItem), pdfWidth, within: 1)
        } state: { "showing: " + state() }
    }

    /// Hide Build Panel and Show Build Panel bring it back at the height it was dragged to.
    @Test func theHiddenPanelComesBackAtItsHeight() async throws {
        let workspace = open(panel: true)
        try await waitUntil { self.height(workspace.panelItem) > 0 }
        let split = workspace.area.splitView
        split.setPosition(split.bounds.height - split.dividerThickness - 210, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let panelHeight = height(workspace.panelItem)
        workspace.project.showLogs = false
        try await waitUntil { workspace.panelItem.isCollapsed }
        workspace.project.showLogs = true
        try await waitUntil { !workspace.panelItem.isCollapsed && isClose(self.height(workspace.panelItem), panelHeight, within: 1) } state: {
            "panel \(self.height(workspace.panelItem)), was \(panelHeight)"
        }
    }

    /// The next window opens with the dividers where this one left them.
    @Test func theNextWindowKeepsTheDividers() async throws {
        var workspace = open()
        try await waitUntil { self.width(workspace.pdfItem) > 0 }
        workspace.columns.splitView.setPosition(width(workspace.sourceItem) + 100, ofDividerAt: 0)
        workspace.columns.splitView.layoutSubtreeIfNeeded()
        let source = width(workspace.sourceItem)
        // AppKit keeps the dividers once the drag's layout is done.
        try await waitUntil { UserDefaults.standard.object(forKey: Self.splits[2]) != nil }
        closeWindow()

        workspace = open()
        try await waitUntil { isClose(self.width(workspace.sourceItem), source, within: 1) } state: {
            "source \(self.width(workspace.sourceItem)), was \(source)"
        }
    }

    /// A window closed while a pane animates leaves the dividers it had saved: the
    /// animation, ending after the window, doesn't save its frames over them.
    @Test func aWindowClosedMidAnimationKeepsItsDividers() async throws {
        let workspace = open()
        try await waitUntil { UserDefaults.standard.object(forKey: Self.splits[2]) != nil }
        let saved = UserDefaults.standard.array(forKey: Self.splits[2]) as? [String]
        workspace.app.showPDF = false
        try await waitUntil { self.width(workspace.pdfItem) < ColumnMetrics.pdfMinimum }
        closeWindow()
        // Past the end of AppKit's collapse animation.
        try await Task.sleep(for: .milliseconds(500))
        #expect(UserDefaults.standard.array(forKey: Self.splits[2]) as? [String] == saved)
    }

    /// The models, not the last window, say which panes show.
    @Test func theNextWindowShowsWhatTheModelsShow() async throws {
        var workspace = open(panel: true)
        workspace.app.showPDF = false
        try await waitUntil { workspace.pdfItem.isCollapsed }
        closeWindow()

        workspace = open()
        #expect(workspace.panelItem.isCollapsed)
        try await waitUntil { !workspace.pdfItem.isCollapsed && self.width(workspace.pdfItem) >= ColumnMetrics.pdfMinimum } state: {
            "collapsed \(workspace.pdfItem.isCollapsed), PDF \(self.width(workspace.pdfItem))"
        }
    }

    /// The File Outline's header is one list at the foot of the files: over the outline's
    /// pane, or folded with it at the foot of the sidebar; unfolding it there brings the pane back.
    @Test func theFoldedOutlineKeepsItsHeaderAtTheFoot() async throws {
        let workspace = open(), project = workspace.project
        workspace.app.outlineCollapsed = false
        project.tree = [TreeNode(type: "file", name: "main.tex", path: "main.tex", children: nil)]
        project.outline = [OutlineItem(id: 0, level: 1, title: "Introduction", line: 1, file: "main.tex")]
        project.openPath = "main.tex"
        let sidebar = workspace.sidebarItem.viewController.view
        // Shown lists, files first, by their rows; and the foot of the sidebar each pane's list ends at.
        let rows = { Self.lists(sidebar).map(\.numberOfRows) }
        let bottoms = { Self.lists(sidebar).map { list in
            // Not forced: a trap would end the whole run with the app's defaults unrestored.
            let scroll: NSView = list.enclosingScrollView ?? list
            let frame = scroll.convert(scroll.bounds, to: sidebar)
            return sidebar.isFlipped ? sidebar.bounds.height - frame.maxY : frame.minY
        } }
        let state = { "rows \(rows()), above the foot \(bottoms()), outline collapsed \(workspace.outlineItem.isCollapsed)" }
        // Files: its header and main.tex; the File Outline's header; its heading, to the foot.
        try await waitUntil { rows() == [2, 1, 1] && isClose(bottoms()[2], 0) } state: { state() }
        let header = Self.lists(sidebar)[1]

        workspace.app.outlineCollapsed = true
        // The header alone, under the files, in the status bar's height at the foot: the same list.
        try await waitUntil {
            workspace.outlineItem.isCollapsed && rows() == [2, 1] && abs(bottoms()[1]) < StatusBar.height / 2
        } state: { state() }
        #expect(Self.lists(sidebar)[1] === header)
        // Opening the header's section, as its disclosure button does, unfolds the outline.
        header.expandItem(header.item(atRow: 0))
        try await waitUntil {
            !workspace.outlineItem.isCollapsed && rows() == [2, 1, 1] && isClose(bottoms()[2], 0)
        } state: { state() }
        #expect(!workspace.app.outlineCollapsed)
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
        // Files, the File Outline's header, then the outline.
        func rows() -> [Int] { Self.lists(workspace.view).map(\.numberOfRows) }
        // Files: its header, the folder and main.tex; the outline: two headings.
        try await waitUntil { rows() == [3, 1, 2] } state: { "\(rows())" }

        // The folder opens. The headings come after the file, as the core's analysis does.
        project.openPath = "chapters/results.tex"
        try await waitUntil { rows().first == 4 } state: { "\(rows())" }
        project.outline = [OutlineItem(id: 0, level: 1, title: "Results", line: 1, file: "chapters/results.tex"),
                           OutlineItem(id: 1, level: 2, title: "Discussion", line: 9, file: "chapters/results.tex")]
        let outline = try #require(Self.lists(workspace.view).last)
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
        // Below the titlebar: the panes stop at the safe area.
        #expect(isClose(workspace.view.frame.height - workspace.view.safeAreaInsets.top, ColumnMetrics.contentMinimum.height),
                "workspace \(workspace.view.frame), safe area \(workspace.view.safeAreaInsets), minimum \(ColumnMetrics.contentMinimum)")
    }

    /// Compile is off without TeX, in the toolbar and its overflow menu as in the
    /// menu bar, and labelled, it keeps one width for Compile and Stop.
    @Test func compileIsOffWithoutTeX() throws {
        let toolbar = try #require(open().toolbar)
        let item = try #require(toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: .compile, willBeInsertedIntoToolbar: true))
        #expect(item.possibleLabels == [MenuCommand.compileRun.title, MenuCommand.compileStop.title])
        item.validate()
        #expect(!item.isEnabled)
        let overflow = try #require(item.menuFormRepresentation), menu = NSMenu()
        menu.addItem(overflow)
        menu.update()
        #expect(!overflow.isEnabled)
    }

    /// The toolbar's scale follows a fitted PDF as the sidebar resizes it, in the same
    /// layout pass: a pass later, each frame of the sidebar's animation draws twice.
    @Test func theZoomLabelFollowsThePDFInTheSamePass() async throws {
        let workspace = open()
        let window = try #require(window)
        _ = try showToolbar(workspace)
        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        page.string = "Introduction"
        // The pane shows the PDF's view once the project has one.
        workspace.project.pdfURL = FileManager.default.temporaryDirectory.appending(path: "main.pdf")
        workspace.pdf.show(try #require(PDFDocument(data: page.dataWithPDF(inside: page.bounds))))
        let zoom = try #require(window.toolbar?.items.first { $0.itemIdentifier == .zoom }?.view as? NSSegmentedControl)
        // Fitted to the column once it has its width.
        try await waitUntil { workspace.pdf.zoomLabel != "100%" && zoom.label(forSegment: 1) == workspace.pdf.zoomLabel } state: {
            "PDF \(workspace.pdf.zoomLabel), toolbar \(zoom.label(forSegment: 1) ?? "")"
        }
        let label = workspace.pdf.zoomLabel

        workspace.splitView.setPosition(ColumnMetrics.sidebarIdeal + 120, ofDividerAt: 0)
        window.layoutIfNeeded()
        #expect(workspace.pdf.zoomLabel != label)
        #expect(zoom.label(forSegment: 1) == workspace.pdf.zoomLabel)
    }

    /// Format, Math and Insert sit side by side, which shares a capsule, as Notes' tools do; the
    /// PDF and Inspector toggles are a group. Share is in Customize Toolbar only: File › Share has it.
    @Test func theToolbarGroupsItsTools() throws {
        let toolbar = try #require(open().toolbar), bar = toolbar.toolbar
        let shown = toolbar.toolbarDefaultItemIdentifiers(bar)
        let format = try #require(shown.firstIndex(of: .format))
        #expect(Array(shown[format...].prefix(3)) == [.format, .math, .insert])
        #expect(shown.contains(.pdfInspector) && !shown.contains(.share))
        #expect(toolbar.toolbarAllowedItemIdentifiers(bar).contains(.share))
        let group = toolbar.toolbar(bar, itemForItemIdentifier: .pdfInspector, willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup
        #expect(group?.subitems.map(\.itemIdentifier) == [.togglePDF, .inspectorToggle])
    }

    /// The editing tools and the toggles follow the window: Format, Math and Insert are off outside
    /// LaTeX, and so are their menus' items, which the overflow menu opens either way; the toggles'
    /// help says what they'll do, and the Inspector's shows the window's inspector.
    @Test func theGroupedItemsFollowTheWindow() async throws {
        let workspace = open(), project = workspace.project
        let items = try showToolbar(workspace).items.flatMap { [$0] + (($0 as? NSToolbarItemGroup)?.subitems ?? []) }
        let item = { (id: NSToolbarItem.Identifier) in try #require(items.first { $0.itemIdentifier == id }) }
        let editing = try [NSToolbarItem.Identifier.format, .math, .insert].map(item)
        let format = try #require(editing[0].menuFormRepresentation?.submenu)
        let bold = { format.update(); return format.item(withTitle: MenuCommand.editBold.title)?.isEnabled }
        project.openPath = "refs.bib"
        #expect(editing.allSatisfy { !$0.isEnabled })
        try await waitUntil { bold() == false }
        project.openPath = "main.tex"
        #expect(editing.allSatisfy { $0.isEnabled })
        try await waitUntil { bold() == true }

        let pdf = try item(.togglePDF), inspector = try item(.inspectorToggle)
        #expect(pdf.toolTip == "Hide PDF" && inspector.toolTip == "Show Inspector")
        workspace.app.showPDF = false
        #expect(pdf.toolTip == "Show PDF")
        NSApp.sendAction(try #require(inspector.action), to: inspector.target, from: inspector)
        try await waitUntil { workspace.app.inspectorVisible && !workspace.inspectorItem.isCollapsed }
        #expect(inspector.toolTip == "Hide Inspector")
    }

    /// Aa opens its popover under it, on the screen, and again closes it; the menu bar's
    /// Format and the overflow menu keep the same choices as menu items.
    @Test func aaOpensItsPopover() async throws {
        let workspace = open(sidebar: false)
        let window = try #require(window), toolbar = try showToolbar(workspace)
        window.layoutIfNeeded()
        let item = try #require(toolbar.items.first { $0.itemIdentifier == .format })
        #expect(!(item is NSMenuToolbarItem) && item.menuFormRepresentation?.submenu?.items.map(\.title)
            .starts(with: [MenuCommand.editBold.title, MenuCommand.editItalic.title]) == true)
        let popover = workspace.toolbar.format.popover
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        try await waitUntil { popover.isShown && popover.contentViewController?.view.window != nil }
        let shown = try #require(popover.contentViewController?.view.window).frame
        let aa = try #require(Self.views(window.contentView!.superview!).first { $0 is NSButton && $0.accessibilityLabel() == "Format" })
        let anchor = aa.convert(aa.bounds, to: nil).offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        #expect(shown.minX < anchor.midX && anchor.midX < shown.maxX && shown.maxY <= anchor.minY + 1)
        #expect(window.screen.map { $0.visibleFrame.contains(shown) } != false && shown.height < 400)
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        try await waitUntil { !popover.isShown }
    }

    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    /// Off in the toolbar, off in its overflow menu: Share, which the menu asks, and Zoom's
    /// scales, under a submenu that stays available (HIG, Menus).
    @Test func theOverflowMenuFollowsTheItems() async throws {
        let workspace = open(), toolbar = try #require(workspace.toolbar), bar = toolbar.toolbar
        let share = try #require(toolbar.toolbar(bar, itemForItemIdentifier: .share, willBeInsertedIntoToolbar: true))
        let scales = try #require(toolbar.toolbar(bar, itemForItemIdentifier: .zoom, willBeInsertedIntoToolbar: true)?
            .menuFormRepresentation?.submenu)
        let fitWidth = { scales.update(); return scales.item(withTitle: "Fit Width")?.isEnabled }
        // The overflow menu's own item for Share, which AppKit's validation turns on whatever the item's state.
        let overflow = NSMenuItem(title: "Share…", action: Selector(("_simpleOverflowMenuItemClicked:")), keyEquivalent: "")
        // No PDF yet.
        #expect(!share.isEnabled && !share.validateMenuItem(overflow))
        try await waitUntil { fitWidth() == false }
        workspace.project.pdfURL = FileManager.default.temporaryDirectory.appending(path: "main.pdf")
        try await waitUntil { fitWidth() == true }
    }

    /// A narrowing window overflows the least-used items first: Zoom, then Insert, Math and
    /// Format; Back, Compile and the toggles stay down to the window's minimum.
    @Test func theToolbarOverflowsTheLeastUsedFirst() async throws {
        let workspace = open(sidebar: false)
        let window = try #require(window), toolbar = try showToolbar(workspace)
        var left: [NSToolbarItem.Identifier] = []
        for width in stride(from: Self.size.width, through: ColumnMetrics.contentMinimum.width, by: -5) {
            window.setContentSize(NSSize(width: width, height: Self.size.height))
            window.layoutIfNeeded()
            let shown = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
            left += toolbar.items.map(\.itemIdentifier).filter { !shown.contains($0) && !left.contains($0) }
        }
        #expect(left.filter { !$0.rawValue.hasPrefix("NSToolbar") } == [.zoom, .insert, .math, .format])
        #expect(!left.contains(.toggleSidebar))
    }

    /// Zoom out | scale | zoom in, one width from the PDFView's smallest scale to its largest, as
    /// a pop-up keeps its widest item's, and the same before the first PDF.
    @Test func theZoomControlKeepsItsSegmentsAndWidth() async throws {
        let workspace = open(), pdf = workspace.pdf
        let zoom = try #require(showToolbar(workspace).items.first { $0.itemIdentifier == .zoom }?.view as? NSSegmentedControl)
        window?.layoutIfNeeded()
        #expect(zoom.segmentCount == 3 && zoom.image(forSegment: 0) != nil && zoom.image(forSegment: 2) != nil)
        let width = zoom.intrinsicContentSize.width
        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        workspace.project.pdfURL = FileManager.default.temporaryDirectory.appending(path: "main.pdf")
        pdf.show(try #require(PDFDocument(data: page.dataWithPDF(inside: page.bounds))))
        // Fitted to the column once it has its width.
        try await waitUntil { pdf.zoomLabel != "100%" }
        // A document keeps the cap: three digits at most.
        #expect(pdf.widestZoomLabel == "999%")
        for scale in [pdf.view.minScaleFactor, 0.5, 0.95, 1, pdf.view.maxScaleFactor] {
            pdf.setScale(scale)
            try await waitUntil { abs(pdf.scale - scale) < 0.001 && zoom.label(forSegment: 1) == pdf.zoomLabel } state: {
                "\(pdf.scale), toolbar \(zoom.label(forSegment: 1) ?? "")"
            }
            window?.layoutIfNeeded()
            #expect(zoom.intrinsicContentSize.width == width, "\(pdf.zoomLabel)")
        }
        // Zoom In stops there.
        pdf.setScale(9.5)
        try await waitUntil { pdf.zoomLabel == "950%" }
        pdf.zoom(in: true)
        try await waitUntil { pdf.zoomLabel != "950%" }
        #expect(pdf.zoomLabel == "999%")
    }
}

/// A window kept at the size it's given. Ordered front, a titled window shrinks
/// to the screen's visible frame, and a CI runner's screen is smaller than the
/// tests' window: the workspace, made for the size asked, would be squeezed after.
private final class UnclampedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
