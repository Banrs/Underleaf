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
        let field = try #require(panel.viewController.view.descendants(of: NSTextField.self).first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        panel.isCollapsed = true
        #expect(!workspace.project.panel.shown && window.firstResponder === workspace.pdf.view)
    }

    @Test func theBuildLogScrollsUnderItsControlsAndTheLastLineClearsThem() async throws {
        let (window, workspace) = workspaceWindow(TestDefaults().window())
        defer { workspace.close(); window.close() }
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        let area = try #require(workspace.splitViewItems[1].viewController as? NSSplitViewController)
        let panel = try #require(area.splitViewItems.last)
        let log = (1...80).map { "Build log line \($0)" }.joined(separator: "\n")
        workspace.project.store.apply(.buildLog(log))
        panel.isCollapsed = false
        window.layoutIfNeeded()

        let pane = panel.viewController.view
        let field = try #require(pane.descendants(of: NSTextField.self).first { $0.isEditable })
        let scroll = try #require(pane.descendants(of: NSScrollView.self).first { $0.documentView is NSTextView })
        let text = try #require(scroll.documentView as? NSTextView)
        try await waitUntil(timeout: .seconds(2)) { text.string == log && scroll.contentView.contentInsets.bottom > 0 }
        let viewport = scroll.convert(scroll.bounds, to: nil), filter = field.convert(field.bounds, to: nil)
        #expect(viewport.contains(NSPoint(x: filter.midX, y: filter.midY)))
        #expect(scroll.scrollerInsets.bottom == scroll.contentView.contentInsets.bottom)

        let last = (log as NSString).range(of: "Build log line 80")
        try await waitUntil(timeout: .seconds(2)) {
            let line = window.convertFromScreen(text.firstRect(forCharacterRange: last, actualRange: nil))
            return line.height > 0 && line.minY >= filter.maxY && line.maxY <= viewport.maxY
        }
    }

    @Test func closingLogsLaysOutTheRevealedSourceDuringTheResize() async throws {
        let defaults = TestDefaults()
        let (window, workspace) = workspaceWindow(defaults.window())
        defer { workspace.close(); window.close() }
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        let area = try #require(workspace.splitViewItems[1].viewController as? NSSplitViewController)
        let panel = try #require(area.splitViewItems.last)
        let editor = workspace.views.editor, text = editor.textView
        workspace.project.store.apply(.openFile(OpenFile(path: "main.tex", kind: .tex, text: true)))
        editor.open(path: "main.tex", source: SourceDocument(text: (1...200).map { "Line \($0)" }.joined(separator: "\n")))
        panel.isCollapsed = false
        try await waitUntil(timeout: .seconds(3)) { !text.isHidden && text.fragments.count > 5 }
        let bottom = text.visibleRect.maxY
        // On the main actor, which AppKit calls the completion handler on, so the handler and the test share it safely.
        final class Animation { var finished = false }
        let animation = Animation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.8
            panel.animator().isCollapsed = true
        } completionHandler: { MainActor.assumeIsolated { animation.finished = true } }
        try await waitUntil(timeout: .seconds(2)) { text.visibleRect.maxY > bottom + 10 }
        #expect(!animation.finished && text.preparedContentRect.contains(text.visibleRect))
        try await waitUntil(timeout: .seconds(2)) { animation.finished }
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
