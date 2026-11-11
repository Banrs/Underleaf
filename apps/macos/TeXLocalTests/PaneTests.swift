import AppKit
import Testing
@testable import TeXLocal

struct PaneTests {
    private static let toggleSidebar = #selector(NSSplitViewController.toggleSidebar(_:))
    private static let toggleInspector = #selector(NSSplitViewController.toggleInspector(_:))

    @Test func tabbingOutOfFilesSkipsTheHiddenNavigatorsAndFindGivesUpTheKeyboardAsItHides() throws {
        let defaults = TestDefaults()
        let (window, workspace) = workspaceWindow(defaults.window())
        defer { workspace.close(); window.close() }
        window.autorecalculatesKeyViewLoop = true
        let project = workspace.project
        (project.search.replacing, project.navigator.shown) = (true, .files)
        let sidebar = workspace.splitViewItems[0].viewController.view
        sidebar.layoutSubtreeIfNeeded()
        let fields = sidebar.descendants(of: NSTextField.self).filter(\.isEditable), lists = sidebar.descendants(of: NSOutlineView.self)
        #expect(fields.count == 2 && fields[0] is NSSearchField && lists.count == Navigator.allCases.count)
        func inFind() -> Bool { fields.contains { $0.currentEditor() != nil } }
        for step in [NSWindow.selectNextKeyView(_:), NSWindow.selectPreviousKeyView(_:)] {
            #expect(window.makeFirstResponder(lists[0]))
            var reached: Set<ObjectIdentifier> = []
            for _ in 0..<20 {
                step(window)(nil)
                let responder = try #require(window.firstResponder)
                #expect(!inFind() && !lists.dropFirst().contains { $0 === responder })
                reached.insert(ObjectIdentifier(responder))
            }
            reached.remove(ObjectIdentifier(lists[0]))
            #expect(!reached.isEmpty)
        }

        workspace.focusSearch()
        #expect(project.navigator.shown == .search && fields[0].currentEditor() != nil)
        project.navigator.shown = .files
        sidebar.layoutSubtreeIfNeeded()
        #expect(!inFind())
    }

    @Test func theStandardActionsCollapseAndRestoreTheSidebarAndTheInspectorFromAnywhereInTheWindow() async throws {
        let defaults = TestDefaults()
        let model = defaults.window()
        let (window, workspace) = workspaceWindow(model)
        defer { workspace.close(); window.close() }
        let (sidebar, inspector) = (try #require(workspace.splitViewItems.first), try #require(workspace.splitViewItems.last))
        let editor = workspace.views.editor.textView
        #expect(sidebar.behavior == .sidebar && !sidebar.isCollapsed)
        #expect(inspector.behavior == .inspector && inspector.isCollapsed && forms(in: inspector) == 0)
        #expect(model.title(.viewToggleInspector, on: workspace.project) == "Show Inspector")

        #expect(editor.tryToPerform(Self.toggleSidebar, with: nil))
        try await waitUntil { sidebar.isCollapsed }
        workspace.revealSidebar()
        try await waitUntil { !sidebar.isCollapsed }
        #expect(window.tryToPerform(Self.toggleSidebar, with: nil))
        try await waitUntil { sidebar.isCollapsed }

        #expect(editor.tryToPerform(Self.toggleInspector, with: nil))
        #expect(forms(in: inspector) > 0 && model.title(.viewToggleInspector, on: workspace.project) == "Hide Inspector")
        try await waitUntil { !inspector.isCollapsed }
        #expect(editor.tryToPerform(Self.toggleInspector, with: nil))
        try await waitUntil { inspector.isCollapsed }
        #expect(model.title(.viewToggleInspector, on: workspace.project) == "Show Inspector")

        let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        let item = try #require(items.first { $0.action == Self.toggleSidebar })
        #expect(item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.command, .control])
    }

    @Test func theBuildPanelShownIsWhatItsSplitItemSaysHoweverItCollapsesAndFocusLeavesIt() throws {
        let defaults = TestDefaults()
        let (window, workspace) = workspaceWindow(defaults.window())
        defer { workspace.close(); window.close() }
        let area = try #require(workspace.splitViewItems[1].viewController as? NSSplitViewController)
        let panel = try #require(area.splitViewItems.last)
        #expect(panel.isCollapsed && !workspace.project.panel.shown)
        panel.isCollapsed = false
        #expect(workspace.project.panel.shown)
        window.layoutIfNeeded()
        let field = try #require(panel.viewController.view.descendants(of: NSSearchField.self).first)
        #expect(window.makeFirstResponder(field))
        panel.isCollapsed = true
        #expect(!workspace.project.panel.shown && window.firstResponder === workspace.pdf.view)
    }

    @Test func onlyTheStatusBarsTopEdgeDragsTheBuildPanelLeavingItsButtonsAndTheEditorTheirClicks() throws {
        let defaults = TestDefaults()
        let (window, workspace) = workspaceWindow(defaults.window())
        defer { workspace.close(); window.close() }
        let split = try #require(workspace.splitViewItems[1].viewController as? NSSplitViewController).splitView
        let content = try #require(window.contentView)
        let edge = split.arrangedSubviews[0].frame.maxY - BarMetrics.height
        func hit(_ y: CGFloat) -> NSView? { content.hitTest(content.superview!.convert(split.convert(NSPoint(x: 300, y: y), to: nil), from: nil)) }
        #expect(hit(edge) === split)
        #expect(hit(edge + BarMetrics.height / 2) !== split && hit(edge - 20) !== split)
    }

    @Test func theSplitViewsKeepTheSidebarInspectorAndBuildPanelUnderTheirAutosaveNames() async throws {
        let names = ["Workspace 2", "Columns", "Area"]
        let keys = names.map { "NSSplitView Subview Frames \($0)" } + [DefaultsKey.buildPanelHeight]
        let kept = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { UserDefaults.standard.set(value, forKey: key) } }
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        let model = WindowModel(app: AppModel(core: .shared))
        #expect(model.app.savesLayout)

        let (window, workspace) = workspaceWindow(model)
        #expect([workspace.splitView, workspace.columns.splitView].map(\.autosaveName) == ["Workspace 2", "Columns"])
        let (sidebar, inspector) = (try #require(workspace.splitViewItems.first), try #require(workspace.splitViewItems.last))
        (sidebar.isCollapsed, inspector.isCollapsed) = (true, false)
        workspace.project.panel.shown = true
        func saved(_ key: String, _ index: Int) -> String? { UserDefaults.standard.stringArray(forKey: key)?.dropFirst(index).first }
        try await waitUntil { saved(keys[0], 0)?.contains(", YES,") == true && saved(keys[2], 1)?.contains(", NO,") == true }
        workspace.close()
        window.close()

        let (again, restored) = workspaceWindow(model)
        defer { restored.close(); again.close() }
        let (sidebarAgain, inspectorAgain) = (try #require(restored.splitViewItems.first), try #require(restored.splitViewItems.last))
        #expect(sidebarAgain.isCollapsed && !inspectorAgain.isCollapsed && forms(in: inspectorAgain) > 0)
        #expect(restored.project.panel.shown)
    }

    @Test func theWindowShowsItsWorkspaceAtOnceAndItsControllerPassesTheInspectorToggleToIt() throws {
        let defaults = TestDefaults()
        let controller = MainWindowController(app: defaults.app(), project: "P")
        let (window, workspace) = (try #require(controller.window), try #require(controller.workspace))
        defer { window.close() }
        #expect(window.contentViewController === workspace && window.toolbar === workspace.toolbar.toolbar)
        #expect(controller.supplementalTarget(forAction: Self.toggleInspector, sender: nil) as? WorkspaceController === workspace)
        #expect(controller.supplementalTarget(forAction: Self.toggleSidebar, sender: nil) == nil)
        #expect(controller.undoManager != nil && controller.undoManager === window.undoManager)
    }

    private func forms(in item: NSSplitViewItem) -> Int {
        let view = item.viewController.view
        view.layoutSubtreeIfNeeded()
        return view.descendants(of: NSScrollView.self).count
    }
}
