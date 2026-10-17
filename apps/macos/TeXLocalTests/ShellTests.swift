import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// One at a time: AppKit keeps toolbars of one identifier alike, so a tool taken out of one window's is out of every window's.
@Suite(.serialized)
struct ShellTests {
    private let defaults = TestDefaults()

    /// With a model on the test's own defaults, which saves neither the splits nor the toolbar (`AppModel.savesLayout`).
    private func workspace(sidebar: Bool = false) async throws -> (NSWindow, WorkspaceController) {
        let app = AppModel(defaults: defaults.store)
        app.sidebarVisible = sidebar
        app.inspectorVisible = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let workspace = WorkspaceController(app: app, project: ProjectModel(id: "ShellTests", app: app),
                                            size: window.contentLayoutRect.size)
        window.contentViewController = workspace
        window.toolbar = workspace.toolbar.toolbar
        window.orderFront(nil)
        try await resize(window, to: 1300)
        return (window, workspace)
    }

    /// Waits, a turn at a time, until no view in the window has moved for a few.
    private func resize(_ window: NSWindow, to width: CGFloat) async throws {
        func frames(_ view: NSView) -> String {
            "\(view.frame)" + view.subviews.map(frames).joined()
        }
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

    /// A wide window has Compile as its word. Narrower, it is its symbol's circle, never a capsule between the two, and
    /// still Compile to the overflow menu and VoiceOver; the narrowest keeps the panes at their least, and nothing has left
    /// the toolbar but for its overflow menu, where each tool that can go has a menu form. Wide again, it is the word.
    @Test func aNarrowWindowKeepsEveryToolOrItsMenuForm() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let compile = try item(.compile, in: workspace)
        let button = try #require(compile.view)
        let word = button.frame.width
        #expect(word > 60 && compile.style == .prominent)
        var symbol = false
        for width in stride(from: 1200, through: 300, by: -50) as StrideThrough<CGFloat> {
            try await resize(window, to: width)
            guard workspace.toolbar.toolbar.visibleItems?.contains(compile) == true else { continue }
            #expect(button.frame.width == word || button.frame.width == 36, "\(button.frame.width) at \(width)")
            symbol = symbol || button.frame.width == 36
        }
        #expect(symbol)
        let panes = workspace.columns.splitView.arrangedSubviews.map(\.frame.width)
        #expect(panes.count == 2 && panes[0] >= ColumnMetrics.sourceMinimum && panes[1] >= ColumnMetrics.pdfMinimum)
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
        #expect(button.frame.width == word)
    }

    /// Stop, with the build's spinner, is as wide as Compile was, as its word and as its symbol: the tools beside it stay
    /// where they are as a build starts and ends. The overflow menu and VoiceOver have Stop by name.
    @Test func stopIsAsWideAsCompile() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let compile = try item(.compile, in: workspace)
        let button = try #require(compile.view)
        for width in [1300, 300] as [CGFloat] {
            try await resize(window, to: width)
            let idle = button.frame.size
            workspace.project.compiling = true
            try await waitUntil { compile.label == MenuCommand.compileStop.title }
            window.layoutIfNeeded()
            #expect(button.frame.size == idle)
            #expect(compile.menuFormRepresentation?.title == MenuCommand.compileStop.title)
            #expect(compile.backgroundTintColor == .clear)
            workspace.project.compiling = false
            try await waitUntil { compile.label == MenuCommand.compileRun.title }
            window.layoutIfNeeded()
            #expect(button.frame.size == idle && compile.backgroundTintColor == nil)
        }
    }

    /// The source|PDF divider stands under the toolbar's separator, sidebar open or shut.
    @Test(arguments: [false, true])
    func theDividerStaysUnderTheToolbarsSeparator(sidebar: Bool) async throws {
        let (window, workspace) = try await workspace(sidebar: sidebar)
        defer { workspace.close(); window.close() }
        let split = workspace.columns.splitView
        let frame = try #require(window.contentView?.superview)
        // AppKit's own view for the separator (27.2), which a test may look for by its class.
        func separators(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { ($0.className == "NSSeparatorToolbarItemView" ? [$0] : []) + separators($0) }
        }
        func lines() -> [CGFloat] { separators(frame).map { split.convert($0.bounds, from: $0).minX } }
        func divider() -> CGFloat { split.arrangedSubviews[0].frame.maxX }
        try await waitUntil({ lines().contains { isClose($0, divider()) } }) {
            "divider at \(divider()), lines at \(lines())"
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
        #expect(layout.markers > 0 && headings.allSatisfy { layout.height($0) >= FormatPanel.item })
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

    /// Shut otherwise, with a click or a drag on its divider, a side column is hidden and saved so; the window widening
    /// brings back one it folded.
    @Test func aSideColumnShutByTheUserIsHidden() {
        let app = AppModel(defaults: defaults.store)
        app.inspectorVisible = true
        app.sideColumn(.sidebar, shown: false, byWindow: true)
        app.sideColumn(.sidebar, shown: true, byWindow: true)
        #expect(app.sidebarShown && !app.sidebarFolded)
        app.sideColumn(.sidebar, shown: false, byWindow: false)
        app.sideColumn(.inspector, shown: false, byWindow: false)
        #expect(!app.sidebarVisible && !app.sidebarFolded && !app.inspectorVisible && !app.inspectorFolded)
        #expect(defaults.saved(DefaultsKey.sidebarVisible) as? Bool == false
                && defaults.saved(DefaultsKey.inspectorVisible) as? Bool == false)
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

    /// What the tests set goes to their own defaults, not the user's.
    @Test func theModelsSettingsGoWhereTheyAreKept() {
        let user = UserDefaults.standard.object(forKey: DefaultsKey.showWordCount) as? Bool
        let app = AppModel(defaults: defaults.store)
        app.showWordCount = false
        #expect(!app.savesLayout && defaults.saved(DefaultsKey.showWordCount) as? Bool == false)
        #expect(UserDefaults.standard.object(forKey: DefaultsKey.showWordCount) as? Bool == user)
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
