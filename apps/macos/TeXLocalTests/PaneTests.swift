import AppKit
import Testing
@testable import TeXLocal

struct PaneTests {
    private static let toggleSidebar = #selector(NSSplitViewController.toggleSidebar(_:))
    private static let toggleInspector = #selector(NSSplitViewController.toggleInspector(_:))

    @Test func theFindBreadcrumbTraversesItsComponentsAndThenLeavesInEitherDirection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let before = NSTextField(frame: NSRect(x: 0, y: 60, width: 100, height: 24))
        let after = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        let crumb = Breadcrumb { _, _ in }
        crumb.items = [.init(choices: ["Find", "Replace"], chosen: 0), .init(choices: ["Text", "Whole Words"], chosen: 0)]
        crumb.frame = NSRect(x: 0, y: 30, width: 200, height: 19)
        for view in [before, crumb, after] { window.contentView?.addSubview(view) }
        before.nextKeyView = crumb
        crumb.nextKeyView = after
        window.layoutIfNeeded()
        #expect(!crumb.acceptsFirstResponder)
        window.selectKeyView(following: before)
        #expect(window.firstResponder === crumb && crumb.acceptsFirstResponder)
        let first = crumb.focusRingMaskBounds
        #expect(first.width > 0)
        func key(_ text: String, code: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: text,
                                                     charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            crumb.keyDown(with: event)
        }
        try key("\u{f703}", code: 124)
        let second = crumb.focusRingMaskBounds
        #expect(second.minX == first.maxX)
        try key("\u{f703}", code: 124)
        #expect(crumb.focusRingMaskBounds == second)
        try key("\u{f702}", code: 123)
        #expect(crumb.focusRingMaskBounds == first)
        try key("\t", code: 48)
        #expect(window.firstResponder === crumb && crumb.focusRingMaskBounds == second)
        crumb.selectNextKeyView(nil)
        #expect(window.firstResponder === after.currentEditor())
        window.selectKeyView(preceding: after)
        #expect(window.firstResponder === crumb && crumb.focusRingMaskBounds == second)
        crumb.insertBacktab(nil)
        #expect(crumb.focusRingMaskBounds == first)
        crumb.selectPreviousKeyView(nil)
        #expect(window.firstResponder === before.currentEditor())
        let parts = try #require(crumb.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(parts.count == 2 && parts.allSatisfy { $0.accessibilityRole() == .popUpButton })
    }

    @Test func tabbingOutOfFilesSkipsTheHiddenNavigatorsAndFindGivesUpTheKeyboardAsItHides() throws {
        let defaults = TestDefaults()
        let (window, workspace) = open(defaults.window())
        defer { workspace.close(); window.close() }
        window.autorecalculatesKeyViewLoop = true
        let project = workspace.project
        (project.search.replacing, project.navigator.shown) = (true, .files)
        let sidebar = workspace.splitViewItems[0].viewController.view
        sidebar.layoutSubtreeIfNeeded()
        let fields = sidebar.descendants(of: NSSearchField.self), lists = sidebar.descendants(of: NSOutlineView.self)
        #expect(fields.count == 2 && lists.count == Navigator.allCases.count)
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
        let (window, workspace) = open(model)
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
        let (window, workspace) = open(defaults.window())
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

    @Test func theSplitViewsKeepTheSidebarInspectorAndBuildPanelUnderTheirAutosaveNames() async throws {
        let names = ["Workspace 2", "Columns", "Area"]
        let keys = names.map { "NSSplitView Subview Frames \($0)" } + [DefaultsKey.buildPanelHeight]
        let kept = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { UserDefaults.standard.set(value, forKey: key) } }
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        let model = WindowModel(app: AppModel(core: .shared))
        #expect(model.app.savesLayout)

        let (window, workspace) = open(model)
        #expect([workspace.splitView, workspace.columns.splitView].map(\.autosaveName) == ["Workspace 2", "Columns"])
        let (sidebar, inspector) = (try #require(workspace.splitViewItems.first), try #require(workspace.splitViewItems.last))
        (sidebar.isCollapsed, inspector.isCollapsed) = (true, false)
        workspace.project.panel.shown = true
        func saved(_ key: String, _ index: Int) -> String? { UserDefaults.standard.stringArray(forKey: key)?.dropFirst(index).first }
        try await waitUntil { saved(keys[0], 0)?.contains(", YES,") == true && saved(keys[2], 1)?.contains(", NO,") == true }
        workspace.close()
        window.close()

        let (again, restored) = open(model)
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

    private func open(_ model: WindowModel) -> (NSWindow, WorkspaceController) {
        let views = WorkspaceViews(project: ProjectModel(id: "P", window: model))
        let workspace = WorkspaceController(window: model, views: views, size: CGSize(width: 1400, height: 800))
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
