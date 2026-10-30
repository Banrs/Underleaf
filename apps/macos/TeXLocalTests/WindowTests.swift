import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

@Suite(.serialized)
struct WindowTests {
    private let defaults = TestDefaults()

    @Test func preferencesAreKeptInTheInjectedStore() {
        let app = defaults.app()
        #expect((app.fontName, app.fontSize, app.syntaxTheme, app.lineNumbers, app.autoPair, app.autoComplete) == ("", 13, .system, true, true, true))
        #expect((app.spellCheck, app.syncAfterCompile, app.newProjectEngine, app.paper, app.settingsPane) == (true, false, .pdflatex, .white, .general))
        (app.fontName, app.fontSize, app.syntaxTheme, app.lineNumbers, app.autoPair, app.autoComplete) = ("Menlo", 15, .overleaf, false, false, false)
        (app.spellCheck, app.syncAfterCompile, app.newProjectEngine, app.paper, app.settingsPane) = (false, true, .xelatex, .dark, .pdf)
        let again = defaults.app()
        #expect((again.fontName, again.fontSize, again.syntaxTheme, again.lineNumbers, again.autoPair, again.autoComplete) == ("Menlo", 15, .overleaf, false, false, false))
        #expect((again.spellCheck, again.syncAfterCompile, again.newProjectEngine, again.paper, again.settingsPane) == (false, true, .xelatex, .dark, .pdf))
    }

    @Test func thePDFsPaperAndTheEditorsSpellCheckFollowTheStore() async throws {
        let window = defaults.window(), app = window.app
        let views = WorkspaceViews(project: ProjectModel(id: "P", window: window))
        let text = views.editor.textView
        #expect(!views.pdf.view.darkPaper && text.isContinuousSpellCheckingEnabled)
        app.paper = .dark
        try await waitUntil { views.pdf.view.darkPaper }
        text.toggleContinuousSpellChecking(nil)
        #expect(!app.spellCheck)
    }

    @Test func anErrorShowsOnItsWindowAndOneThatComesWhileItIsUpIsOnlyAnnounced() async throws {
        let controller = MainWindowController(app: defaults.app())
        let (model, window) = (controller.model, try #require(controller.window))
        window.orderFront(nil)
        defer { window.close() }
        model.report("Couldn’t Open “a.tex”", "It’s gone.")
        model.report("Couldn’t Open “b.tex”", CocoaError(.fileNoSuchFile))
        #expect(model.alert?.title == "Couldn’t Open “a.tex”" && model.alert?.message == "It’s gone.")
        try await waitUntil { window.attachedSheet != nil }
        model.alert = nil
        try await waitUntil { window.attachedSheet == nil }
        model.report("Couldn’t Open “b.tex”", CocoaError(.fileNoSuchFile))
        #expect(model.alert?.title == "Couldn’t Open “b.tex”")
        model.alert = nil
    }

    @Test func sheetsArePresentedFromTheWindowOnHomeAndInAProject() async throws {
        let info = try await newProject()
        let app = defaults.app()
        app.autoCompile = false
        let controller = MainWindowController(app: app)
        let (model, window) = (controller.model, try #require(controller.window))
        window.orderFront(nil)
        defer { window.close() }
        model.newProjectDraft = NewProjectDraft(template: .article, name: "Draft")
        try await waitUntil { window.attachedSheet != nil }
        model.newProjectDraft = nil
        try await waitUntil { window.attachedSheet == nil }

        await model.open(info.id)
        try await waitUntil { controller.workspace != nil }
        model.prompt = .gotoLine
        try await waitUntil { window.attachedSheet != nil }
        model.prompt = nil
        try await waitUntil { window.attachedSheet == nil }
        #expect(await model.close())
    }

    @Test func findInProjectFocusesTheSearchOnHomeAndInAProject() async throws {
        let info = try await newProject()
        let app = defaults.app()
        app.autoCompile = false
        let controller = MainWindowController(app: app)
        let (model, window) = (controller.model, try #require(controller.window))
        window.orderFront(nil)
        defer { window.close() }
        try await waitUntil { window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true }
        controller.focusSearch()
        try await waitUntil { window.firstResponder is NSTextView }

        await model.open(info.id)
        try await waitUntil { controller.workspace != nil }
        let sidebar = try #require(controller.workspace?.splitViewItems.first)
        sidebar.isCollapsed = true
        model.perform(.projectSearch, on: model.project)
        try await waitUntil {
            ((window.firstResponder as? NSText)?.delegate as? NSSearchField)?.placeholderString == "Search Project" && !sidebar.isCollapsed
        }
        #expect(await model.close())
    }

    @Test func anotherProjectOpensInATabBesideTheWindowAndAnOpenOneComesForward() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let app = defaults.app()
        app.autoCompile = false
        app.newWindow = { MainWindowController.tab(app: app, beside: $0).model }
        let controller = MainWindowController(app: app)
        let window = try #require(controller.window)
        window.tabbingIdentifier = UUID().uuidString
        controller.showWindow(nil)
        defer { for model in app.windows { (model.controller as? MainWindowController)?.window?.close() } }
        await controller.model.open(first.id)
        await controller.model.open(second.id)
        let tab = try #require(app.window(showing: second.id)?.controller as? MainWindowController)
        #expect(window.tabbedWindows?.count == 2 && window.tabGroup?.selectedWindow === tab.window)
        try await waitUntil { window.tab.title == first.name && tab.window?.tab.title == second.name }
        await tab.model.open(first.id)
        #expect(window.tabGroup?.selectedWindow === window && app.windows.count == 2)
        controller.newWindowForTab(nil)
        #expect(window.tabbedWindows?.count == 3 && app.windows.contains { $0.project == nil })
        for model in app.windows { #expect(await model.close()) }
    }

    @Test func closingAWindowSavesAndClosesItsProjectAndARestoredOneOpensItAgain() async throws {
        let info = try await newProject()
        let app = defaults.app()
        app.autoCompile = false
        let controller = MainWindowController(app: app)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        await controller.model.open(info.id)
        let project = try #require(controller.model.project)
        let document = try #require(SourceDocument(session: project.session, path: "main.tex"))
        _ = document.edit(NSRange(location: 0, length: 0), with: "% kept\n", changing: nil, mirroring: false)
        let state = NSKeyedArchiver(requiringSecureCoding: true)
        controller.window(window, willEncodeRestorableState: state)
        window.performClose(nil)
        try await waitUntil { !window.isVisible }
        #expect(project.closed && app.windows.isEmpty)
        #expect(try String(contentsOfFile: info.path + "/main.tex", encoding: .utf8).hasPrefix("% kept\n"))

        let restored = MainWindowController(app: app)
        let again = try #require(restored.window)
        defer { again.close() }
        restored.window(again, didDecodeRestorableState: try NSKeyedUnarchiver(forReadingFrom: state.encodedData))
        await restored.model.reopen()
        #expect(restored.model.project?.id == info.id && restored.model.project?.isOpen == true)
        #expect(await restored.model.close())
    }

    @Test func theToolbarFollowsTheLayoutAndTheColumnsWidthsAtOnceWhileADividerIsDragged() async throws {
        let model = defaults.window()
        let views = WorkspaceViews(project: ProjectModel(id: "P", window: model))
        let workspace = WorkspaceController(window: model, views: views, size: CGSize(width: 1400, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.toolbar = workspace.toolbar.toolbar
        window.layoutIfNeeded()
        defer { workspace.close(); window.close() }
        let format = try #require(workspace.toolbar.toolbar.items.first { $0.itemIdentifier == .format })
        model.layout = .pdf
        try await waitUntil { format.isHidden }
        model.layout = .split
        try await waitUntil { !format.isHidden }

        let columns = try #require(workspace.columns.splitView as? DraggedSplitView)
        func move(to position: CGFloat) {
            columns.setPosition(position, ofDividerAt: 0)
            window.layoutIfNeeded()
        }
        move(to: columns.bounds.width)
        #expect(workspace.toolbar.compactCompile)
        workspace.quiet(true)
        move(to: ColumnMetrics.paneMinimum)
        #expect(workspace.toolbar.compactCompile)
        workspace.quiet(false)
        #expect(!workspace.toolbar.compactCompile)
        columns.drag {
            move(to: columns.bounds.width)
            #expect(workspace.toolbar.compactCompile)
            move(to: ColumnMetrics.paneMinimum)
            #expect(!workspace.toolbar.compactCompile)
        }
    }

    @Test func aSearchFieldHandsReturnArrowsAndEscapeToItsActions() {
        var heard: [String] = []
        let field = SearchField(text: .constant(""), prompt: "Open Quickly", step: { heard.append("step \($0)") },
                                move: { heard.append("move \($0)") }, close: { heard.append("close") })
        let coordinator = field.makeCoordinator()
        for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertNewline(_:)),
                         #selector(NSResponder.cancelOperation(_:))] {
            #expect(coordinator.control(NSSearchField(), textView: NSTextView(), doCommandBy: selector))
        }
        #expect(!coordinator.control(NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(heard == ["move 1", "move -1", "step 1", "close"])
    }
}
