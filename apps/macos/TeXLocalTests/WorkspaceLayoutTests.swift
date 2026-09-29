import AppKit
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
                               DefaultsKey.showPDF, DefaultsKey.outlineCollapsed]
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
    private func open(panel: Bool = false, sidebar: Bool = true, inspector: Bool = false) -> WorkspaceController {
        let app = AppModel()
        app.sidebarVisible = sidebar
        app.inspectorVisible = inspector
        let project = ProjectModel(id: "WorkspaceLayoutTests", app: app)
        project.showPDF = true
        project.showLogs = panel
        let workspace = WorkspaceController(app: app, project: project, size: Self.size)
        let window = UnclampedWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                     styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.setContentSize(Self.size)
        window.alphaValue = 0
        window.orderFront(nil)
        window.layoutIfNeeded()
        (self.window, self.workspace, self.project) = (window, workspace, project)
        return workspace
    }

    private func width(_ item: NSSplitViewItem) -> CGFloat { item.viewController.view.frame.width }
    private func height(_ item: NSSplitViewItem) -> CGFloat { item.viewController.view.frame.height }

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
        workspace.project.showPDF = false
        try await waitUntil {
            workspace.pdfItem.isCollapsed && isClose(self.width(workspace.sourceItem), workspace.columns.view.frame.width)
        } state: { "hiding: " + state() }
        workspace.project.showPDF = true
        try await waitUntil {
            !workspace.pdfItem.isCollapsed && isClose(self.width(workspace.pdfItem), pdfWidth, within: 1)
        } state: { "showing: " + state() }
    }

    /// The build panel opens at the height kept for it, not at its minimum.
    @Test func thePanelOpensAtItsKeptHeight() async throws {
        PaneSize.panel.store(210)
        let workspace = open()
        #expect(workspace.panelItem.isCollapsed)
        workspace.project.showLogs = true
        try await waitUntil { isClose(self.height(workspace.panelItem), 210, within: 1) }
    }

    /// A divider dragged is kept for the next launch.
    @Test func aDraggedDividerIsKept() async throws {
        let workspace = open()
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
    }

    /// A window resized in code squeezes a pane, and closing it then keeps the
    /// size the pane was dragged to, not the squeeze.
    @Test func aSqueezedPaneKeepsItsSize() async throws {
        PaneSize.panel.store(250)
        let workspace = open()
        workspace.project.showLogs = true
        // Its minimum is its height until it's back.
        try await waitUntil { workspace.panelItem.minimumThickness == ColumnMetrics.panelMinimum }
        #expect(isClose(height(workspace.panelItem), 250, within: 1))
        window?.setContentSize(NSSize(width: Self.size.width, height: 400))
        try await waitUntil { self.height(workspace.panelItem) < 240 }
        workspace.close()
        #expect(PaneSize.panel.value == 250)
    }

    /// A divider dragged near its detent stops there: the sidebar at its opening
    /// width, source and PDF at half each. Farther off, it goes where it's dragged.
    @Test func dividersStopAtTheirDetents() async throws {
        let workspace = open()
        try await waitUntil { self.width(workspace.pdfItem) > 0 }
        for (offset, expected) in [(5.0, ColumnMetrics.sidebarIdeal), (-7, ColumnMetrics.sidebarIdeal),
                                   (30, ColumnMetrics.sidebarIdeal + 30)] {
            workspace.splitView.setPosition(ColumnMetrics.sidebarIdeal + offset, ofDividerAt: 0)
            workspace.view.layoutSubtreeIfNeeded()
            #expect(isClose(width(workspace.sidebarItem), expected), "\(offset)")
        }
        let split = workspace.columns.splitView
        let half = (split.bounds.width - split.dividerThickness) / 2
        split.setPosition(half + 6, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        #expect(abs(width(workspace.sourceItem) - width(workspace.pdfItem)) <= 1)
        split.setPosition(half + 40, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        #expect(isClose(width(workspace.sourceItem) - width(workspace.pdfItem), 80, within: 1.5))
    }

    /// The File Outline's header stays at the files' foot, folded or not. Open, the
    /// line over it takes the divider's drags; folded, nothing does.
    @Test func theOutlineHeadersLineTakesTheDividersDrags() async throws {
        let workspace = open()
        let sidebar = try #require(workspace.sidebarItem.viewController as? NSSplitViewController)
        let split = sidebar.splitView, delegate = try #require(split.delegate)
        let header = try #require(sidebar.splitViewItems.first?.bottomAlignedAccessoryViewControllers.first)
        let outline = try #require(sidebar.splitViewItems.last)
        workspace.project.openPath = "main.tex"
        workspace.app.outlineCollapsed = false
        try await waitUntil { !outline.isCollapsed && !header.isHidden }
        split.layoutSubtreeIfNeeded()

        let frame = header.view.convert(header.view.bounds, to: split)
        let line = split.isFlipped ? frame.minY : frame.maxY
        let divider = NSRect(x: 0, y: frame.maxY, width: split.bounds.width, height: split.dividerThickness)
        let drag = try #require(delegate.splitView?(split, effectiveRect: divider.insetBy(dx: 0, dy: -2),
                                                    forDrawnRect: divider, ofDividerAt: 0))
        #expect(isClose(drag.midY, line, within: 1), "\(drag) for the line at \(line)")
        #expect(drag.height > 0 && isClose(drag.width, frame.width))

        workspace.app.outlineCollapsed = true
        try await waitUntil { outline.isCollapsed }
        #expect(!header.isHidden)
        #expect(delegate.splitView?(split, effectiveRect: divider, forDrawnRect: divider, ofDividerAt: 0) == .zero)
    }

    /// No pane's content raises the window's minimum: it goes down to the app's own,
    /// the sidebar folded (a user's narrowing folds it; setting the size doesn't).
    @Test func theWindowReachesItsMinimum() {
        let workspace = open(panel: true, sidebar: false)
        window?.setContentSize(ColumnMetrics.contentMinimum)
        window?.layoutIfNeeded()
        #expect(isClose(workspace.view.frame.width, ColumnMetrics.contentMinimum.width))
        // Below the titlebar: the panes stop at the safe area.
        #expect(isClose(workspace.view.frame.height - workspace.view.safeAreaInsets.top, ColumnMetrics.contentMinimum.height))
    }
}

/// A window kept at the size it's given. Ordered front, a titled window shrinks
/// to the screen's visible frame, and a CI runner's screen is smaller than the
/// tests' window: the workspace, made for the size asked, would be squeezed after.
private final class UnclampedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
