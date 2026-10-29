import AppKit
import Testing
@testable import TeXLocal

@Suite(.serialized)
struct PaneTests {
    private static let toggleSidebar = #selector(NSSplitViewController.toggleSidebar(_:))
    private static let toggleInspector = #selector(NSSplitViewController.toggleInspector(_:))

    @Test func theStandardActionsCollapseAndRestoreTheSidebarAndTheInspectorFromAnywhereInTheWindow() async throws {
        let defaults = TestDefaults()
        let app = defaults.app()
        let (window, workspace) = open(app)
        defer { workspace.close(); window.close() }
        let (sidebar, inspector) = (try #require(workspace.splitViewItems.first), try #require(workspace.splitViewItems.last))
        let editor = workspace.views.editor.textView
        #expect(sidebar.behavior == .sidebar && !sidebar.isCollapsed)
        #expect(inspector.behavior == .inspector && inspector.isCollapsed && forms(in: inspector) == 0)
        #expect(app.title(.viewToggleInspector, on: workspace.project) == "Show Inspector")

        #expect(editor.tryToPerform(Self.toggleSidebar, with: nil))
        try await waitUntil { sidebar.isCollapsed }
        workspace.revealSidebar()
        try await waitUntil { !sidebar.isCollapsed }
        #expect(window.tryToPerform(Self.toggleSidebar, with: nil))
        try await waitUntil { sidebar.isCollapsed }

        #expect(editor.tryToPerform(Self.toggleInspector, with: nil))
        #expect(forms(in: inspector) > 0 && app.title(.viewToggleInspector, on: workspace.project) == "Hide Inspector")
        try await waitUntil { !inspector.isCollapsed }
        #expect(editor.tryToPerform(Self.toggleInspector, with: nil))
        try await waitUntil { inspector.isCollapsed }
        #expect(app.title(.viewToggleInspector, on: workspace.project) == "Show Inspector")

        let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        let item = try #require(items.first { $0.action == Self.toggleSidebar })
        #expect(item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.command, .control])
    }

    @Test func draggingTheBuildPanelShutOrOpenIsWhatTheProjectShows() throws {
        let defaults = TestDefaults()
        let (window, workspace) = open(defaults.app())
        defer { workspace.close(); window.close() }
        let area = try #require(workspace.splitViewItems[1].viewController as? NSSplitViewController)
        let panel = try #require(area.splitViewItems.last)
        #expect(panel.isCollapsed && !workspace.project.panel.shown)
        panel.isCollapsed = false
        workspace.dragged(workspace.columns.splitView)
        #expect(!workspace.project.panel.shown)
        workspace.dragged(area.splitView)
        #expect(workspace.project.panel.shown)
        panel.isCollapsed = true
        workspace.dragged(area.splitView)
        #expect(!workspace.project.panel.shown)
    }

    @Test func theSplitViewsKeepTheSidebarInspectorAndBuildPanelUnderTheirAutosaveNames() async throws {
        let names = ["Workspace 2", "Sidebar", "Columns", "Area"]
        let keys = names.map { "NSSplitView Subview Frames \($0)" } + [DefaultsKey.buildPanelHeight]
        let kept = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { UserDefaults.standard.set(value, forKey: key) } }
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        let app = AppModel(core: .shared)
        #expect(app.savesLayout)

        let (window, workspace) = open(app)
        #expect([workspace.splitView, workspace.columns.splitView].map(\.autosaveName) == ["Workspace 2", "Columns"])
        let (sidebar, inspector) = (try #require(workspace.splitViewItems.first), try #require(workspace.splitViewItems.last))
        (sidebar.isCollapsed, inspector.isCollapsed) = (true, false)
        workspace.project.panel.shown = true
        func saved(_ key: String, _ index: Int) -> String? { UserDefaults.standard.stringArray(forKey: key)?.dropFirst(index).first }
        try await waitUntil { saved(keys[0], 0)?.contains(", YES,") == true && saved(keys[3], 1)?.contains(", NO,") == true }
        workspace.close()
        window.close()

        let (again, restored) = open(app)
        defer { restored.close(); again.close() }
        let (sidebarAgain, inspectorAgain) = (try #require(restored.splitViewItems.first), try #require(restored.splitViewItems.last))
        #expect(sidebarAgain.isCollapsed && !inspectorAgain.isCollapsed && forms(in: inspectorAgain) > 0)
        #expect(restored.project.panel.shown)
    }

    @Test func theWindowControllerPassesTheInspectorToggleToTheWorkspaceItShows() throws {
        let defaults = TestDefaults()
        let app = defaults.app()
        let controller = MainWindowController(app: app)
        #expect(controller.supplementalTarget(forAction: Self.toggleInspector, sender: nil) == nil)
        let (window, workspace) = open(app)
        defer { workspace.close(); window.close() }
        controller.window = window
        window.contentViewController = workspace
        #expect(controller.supplementalTarget(forAction: Self.toggleInspector, sender: nil) as? WorkspaceController === workspace)
        #expect(controller.supplementalTarget(forAction: Self.toggleSidebar, sender: nil) == nil)
        #expect(controller.undoManager != nil && controller.undoManager === window.undoManager)
    }

    private func open(_ app: AppModel) -> (NSWindow, WorkspaceController) {
        let views = WorkspaceViews(project: ProjectModel(id: "P", app: app))
        let workspace = WorkspaceController(app: app, views: views, size: CGSize(width: 1400, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.layoutIfNeeded()
        return (window, workspace)
    }

    private func forms(in item: NSSplitViewItem) -> Int {
        let view = item.viewController.view
        view.layoutSubtreeIfNeeded()
        return view.descendants(of: NSScrollView.self).count
    }
}
