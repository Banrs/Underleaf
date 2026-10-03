import AppKit
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
    private static let size = NSSize(width: 1200, height: 600)
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
        let workspace = WorkspaceController(app: app, project: project, size: size)
        let window = UnclampedWindow(contentRect: NSRect(origin: .zero, size: size),
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

    /// Panes open on whole points: one half a point off centres its content half a point low.
    @Test func firstSizesAreWholePoints() async throws {
        let workspace = open(size: NSSize(width: Self.size.width, height: 601))
        workspace.app.outlineCollapsed = false
        workspace.project.showLogs = true
        try await waitUntil { self.height(workspace.panelItem) > 0 }
        for item in [workspace.outlineItem!, workspace.panelItem!] { #expect(height(item) == height(item).rounded()) }
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

    /// Folded, the File Outline's header is the files' last section, and its pane is
    /// gone; unfolding it there brings the pane back under its own header.
    @Test func theFoldedOutlineHeaderJoinsTheFiles() async throws {
        let workspace = open(), project = workspace.project
        workspace.app.outlineCollapsed = true
        project.tree = [TreeNode(type: "file", name: "main.tex", path: "main.tex", children: nil)]
        project.outline = [OutlineItem(id: 0, level: 1, title: "Introduction", line: 1, file: "main.tex")]
        project.openPath = "main.tex"
        func lists(_ view: NSView) -> [NSOutlineView] { [view as? NSOutlineView].compactMap(\.self) + view.subviews.flatMap(lists) }
        let files = { lists(workspace.sidebarItem.viewController.view).first?.numberOfRows }
        let outline = { lists(workspace.outlineItem.viewController.view).first?.numberOfRows }
        // Files: its header, main.tex and the File Outline's header.
        try await waitUntil { files() == 3 } state: { "files \(String(describing: files()))" }
        #expect(workspace.outlineItem.isCollapsed)

        workspace.app.outlineCollapsed = false
        // Files: its header and main.tex; the File Outline: its header and the heading.
        try await waitUntil { !workspace.outlineItem.isCollapsed && files() == 2 && outline() == 2 } state: {
            "collapsed \(workspace.outlineItem.isCollapsed), files \(String(describing: files())), outline \(String(describing: outline()))"
        }
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
        // Files, then the File Outline.
        func lists(_ view: NSView) -> [NSOutlineView] { [view as? NSOutlineView].compactMap(\.self) + view.subviews.flatMap(lists) }
        func rows() -> [Int] { lists(workspace.view).map(\.numberOfRows) }
        // Files: its header, the folder and main.tex; the outline: its header and two headings.
        try await waitUntil { rows() == [3, 3] } state: { "\(rows())" }

        // The folder opens. The headings come after the file, as the core's analysis does.
        project.openPath = "chapters/results.tex"
        try await waitUntil { rows().first == 4 } state: { "\(rows())" }
        project.outline = [OutlineItem(id: 0, level: 1, title: "Results", line: 1, file: "chapters/results.tex"),
                           OutlineItem(id: 1, level: 2, title: "Discussion", line: 9, file: "chapters/results.tex")]
        let outline = try #require(lists(workspace.view).last)
        try await waitUntil { outline.isExpandable(outline.item(atRow: 1)) }
        #expect(outline.isItemExpanded(outline.item(atRow: 1)))
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
}

/// A window kept at the size it's given. Ordered front, a titled window shrinks
/// to the screen's visible frame, and a CI runner's screen is smaller than the
/// tests' window: the workspace, made for the size asked, would be squeezed after.
private final class UnclampedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
