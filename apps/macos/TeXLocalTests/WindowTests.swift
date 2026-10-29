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
        let app = defaults.app()
        let views = WorkspaceViews(project: ProjectModel(id: "P", app: app))
        let text = views.editor.textView
        #expect(!views.pdf.view.darkPaper && text.isContinuousSpellCheckingEnabled)
        app.paper = .dark
        try await waitUntil { views.pdf.view.darkPaper }
        text.toggleContinuousSpellChecking(nil)
        #expect(!app.spellCheck)
    }

    @Test func anErrorShowsOnTheWindowAndOneThatComesWhileItIsUpIsOnlyAnnounced() async throws {
        let app = defaults.app()
        let controller = MainWindowController(app: app)
        let window = try #require(controller.window)
        window.orderFront(nil)
        defer { window.close() }
        app.report("Couldn’t Open “a.tex”", "It’s gone.")
        app.report("Couldn’t Open “b.tex”", CocoaError(.fileNoSuchFile))
        #expect(app.alert?.title == "Couldn’t Open “a.tex”" && app.alert?.message == "It’s gone.")
        try await waitUntil { window.attachedSheet != nil }
        app.alert = nil
        try await waitUntil { window.attachedSheet == nil }
        app.report("Couldn’t Open “b.tex”", CocoaError(.fileNoSuchFile))
        #expect(app.alert?.title == "Couldn’t Open “b.tex”")
        app.alert = nil
    }

    @Test func sheetsArePresentedFromTheWindowOnHomeAndInAProject() async throws {
        let info = try await newProject()
        let app = defaults.app()
        app.autoCompile = false
        let controller = MainWindowController(app: app)
        app.window = controller
        let window = try #require(controller.window)
        window.orderFront(nil)
        defer { window.close() }
        app.newProjectDraft = NewProjectDraft(template: .article, name: "Draft")
        try await waitUntil { window.attachedSheet != nil }
        app.newProjectDraft = nil
        try await waitUntil { window.attachedSheet == nil }

        await app.open(info.id)
        try await waitUntil { controller.workspace != nil }
        app.prompt = .gotoLine
        try await waitUntil { window.attachedSheet != nil }
        app.prompt = nil
        try await waitUntil { window.attachedSheet == nil }
        #expect(await app.close())
    }

    @Test func findInProjectFocusesTheSearchOnHomeAndInAProject() async throws {
        let info = try await newProject()
        let app = defaults.app()
        app.autoCompile = false
        let controller = MainWindowController(app: app)
        app.window = controller
        let window = try #require(controller.window)
        window.orderFront(nil)
        defer { window.close() }
        try await waitUntil { window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true }
        controller.focusSearch()
        try await waitUntil { window.firstResponder is NSTextView }

        await app.open(info.id)
        try await waitUntil { controller.workspace != nil }
        let sidebar = try #require(controller.workspace?.splitViewItems.first)
        sidebar.isCollapsed = true
        app.perform(.projectSearch, on: app.project)
        try await waitUntil {
            ((window.firstResponder as? NSText)?.delegate as? NSSearchField)?.placeholderString == "Search Project" && !sidebar.isCollapsed
        }
        #expect(await app.close())
    }

    @Test func theToolbarFollowsTheLayoutAndTheColumnsWidthsAtOnceWhileADividerIsDragged() async throws {
        let app = defaults.app()
        let views = WorkspaceViews(project: ProjectModel(id: "P", app: app))
        let workspace = WorkspaceController(app: app, views: views, size: CGSize(width: 1400, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.toolbar = workspace.toolbar.toolbar
        window.layoutIfNeeded()
        defer { workspace.close(); window.close() }
        let format = try #require(workspace.toolbar.toolbar.items.first { $0.itemIdentifier == .format })
        app.layout = .pdf
        try await waitUntil { format.isHidden }
        app.layout = .split
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
