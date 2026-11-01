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
        let controller = HomeWindowController(app: defaults.app())
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

    @Test func sheetsArePresentedFromTheProjectsWindowAndAProjectWindow() async throws {
        let info = try await newProject()
        let app = windowedApp()
        let home = app.showHome()
        let homeWindow = try #require(window(of: home))
        home.newProjectDraft = NewProjectDraft(template: .article, name: "Draft")
        try await waitUntil { homeWindow.attachedSheet != nil }
        home.newProjectDraft = nil
        try await waitUntil { homeWindow.attachedSheet == nil }

        await home.open(info.id)
        let model = try #require(app.window(showing: info.id)), window = try #require(window(of: model))
        model.prompt = .gotoLine
        try await waitUntil { window.attachedSheet != nil }
        model.prompt = nil
        try await waitUntil { window.attachedSheet == nil }
        await close(app)
    }

    @Test func findFocusesTheSearchInTheProjectsWindowAndInAProject() async throws {
        let info = try await newProject()
        let app = windowedApp()
        let home = app.showHome()
        let homeWindow = try #require(window(of: home))
        try await waitUntil { homeWindow.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true }
        home.controller?.focusSearch()
        try await waitUntil { homeWindow.firstResponder is NSTextView }

        await home.open(info.id)
        let model = try #require(app.window(showing: info.id)), window = try #require(window(of: model))
        let sidebar = try #require((model.controller as? MainWindowController)?.workspace?.splitViewItems.first)
        sidebar.isCollapsed = true
        model.perform(.projectSearch, on: model.project)
        try await waitUntil {
            ((window.firstResponder as? NSText)?.delegate as? NSSearchField)?.placeholderString == "Search Project" && !sidebar.isCollapsed
        }
        await close(app)
    }

    @Test func eachProjectOpensInAWindowOfItsOwnThatNeverTabsAndOpeningItAgainBringsItForward() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let app = windowedApp()
        let home = app.showHome()
        let homeWindow = try #require(window(of: home))
        #expect(homeWindow.isVisible && homeWindow.tabbingMode == .disallowed && homeWindow.isExcludedFromWindowsMenu && !homeWindow.isRestorable)
        await home.open(first.id)
        #expect(!homeWindow.isVisible && app.home == nil)
        let one = try #require(app.window(showing: first.id))
        let screen = try #require(window(of: one)?.screen?.visibleFrame)
        window(of: one)?.setFrame(NSRect(x: screen.minX, y: screen.maxY - 600, width: 800, height: 600), display: false)
        await one.open(second.id)
        let two = try #require(app.window(showing: second.id))
        let windows = try [one, two].map { try #require(window(of: $0)) }
        #expect(app.windows.count == 2 && windows.allSatisfy { $0.isVisible && $0.tabbingMode == .disallowed && $0.tabbedWindows == nil })
        #expect(windows.map(\.title) == [first.name, second.name] && windows.allSatisfy { $0.subtitle == "main.tex" })
        #expect(windows[1].frame.minX > windows[0].frame.minX && windows[1].frame.maxY < windows[0].frame.maxY)
        #expect(windows[1].orderedIndex < windows[0].orderedIndex)
        await two.open(first.id)
        #expect(app.windows.count == 2 && windows[0].orderedIndex < windows[1].orderedIndex)

        let items = NSApp.mainMenu?.items.flatMap { $0.submenu.map(Self.items) ?? [] } ?? []
        let tabs = [#selector(NSWindow.mergeAllWindows(_:)), #selector(NSWindow.moveTabToNewWindow(_:)), #selector(NSWindow.toggleTabBar(_:)),
                    #selector(NSWindow.toggleTabOverview(_:)), #selector(NSWindow.selectNextTab(_:)), #selector(NSWindow.selectPreviousTab(_:)),
                    #selector(NSResponder.newWindowForTab(_:))]
        #expect(!NSWindow.allowsAutomaticWindowTabbing && !items.contains { $0.action.map(tabs.contains) == true || $0.title == "New Tab" })
        let projects = try #require(items.first { $0.title == "Projects" })
        #expect(projects.keyEquivalent == "1" && projects.keyEquivalentModifierMask == [.command, .shift])
        await close(app)
    }

    @Test func aProjectsWindowReopensWithTheFrameItWasLeftWith() async throws {
        let project = try await newProject()
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame Project \(project.id)") }
        let app = windowedApp()
        await app.showHome().open(project.id)
        let screen = try #require(window(of: app.window(showing: project.id))?.screen?.visibleFrame)
        let left = NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 800, height: 560)
        window(of: app.window(showing: project.id))?.setFrame(left, display: false)
        await close(app)
        await app.showHome().open(project.id)
        #expect(window(of: app.window(showing: project.id))?.frame == left)
        await close(app)
    }

    @Test func theProjectsWindowIsSingleAndShowsWhenTheLastProjectWindowClosesOrAProjectCloses() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let app = windowedApp()
        let home = app.showHome()
        #expect(app.showHome() === home && app.windows.count == 1)
        await home.open(first.id)
        await app.front.open(second.id)
        let (one, two) = (try #require(app.window(showing: first.id)), try #require(app.window(showing: second.id)))
        #expect(app.home == nil)
        two.perform(.projectClose, on: two.project)
        try await waitUntil { app.home != nil }
        #expect(two.project?.closed == true && app.windows.count == 2 && window(of: app.home)?.isVisible == true)
        app.home?.controller?.close()
        #expect(app.home == nil)
        #expect(await one.close())
        let again = try #require(app.home)
        #expect(app.windows.count == 1 && window(of: again)?.isVisible == true)

        await again.open("No Such Project")
        #expect(app.windows.count == 1 && app.home === again && again.alert?.title == "Couldn’t Open “No Such Project”")
        await close(app)
    }

    @Test func closingAWindowSavesAndClosesItsProjectAndARestoredOneOpensItAgain() async throws {
        let info = try await newProject()
        let app = windowedApp()
        await app.showHome().open(info.id)
        let controller = try #require(app.window(showing: info.id)?.controller as? MainWindowController)
        let (window, project) = (try #require(controller.window), try #require(controller.model.project))
        let document = try #require(SourceDocument(session: project.session, path: "main.tex"))
        _ = document.edit(NSRange(location: 0, length: 0), with: "% kept\n", changing: nil, mirroring: false)
        let state = NSKeyedArchiver(requiringSecureCoding: true)
        controller.window(window, willEncodeRestorableState: state)
        window.performClose(nil)
        try await waitUntil { !window.isVisible }
        #expect(project.closed && app.windows.count == 1 && app.home != nil)
        #expect(try String(contentsOfFile: info.path + "/main.tex", encoding: .utf8).hasPrefix("% kept\n"))
        await close(app)

        func restore(_ data: Data) throws -> MainWindowController? {
            var restored: NSWindow?
            MainWindowController.restoreWindow(withIdentifier: MainWindowController.identifier,
                                               state: try NSKeyedUnarchiver(forReadingFrom: data)) { window, _ in restored = window }
            return restored?.windowController as? MainWindowController
        }
        #expect(try restore(NSKeyedArchiver(requiringSecureCoding: true).encodedData) == nil)
        let again = try #require(try restore(state.encodedData))
        await again.model.reopen()
        #expect(again.model.project?.id == info.id && again.model.project?.isOpen == true)
        try await waitUntil { again.workspace != nil }
        #expect(await again.model.close())

        let missing = NSKeyedArchiver(requiringSecureCoding: true)
        missing.encode("No Such Project" as NSString, forKey: "project")
        let gone = try #require(try restore(missing.encodedData)).model
        #expect(await gone.project?.saveBeforeLeaving() == true)
        await gone.reopen()
        #expect(gone.project?.closed == true && !gone.app.windows.contains { $0 === gone } && gone.alert == nil)
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
        #expect(workspace.toolbar.toolbar.items.allSatisfy { !$0.isNavigational })
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
        #expect(!columns.dragging)
        window.orderFront(nil)
        func mouse(_ type: NSEvent.EventType, at x: CGFloat) throws {
            let point = columns.convert(NSPoint(x: x, y: columns.bounds.midY), to: nil)
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                             pressure: type == .leftMouseUp ? 0 : 1)))
            window.layoutIfNeeded()
        }
        let divider = columns.arrangedSubviews[0].frame.maxX + columns.dividerThickness / 2
        try mouse(.leftMouseDown, at: divider)
        try mouse(.leftMouseDragged, at: divider + 20)
        try mouse(.leftMouseDragged, at: columns.bounds.width)
        #expect(columns.dragging && workspace.toolbar.compactCompile)
        workspace.quiet(true)
        try mouse(.leftMouseDragged, at: ColumnMetrics.paneMinimum + 20)
        #expect(workspace.toolbar.compactCompile)
        workspace.quiet(false)
        try mouse(.leftMouseDragged, at: ColumnMetrics.paneMinimum + 10)
        try await waitUntil(timeout: .seconds(1)) { !workspace.toolbar.compactCompile }
        #expect(columns.dragging)
        try mouse(.leftMouseUp, at: ColumnMetrics.paneMinimum + 10)
        try await waitUntil { !columns.dragging }
    }

    @Test func aSplitViewKeepsItsGestureRecognizers() {
        for split in [ColumnsSplitView(), DraggedSplitView()] { #expect(!split.gestureRecognizers.isEmpty) }
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

    private func windowedApp() -> AppModel {
        let app = defaults.app()
        app.autoCompile = false
        app.newWindow = { [app] id in id.map { MainWindowController(app: app, project: $0).model } ?? HomeWindowController(app: app).model }
        return app
    }

    private func window(of model: WindowModel?) -> NSWindow? { (model?.controller as? NSWindowController)?.window }

    private func close(_ app: AppModel) async {
        for model in app.windows where model.project != nil { #expect(await model.close()) }
        app.home?.controller?.close()
    }

    private static func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
}
