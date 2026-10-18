import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// One at a time: AppKit keeps toolbars of one identifier alike, so a tool taken out of one window's is out of every window's.
@Suite(.serialized)
struct ShellTests {
    /// A workspace with the PDF shown, in a window at its widest.
    private func workspace(sidebar: Bool = false) async throws -> (NSWindow, WorkspaceController) {
        let app = AppModel()
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
        window.contentMinSize = ColumnMetrics.contentMinimum
        // Neither loaded nor saved: this host shares the app's saved toolbar.
        workspace.toolbar.toolbar.autosavesConfiguration = false
        window.toolbar = workspace.toolbar.toolbar
        window.orderFront(nil)
        try await resize(window, to: 1300)
        return (window, workspace)
    }

    /// Waits, a turn at a time, until no view in the window has moved for a few.
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

    private func item(_ id: NSToolbarItem.Identifier, in workspace: WorkspaceController) throws -> NSToolbarItem {
        try #require(workspace.toolbar.toolbar.items.first { $0.itemIdentifier == id })
    }

    /// A wide window has Compile as its word. At its narrowest the panes are at their least or wider, Compile is its
    /// symbol, and nothing has left the toolbar but for its overflow menu, where each tool that can go has a menu form.
    @Test func aNarrowWindowKeepsEveryToolOrItsMenuForm() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        #expect(!workspace.toolbar.compactCompile)
        let compile = try item(.compile, in: workspace)
        let button = try #require(compile.view)
        let word = button.fittingSize.width
        #expect(word > 60 && compile.style == .prominent)
        let least = ColumnMetrics.contentMinimum.width
        #expect(least >= ColumnMetrics.sourceMinimum + 1 + ColumnMetrics.pdfMinimum + ColumnMetrics.toolbarInset)
        try await resize(window, to: least)
        #expect(window.contentView?.frame.width == least)
        // Compile as its symbol, a circle, still Compile to the overflow menu and VoiceOver.
        #expect(workspace.toolbar.compactCompile)
        #expect(button.fittingSize == NSSize(width: 36, height: 36))
        #expect(compile.label == MenuCommand.compileRun.title)
        #expect(compile.menuFormRepresentation?.title == MenuCommand.compileRun.title)
        for id in [NSToolbarItem.Identifier.format, .math, .insert, .zoom] {
            let item = try item(id, in: workspace)
            #expect(!item.isHidden && item.visibilityPriority == .low)
            #expect(item is NSMenuToolbarItem || item.menuFormRepresentation?.submenu != nil)
        }
        for id in [NSToolbarItem.Identifier.back, .compile, .togglePDF] {
            #expect(try item(id, in: workspace).visibilityPriority == .high)
        }
        try await resize(window, to: 1300)
        #expect(!workspace.toolbar.compactCompile)
        #expect(button.fittingSize.width == word)
    }

    /// Stop, with the build's spinner, is as wide as Compile was, as its word and as its symbol: the tools beside it stay
    /// where they are as a build starts and ends. The overflow menu and VoiceOver have Stop by name.
    @Test func stopIsAsWideAsCompile() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let compile = try item(.compile, in: workspace)
        let button = try #require(compile.view)
        for width in [1300, ColumnMetrics.contentMinimum.width] {
            try await resize(window, to: width)
            let idle = button.fittingSize
            workspace.project.compiling = true
            try await waitUntil { compile.label == MenuCommand.compileStop.title }
            #expect(button.fittingSize == idle)
            #expect(compile.menuFormRepresentation?.title == MenuCommand.compileStop.title)
            #expect(compile.backgroundTintColor == .clear)
            workspace.project.compiling = false
            try await waitUntil { compile.label == MenuCommand.compileRun.title }
            #expect(button.fittingSize == idle && compile.backgroundTintColor == nil)
        }
    }

    /// Compile's room is reckoned from the default tools' widths. In a toolbar customised to others it keeps its word,
    /// where the default one has it as its symbol, until the window is too narrow for the word beside the tools that
    /// never leave. With the default tools back, it is its symbol again.
    @Test func aCustomisedToolbarKeepsCompilesWord() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let toolbar = workspace.toolbar.toolbar
        let defaults = workspace.toolbar.toolbarDefaultItemIdentifiers(toolbar)
        #expect(workspace.toolbar.holdsDefaultItems)
        // Too narrow for the default tools and Compile's word, wide enough for the word alone.
        try await resize(window, to: 700)
        #expect(workspace.toolbar.compactCompile)
        for id in [NSToolbarItem.Identifier.format, .math, .insert, .zoom] { toolbar.removeItem(identifier: id) }
        // The toolbar tells the workspace a turn later.
        try await waitUntil { !workspace.toolbar.holdsDefaultItems && !workspace.toolbar.compactCompile }
        try await resize(window, to: ColumnMetrics.contentMinimum.width)
        #expect(workspace.toolbar.compactCompile)
        #expect(toolbar.visibleItems?.contains { $0.itemIdentifier == .compile } == true)
        try await resize(window, to: 700)
        #expect(!workspace.toolbar.compactCompile)
        toolbar.itemIdentifiers = defaults
        try await waitUntil { workspace.toolbar.holdsDefaultItems && workspace.toolbar.compactCompile }
        // Spaces are not tools: without them the toolbar still holds its default ones.
        toolbar.removeItem(identifier: .flexibleSpace)
        #expect(workspace.toolbar.holdsDefaultItems)
        toolbar.itemIdentifiers = defaults
    }

    /// The source|PDF divider stands under the toolbar's separator from the widest window to the narrowest, sidebar open
    /// or shut: where a section's tools stop the separator, the divider goes to it (`joinDivider`).
    @Test(arguments: [false, true])
    func theDividerStaysUnderTheToolbarsSeparator(sidebar: Bool) async throws {
        let (window, workspace) = try await workspace(sidebar: sidebar)
        defer { workspace.close(); window.close() }
        let split = workspace.columns.splitView
        let frame = try #require(window.contentView?.superview)
        func lines() -> [CGFloat] { frame.descendants(named: "NSSeparatorToolbarItemView").map { split.convert($0.bounds, from: $0).minX } }
        func divider() -> CGFloat { split.arrangedSubviews[0].frame.maxX }
        for width in [1300, 900, 700, ColumnMetrics.contentMinimum.width] {
            try await resize(window, to: width)
            try await waitUntil({ lines().contains { isClose($0, divider()) } }) {
                "width \(width): divider at \(divider()), lines at \(lines())"
            }
        }
    }

    /// Aa opens Notes' popover; its overflow form is a menu of the styles and the class's levels by name, as the menu
    /// bar's Section Level, while the popover numbers them as the class does ("1.1" for a subsection).
    @Test func formatIsAPopoverWithAMenuForm() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let format = try item(.format, in: workspace)
        #expect(!(format is NSMenuToolbarItem) && format.action != nil)
        let menu = try #require(format.menuFormRepresentation?.submenu)
        let headings = workspace.project.headingStyles
        let titles = [MenuCommand.editBold, .editItalic, .editUnderline].map(\.title) + headings.map(\.title)
        try await waitUntil {
            menu.update()
            return menu.items.filter { !$0.isSeparatorItem }.map(\.title) == titles
        }
        #expect(headings.contains { $0.marker == "1.1" })
        let layout = FormatPanel.Layout(headings)
        #expect(layout.markers > 0 && layout.pitch >= 24)
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
        defer { workspace.close(); window.close(); workspace.app.sidebarVisible = true }
        let app = workspace.app, project = workspace.project
        #expect(app.title(.viewToggleSidebar, on: project) == "Hide Sidebar")
        // Shut by AppKit, not by a drag: as a narrowing window folds it.
        workspace.sidebarItem.isCollapsed = true
        #expect(app.sidebarVisible && app.sidebarFolded && !app.sidebarShown)
        #expect(UserDefaults.standard.bool(forKey: DefaultsKey.sidebarVisible))
        #expect(app.title(.viewToggleSidebar, on: project) == "Show Sidebar")
        // The workspace applies a change of the model's once a turn: a fold and a show in one turn would read as no change.
        await settle()
        app.perform(.viewToggleSidebar, on: project)
        try await waitUntil { !workspace.sidebarItem.isCollapsed }
        #expect(app.sidebarShown && !app.sidebarFolded)
        app.perform(.viewToggleSidebar, on: project)
        #expect(!app.sidebarVisible && !UserDefaults.standard.bool(forKey: DefaultsKey.sidebarVisible))
    }

    @Test func aPDFRequestShowsTheColumnAndReachesTheWorkspace() {
        let app = AppModel()
        app.showPDF = false
        var asked = 0
        app.performPDF = { if case .fitWidth = $0 { asked += 1 } }
        app.requestPDF(.fitWidth)
        app.requestPDF(.fitWidth)
        #expect(app.showPDF && asked == 2)
    }

    @Test func aTrackAppliesEachNewValueOnce() async throws {
        let app = AppModel()
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
