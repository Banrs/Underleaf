import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import TeXLocal

/// One at a time: AppKit keeps toolbars of one identifier alike, so a tool taken out of one window's is out of every window's.
@Suite(.serialized)
struct ShellTests {
    private let defaults = TestDefaults()

    /// Layout preferences stay in the test's own defaults.
    private func workspace(sidebar: Bool = false) async throws -> (NSWindow, WorkspaceController) {
        let app = AppModel(defaults: defaults.store)
        app.sidebarVisible = sidebar
        app.inspectorVisible = false
        app.showPDF = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let workspace = WorkspaceController(app: app, project: ProjectModel(id: "ShellTests", app: app),
                                            size: window.contentLayoutRect.size)
        window.contentViewController = workspace
        window.toolbar = workspace.toolbar.toolbar
        window.contentMinSize = ColumnMetrics.contentMinimum
        window.orderFront(nil)
        try await resize(window, to: 1300)
        return (window, workspace)
    }

    /// Until no view in the window has moved for five turns.
    private func resize(_ window: NSWindow, to width: CGFloat) async throws {
        func frames(_ view: NSView) -> String { "\(view.frame)" + view.subviews.map(frames).joined() }
        let root = try #require(window.contentView?.superview)
        window.setContentSize(NSSize(width: width, height: 600))
        var last = "", quiet = 0
        for _ in 0..<1_000 where quiet < 5 {
            window.layoutIfNeeded()
            let now = frames(root)
            quiet = now == last ? quiet + 1 : 0
            last = now
            await Task.yield()
        }
        guard quiet == 5 else { throw TimedOut(state: "the window's views were still moving at width \(width)") }
    }

    @Test(arguments: [false, true]) func theNativeToolbarSurvivesWindowResizing(sidebar: Bool) async throws {
        let (window, workspace) = try await workspace(sidebar: sidebar)
        defer { workspace.close(); window.close() }
        let toolbar = try #require(window.toolbar)
        workspace.project.tree.show(.sources)
        workspace.project.openPath = "main.tex"
        workspace.project.editor.open(path: "main.tex", text: "A document", focus: false)
        workspace.pdf.show(try textPDF(["A page"]))
        workspace.project.shown = .build(URL(filePath: "/dev/null"))
        let identifiers = toolbar.items.map(\.itemIdentifier)
        #expect(!identifiers.isEmpty)
        for width in [ColumnMetrics.contentMinimum.width, 900, 1300] {
            try await resize(window, to: width)
            if !sidebar { #expect(isClose(window.contentLayoutRect.width, width)) }
            #expect(toolbar.items.map(\.itemIdentifier) == identifiers)
            for item in toolbar.items where [.compile, .layout].contains(item.itemIdentifier) {
                #expect(item.isVisible)
            }
            for pane in workspace.columns.splitViewItems {
                #expect(pane.viewController.view.frame.width >= ColumnMetrics.paneMinimum)
            }
            if width == ColumnMetrics.contentMinimum.width { #expect(workspace.toolbar.compactCompile) }
            if width == 1300 { #expect(!workspace.toolbar.compactCompile) }
        }
        let split = workspace.columns.splitView
        split.setPosition(split.bounds.width - ColumnMetrics.paneMinimum - split.dividerThickness, ofDividerAt: 0)
        window.layoutIfNeeded()
        #expect(workspace.toolbar.compactCompile)
        split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        window.layoutIfNeeded()
        #expect(!workspace.toolbar.compactCompile)
        #expect(workspace.app.sidebarShown == sidebar)
    }

    @Test func switchingLayoutsPreservesTheEditorAndPDF() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let app = workspace.app, editor = workspace.project.editor
        workspace.project.tree.show(.sources)
        workspace.project.openPath = "main.tex"
        editor.open(path: "main.tex", text: "A document with unsaved edits", focus: false)
        try await waitUntil { editor.shown }
        let document = try textPDF(["Page one", "Page two"])
        workspace.pdf.show(document)
        window.makeFirstResponder(editor.textView)
        let source = workspace.columns.splitViewItems[0], pdf = workspace.columns.splitViewItems[1]
        let toolbar = workspace.toolbar.toolbar
        let separator = try #require(toolbar.items.first { $0.itemIdentifier == .pdfSeparator } as? NSTrackingSeparatorToolbarItem)
        #expect(separator.splitView === workspace.columns.splitView && separator.dividerIndex == 0)
        for layout in [WorkspaceLayout.pdf, .source, .split, .pdf, .split] {
            app.layout = layout
            try await waitUntil { source.isCollapsed == !app.showSource && pdf.isCollapsed == !app.showPDF }
            #expect(editor.textView.string == "A document with unsaved edits")
            #expect(workspace.pdf.view.document === document)
            #expect(!source.isCollapsed || !pdf.isCollapsed)
            #expect(separator.isHidden == (layout != .split))
            for item in toolbar.items where [.format, .math, .insert].contains(item.itemIdentifier) {
                #expect(item.isHidden == (layout == .pdf))
            }
            #expect(NSImage(systemSymbolName: layout.symbol, accessibilityDescription: nil) != nil)
            if layout == .pdf { #expect((window.firstResponder as? NSView)?.isDescendant(of: workspace.pdf.view) == true) }
            if layout == .source { #expect(window.firstResponder === editor.textView) }
        }
    }

    @Test func theLayoutMenuSelectsAndRestoresEveryMode() async throws {
        let app = AppModel(defaults: defaults.store)
        let menu = NSHostingMenu(rootView: WorkspaceLayoutPicker(app: app))
        try await waitUntil { menu.update(); return menu.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }.count >= 3 }
        let choices = menu.items.filter { ["Source Only", "Source & PDF", "PDF Only"].contains($0.title) }
        #expect(choices.map(\.title) == ["Source Only", "Source & PDF", "PDF Only"])
        for (index, layout) in [WorkspaceLayout.source, .split, .pdf].enumerated() {
            menu.performActionForItem(at: try #require(menu.items.firstIndex(of: choices[index])))
            #expect(app.layout == layout)
            #expect(AppModel(defaults: defaults.store).layout == layout)
        }
    }

    @Test func legacyDefaultsCannotHideBothPanes() {
        defaults.store.set(false, forKey: DefaultsKey.showSource)
        defaults.store.set(false, forKey: DefaultsKey.showPDF)
        let app = AppModel(defaults: defaults.store)
        #expect(app.showSource && !app.showPDF)
    }

    /// As Xcode's debug area, the build panel is dragged open, resized and dragged shut from the status bar's line: the area's
    /// split takes a press there before the bar does, with the panel shut and open.
    @Test func theStatusBarsLineTakesThePanelsDrag() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        // The area's split: the first stacked one the columns are in.
        let area = try #require(sequence(first: workspace.columns.view, next: \.superview).lazy.compactMap { $0 as? NSSplitView }
            .first { !$0.isVertical })
        let outside = try #require(area.superview)
        func pressed() -> NSView? {
            area.hitTest(outside.convert(NSPoint(x: 400, y: area.arrangedSubviews[0].frame.maxY - BarMetrics.height), from: area))
        }
        #expect(pressed() === area)
        workspace.project.panel.shown = true
        try await waitUntil { !area.isSubviewCollapsed(area.arrangedSubviews[1])
            && area.arrangedSubviews[1].frame.height >= ColumnMetrics.panelMinimum }
        #expect(pressed() === area)
    }

    /// At the document's start the first page meets the toolbar's edge, and it stays there as the window's width changes.
    /// Pages have no top margin, so the page at the edge, a fraction of a point above it as the clip view rounds, is at the start.
    @Test func theFirstPageStaysAtTheToolbarsEdge() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        workspace.project.shown = .build(URL(filePath: "/dev/null"))
        workspace.pdf.show(try textPDF(["a", "b", "c"]))
        let view = workspace.pdf.view
        func under() throws -> CGFloat {
            let page = try #require(view.document?.page(at: 0))
            let top = view.convert(CGPoint(x: 0, y: page.bounds(for: view.displayBox).maxY), from: page).y
            return view.bounds.maxY - view.safeAreaInsets.top - top
        }
        for width: CGFloat in [1300, 1000, 760, 1100, 900, 1240, 820, 1300] {
            try await resize(window, to: width)
            let gap = try under()
            #expect(isClose(gap, 0), "\(gap) pt under the edge at width \(width)")
        }
    }

    /// The File Outline's header is at the files' foot from the first, over an outline folded for a file that has none, and
    /// away only while search results have the sidebar.
    @Test func theOutlineHeaderGoesOnlyForSearchResults() async throws {
        let (window, workspace) = try await workspace(sidebar: true)
        defer { workspace.close(); window.close() }
        let sidebar = try #require(workspace.sidebarItem.viewController as? NSSplitViewController)
        let files = sidebar.splitViewItems[0]
        let header = try #require(files.bottomAlignedAccessoryViewControllers.first)
        #expect(!header.isHidden && sidebar.splitViewItems[1].isCollapsed)
        workspace.project.search.query = "needle"
        try await waitUntil { header.isHidden }
        workspace.project.search.query = ""
        try await waitUntil { !header.isHidden }
        #expect(files.bottomAlignedAccessoryViewControllers == [header] && sidebar.splitViewItems[1].isCollapsed)
    }

    /// A sidebar the window folded is still the user's shown sidebar: it isn't saved as hidden, View offers to show it, and
    /// showing it unfolds it.
    @Test func aFoldedSidebarIsNotAHiddenOne() async throws {
        let (window, workspace) = try await workspace(sidebar: true)
        defer { workspace.close(); window.close() }
        let app = workspace.app, project = workspace.project
        let saved = defaults.saved(DefaultsKey.sidebarVisible) as? Bool
        #expect(app.title(.viewToggleSidebar, on: project) == "Hide Sidebar")
        // Shut by AppKit with no click or drag behind it: as a narrowing window folds it.
        workspace.sidebarItem.isCollapsed = true
        #expect(app.sidebarVisible && app.sidebarFolded && !app.sidebarShown)
        #expect(defaults.saved(DefaultsKey.sidebarVisible) as? Bool == saved)
        #expect(app.title(.viewToggleSidebar, on: project) == "Show Sidebar")
        // The workspace applies a change of the model's once a turn: a fold and a show in one turn would read as no change.
        await settle()
        app.perform(.viewToggleSidebar, on: project)
        try await waitUntil { !workspace.sidebarItem.isCollapsed }
        #expect(app.sidebarShown && !app.sidebarFolded)
        app.perform(.viewToggleSidebar, on: project)
        #expect(!app.sidebarVisible && defaults.saved(DefaultsKey.sidebarVisible) as? Bool == false)
    }

    @Test func theInspectorOpensAndClosesWithoutChangingTheLayout() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let inspector = try #require(workspace.splitViewItems.last)
        workspace.app.layout = .pdf
        workspace.app.inspectorShown = true
        try await waitUntil { !inspector.isCollapsed }
        try await resize(window, to: 1300)
        #expect(!inspector.viewController.view.descendants(of: NSScrollView.self).isEmpty)
        #expect(workspace.app.layout == .pdf)
        workspace.app.inspectorShown = false
        try await waitUntil { inspector.isCollapsed }
        #expect(workspace.app.layout == .pdf)
    }

    /// A project opened over another keeps the other's workspace until it has loaded: the window never shows Home between
    /// them. With no project open, it shows Home.
    @Test func aProjectSwitchNeverShowsHome() {
        let app = AppModel(defaults: defaults.store)
        let first = ProjectModel(id: "ShellTests A", app: app), next = ProjectModel(id: "ShellTests B", app: app)
        app.project = next
        #expect(!next.initialLoadComplete && app.workspaceProject(after: first) === first)
        #expect(app.workspaceProject(after: nil) == nil)
        app.project = nil
        #expect(app.workspaceProject(after: first) == nil)
    }

    /// A PDF command shows the column for now, not for later launches, and reaches the workspace.
    @Test func aPDFRequestShowsTheColumnAndReachesTheWorkspace() {
        let app = AppModel(defaults: defaults.store)
        app.showPDF = false
        var asked = 0
        app.performPDF = { if case .fitWidth = $0 { asked += 1 } }
        app.requestPDF(.fitWidth)
        app.requestPDF(.fitWidth)
        #expect(app.showPDF && asked == 2 && defaults.saved(DefaultsKey.showPDF) == nil)
    }

    /// Hiding the source or the PDF while the other is hidden shows the other, for later launches too.
    @Test func theSourceOrThePDFAlwaysShows() {
        let app = AppModel(defaults: defaults.store)
        app.toggleSource()
        #expect(!app.showSource && app.showPDF)
        app.togglePDF()
        #expect(app.showSource && !app.showPDF)
        app.toggleSource()
        #expect(!app.showSource && app.showPDF)
        let next = AppModel(defaults: defaults.store)
        #expect(!next.showSource && next.showPDF)
    }

    /// On Home, Find focuses the projects' search field.
    @Test func findOnHomeSearchesTheProjects() {
        let app = AppModel(defaults: defaults.store)
        let controller = MainWindowController(app: app)
        defer { controller.window?.close() }
        let find = NSMenuItem(title: "Find…", action: #selector(MainWindowController.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        #expect(controller.validateMenuItem(find))
        controller.performFindPanelAction(find)
        #expect(app.searchFocusToken == 1)
    }

    @Test func aTrackAppliesEachNewValueOnce() async throws {
        let app = AppModel(defaults: defaults.store)
        var all: [Int] = [], later: [Int] = []
        let tracks = [track({ app.searchFocusToken / 2 }) { all.append($0) },
                      track({ app.searchFocusToken / 2 }, initial: false) { later.append($0) }]
        defer { tracks.forEach { $0.cancel() } }
        // Both have read the first value before it changes: the second shows nothing of its own.
        try await waitUntil { all == [0] }
        await settle()
        app.searchFocusToken = 1
        app.searchFocusToken = 2
        try await waitUntil { all == [0, 1] && later == [1] }
        app.searchFocusToken = 3
        await settle()
        #expect(all == [0, 1] && later == [1])
    }
}
