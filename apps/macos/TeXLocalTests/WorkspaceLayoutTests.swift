import AppKit
import XCTest
@testable import TeXLocal

/// The project window's split as AppKit lays it out: the build panel and the status
/// bar span source and PDF, a hidden PDF comes back at its width, and panes open at
/// the sizes kept for them. On screen, unseen (split animations need an awake,
/// unlocked display).
@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    /// The app's defaults the tests change, put back after each.
    private static let keys = [DefaultsKey.paneSizes, DefaultsKey.sidebarVisible, DefaultsKey.inspectorVisible,
                               DefaultsKey.showPDF, DefaultsKey.outlineCollapsed]
    private var saved: [String: Any] = [:]
    private var window: NSWindow?
    private var workspace: WorkspaceController?
    private var project: ProjectModel?

    override func setUp() async throws {
        for key in Self.keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.removeObject(forKey: DefaultsKey.paneSizes)
    }

    override func tearDown() async throws {
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
    private func open(_ size: NSSize = NSSize(width: 1200, height: 760), panel: Bool = false,
                      pdf: Bool = true, sidebar: Bool = true) -> WorkspaceController {
        let app = AppModel()
        app.sidebarVisible = sidebar
        app.inspectorVisible = false
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

    func testThePanelSpansSourceAndPDF() async throws {
        let workspace = open(panel: true)
        try await waitUntil { self.height(workspace.panelItem) > 0 }
        let columns = width(workspace.sourceItem) + workspace.columns.splitView.dividerThickness + width(workspace.pdfItem)
        XCTAssertEqual(width(workspace.panelItem), columns, accuracy: 0.5)
        XCTAssertEqual(width(workspace.panelItem), workspace.area.view.frame.width, accuracy: 0.5)
    }

    /// Hide PDF gives the source the room; Show PDF brings the PDF back at its width.
    func testTheHiddenPDFComesBackAtItsWidth() async throws {
        let workspace = open()
        let pdfWidth = width(workspace.pdfItem)
        XCTAssertGreaterThan(pdfWidth, ColumnMetrics.pdfMinimum)
        workspace.project.showPDF = false
        try await waitUntil {
            workspace.pdfItem.isCollapsed
                && abs(self.width(workspace.sourceItem) - workspace.columns.view.frame.width) < 0.5
        }
        workspace.project.showPDF = true
        try await waitUntil { !workspace.pdfItem.isCollapsed && abs(self.width(workspace.pdfItem) - pdfWidth) < 1 }
    }

    /// The build panel opens at the height kept for it, not at its minimum.
    func testThePanelOpensAtItsKeptHeight() async throws {
        PaneSize.panel.store(210)
        let workspace = open()
        XCTAssertTrue(workspace.panelItem.isCollapsed)
        workspace.project.showLogs = true
        try await waitUntil { abs(self.height(workspace.panelItem) - 210) < 1 }
    }

    /// A divider moved by hand is kept for the next launch.
    func testAMovedDividerIsKept() async throws {
        let workspace = open()
        // Once the panes have appeared at the sizes they were made with.
        try await waitUntil { self.width(workspace.pdfItem) > 0 }
        try await Task.sleep(for: .milliseconds(50))
        let split = workspace.columns.splitView
        split.setPosition(split.bounds.width * 0.7, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let share = width(workspace.pdfItem) / (width(workspace.sourceItem) + width(workspace.pdfItem))
        try await waitUntil { abs((PaneSize.pdfShare.value ?? 0) - share) < 0.01 }
    }

    /// No pane's content raises the window's minimum: it goes down to the app's own,
    /// the sidebar folded (a user's narrowing folds it; setting the size doesn't).
    func testTheWindowReachesItsMinimum() {
        let workspace = open(panel: true, sidebar: false)
        window?.setContentSize(WindowMetrics.contentMinimum)
        window?.layoutIfNeeded()
        XCTAssertEqual(workspace.view.frame.width, WindowMetrics.contentMinimum.width, accuracy: 0.5)
        // Below the titlebar: the panes stop at the safe area.
        XCTAssertEqual(workspace.view.frame.height - workspace.view.safeAreaInsets.top,
                       WindowMetrics.contentMinimum.height, accuracy: 0.5)
    }
}
