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
    /// No taller than 600 pt: a CI runner's screen holds a taller titled window short.
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
    private func open(_ size: NSSize = WorkspaceLayoutTests.size, panel: Bool = false, pdf: Bool = true,
                      sidebar: Bool = true, inspector: Bool = false) -> WorkspaceController {
        let app = AppModel()
        app.sidebarVisible = sidebar
        app.inspectorVisible = inspector
        let project = ProjectModel(id: "WorkspaceLayoutTests", app: app)
        project.showPDF = pdf
        project.showLogs = panel
        let workspace = WorkspaceController(app: app, project: project, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.setContentSize(size)
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
        workspace.project.showPDF = false
        try await waitUntil {
            workspace.pdfItem.isCollapsed && isClose(self.width(workspace.sourceItem), workspace.columns.view.frame.width)
        }
        workspace.project.showPDF = true
        try await waitUntil { !workspace.pdfItem.isCollapsed && isClose(self.width(workspace.pdfItem), pdfWidth, within: 1) }
    }

    /// The build panel opens at the height kept for it, not at its minimum.
    @Test func thePanelOpensAtItsKeptHeight() async throws {
        PaneSize.panel.store(210)
        let workspace = open()
        #expect(workspace.panelItem.isCollapsed)
        workspace.project.showLogs = true
        try await waitUntil { isClose(self.height(workspace.panelItem), 210, within: 1) }
    }

    /// A divider moved by hand is kept for the next launch.
    @Test func aMovedDividerIsKept() async throws {
        let workspace = open()
        // Once the panes have appeared at the sizes they were made with.
        try await waitUntil { self.width(workspace.pdfItem) > 0 }
        try await Task.sleep(for: .milliseconds(50))
        let split = workspace.columns.splitView
        split.setPosition(split.bounds.width * 0.7, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let share = width(workspace.pdfItem) / (width(workspace.sourceItem) + width(workspace.pdfItem))
        try await waitUntil { isClose(PaneSize.pdfShare.value ?? 0, share, within: 0.01) }
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

    /// No pane's content raises the window's minimum: it goes down to the app's own,
    /// the sidebar folded (a user's narrowing folds it; setting the size doesn't).
    @Test func theWindowReachesItsMinimum() {
        let workspace = open(panel: true, sidebar: false)
        window?.setContentSize(WindowMetrics.contentMinimum)
        window?.layoutIfNeeded()
        #expect(isClose(workspace.view.frame.width, WindowMetrics.contentMinimum.width))
        // Below the titlebar: the panes stop at the safe area.
        #expect(isClose(workspace.view.frame.height - workspace.view.safeAreaInsets.top, WindowMetrics.contentMinimum.height))
    }
}
