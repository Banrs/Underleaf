import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// The window's panes and the toolbar over them. One at a time: AppKit keeps toolbars of one
/// identifier alike, so a tool taken out of one window's is out of every window's.
@Suite(.serialized)
@MainActor
struct ShellTests {
    /// A workspace in a window on screen, the inspector hidden, and the sidebar unless asked for.
    private func workspace(showPDF: Bool, sidebar: Bool = false) async throws -> (NSWindow, WorkspaceController) {
        let app = AppModel()
        app.sidebarVisible = sidebar
        app.inspectorVisible = false
        app.showPDF = showPDF
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let workspace = WorkspaceController(app: app, project: ProjectModel(id: "ShellTests", app: app),
                                            size: window.contentLayoutRect.size)
        window.contentViewController = workspace
        // As the app's window has them (`MainWindowController`).
        window.contentMinSize = ColumnMetrics.contentMinimum
        // Neither loaded nor saved: this host shares the app's saved toolbar, and Compile's form
        // goes by which tools the toolbar holds.
        workspace.toolbar.toolbar.autosavesConfiguration = false
        window.toolbar = workspace.toolbar.toolbar
        window.orderFront(nil)
        try await resize(window, to: 1300)
        return (window, workspace)
    }

    /// The models reach the panes a turn later, and the panes' frames the toolbar at layout: it
    /// waits, a turn at a time, until no view in the window has moved for a few.
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

    /// A wide window has Compile as its word. At its narrowest the panes are at their least
    /// or wider, Compile is its symbol, and nothing has left the toolbar but for its overflow
    /// menu, where each tool that can go has a menu form.
    @Test func aNarrowWindowKeepsEveryToolOrItsMenuForm() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        #expect(!workspace.toolbar.compactCompile)
        let compile = try item(.compile, in: workspace)
        let button = try #require(compile.view)
        let word = button.fittingSize.width
        #expect(word > 60)

        // The least a drag of the window's edge gets to: the toolbar's, which the panes' own
        // (with their divider, at most a point) fit in, so they don't hold the window wider.
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
        // The tools Customize Toolbar can add are among the first to go.
        for id in [NSToolbarItem.Identifier.undo, .redo, .bold, .italic, .underline, .share] {
            let added = workspace.toolbar.toolbar(workspace.toolbar.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false)
            #expect(added?.visibilityPriority == .low, "\(id.rawValue)")
        }

        try await resize(window, to: 1300)
        #expect(!workspace.toolbar.compactCompile)
        #expect(button.fittingSize.width == word)
    }

    /// Stop, with the build's spinner, is as wide as Compile was, as its word and as its symbol:
    /// the tools beside it stay where they are as a build starts and ends. The overflow menu and
    /// VoiceOver have Stop by name.
    @Test func stopIsAsWideAsCompile() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let compile = try item(.compile, in: workspace)
        let button = try #require(compile.view)
        for width in [1300, ColumnMetrics.contentMinimum.width] {
            try await resize(window, to: width)
            let idle = button.fittingSize
            workspace.project.compiling = true
            try await waitUntil { compile.label == MenuCommand.compileStop.title }
            #expect(button.fittingSize == idle)
            #expect(compile.label == MenuCommand.compileStop.title)
            #expect(compile.menuFormRepresentation?.title == MenuCommand.compileStop.title)
            #expect(compile.backgroundTintColor == .clear)
            workspace.project.compiling = false
            try await waitUntil { compile.label == MenuCommand.compileRun.title }
            #expect(button.fittingSize == idle && compile.backgroundTintColor == nil)
        }
    }

    /// With the PDF hidden the window is no narrower: its toolbar holds it there.
    @Test func theSourceAloneStopsAtTheToolbarsMinimum() async throws {
        let (window, workspace) = try await workspace(showPDF: false)
        defer { workspace.close(); window.close() }
        try await resize(window, to: ColumnMetrics.contentMinimum.width)
        #expect(workspace.toolbar.compactCompile)
        #expect(try item(.zoom, in: workspace).isHidden)
    }

    /// The PDF toggle's help tag says which it will do, as View's item, and Zoom goes with the column.
    @Test func thePDFTogglesHelpSaysWhichItWillDo() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let toggle = try item(.togglePDF, in: workspace), zoom = try item(.zoom, in: workspace)
        #expect(toggle.toolTip == "Hide PDF" && !zoom.isHidden)
        workspace.app.showPDF = false
        try await waitUntil { toggle.toolTip == "Show PDF" }
        #expect(zoom.isHidden)
    }

    /// Compile's room is reckoned from the default tools' widths. In a toolbar customised to
    /// others it keeps its word, where the default one has it as its symbol, and AppKit's overflow
    /// menu acts alone, until the window is too narrow for the word beside the tools that never
    /// leave. With the default tools back, it is its symbol again.
    @Test func aCustomisedToolbarKeepsCompilesWord() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let toolbar = workspace.toolbar.toolbar
        let defaults = workspace.toolbar.toolbarDefaultItemIdentifiers(toolbar)
        #expect(workspace.toolbar.holdsDefaultItems)
        // Too narrow for the default tools and Compile's word, wide enough for the word alone.
        try await resize(window, to: 700)
        #expect(workspace.toolbar.compactCompile)

        for id in [NSToolbarItem.Identifier.format, .math, .insert, .zoom] {
            toolbar.removeItem(identifier: id)
        }
        // The toolbar tells the workspace a turn later.
        try await waitUntil { !workspace.toolbar.holdsDefaultItems && !workspace.toolbar.compactCompile }
        // At the window's least AppKit would take Compile itself to its menu, whatever the tools.
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

    /// A divider dragged near where it opened stops there: the sidebar at its opening width, source
    /// and PDF at the split a double-click on their divider restores. Out of reach, it goes where
    /// it is dragged, and a hidden sidebar has nowhere to stop.
    @Test func aDividerStopsWhereItOpened() async throws {
        let (window, workspace) = try await workspace(showPDF: true, sidebar: true)
        defer { workspace.close(); window.close() }
        let split = workspace.splitView, opening = ColumnMetrics.sidebarIdeal, reach = ColumnMetrics.detentReach
        func sidebar(_ position: CGFloat) -> CGFloat {
            workspace.splitView(split, constrainSplitPosition: position, ofSubviewAt: 0)
        }
        #expect(sidebar(opening + 3) == opening && sidebar(opening - reach) == opening)
        #expect(sidebar(opening + reach + 1) == opening + reach + 1)
        workspace.sidebarItem.isCollapsed = true
        #expect(sidebar(opening + 3) == opening + 3)

        let columns = workspace.columns, even = ((columns.splitView.bounds.width - columns.splitView.dividerThickness) / 2).rounded()
        func divider(_ position: CGFloat) -> CGFloat {
            columns.splitView(columns.splitView, constrainSplitPosition: position, ofSubviewAt: 0)
        }
        #expect(divider(even - 5) == even && divider(even + 40) == even + 40)
    }

    /// The source|PDF divider stands under the toolbar's separator from the widest window to the
    /// narrowest, sidebar open or shut: where a section's tools stop the separator, the divider
    /// goes to it (`joinDivider`).
    @Test(arguments: [false, true])
    func theDividerStaysUnderTheToolbarsSeparator(sidebar: Bool) async throws {
        let (window, workspace) = try await workspace(showPDF: true, sidebar: sidebar)
        defer { workspace.close(); window.close() }
        let split = workspace.columns.splitView
        func separators(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { ($0.className == "NSSeparatorToolbarItemView" ? [$0] : []) + separators($0) }
        }
        let frame = try #require(window.contentView?.superview)
        func lines() -> [CGFloat] { separators(frame).map { split.convert($0.bounds, from: $0).minX } }
        func divider() -> CGFloat { split.arrangedSubviews[0].frame.maxX }
        for width in [1300, 900, 700, ColumnMetrics.contentMinimum.width] {
            try await resize(window, to: width)
            try await waitUntil({ lines().contains { isClose($0, divider()) } }) {
                "width \(width): divider at \(divider()), lines at \(lines())"
            }
        }
    }

    /// The File Outline's header is at the files' foot from the first, over an outline folded for
    /// a file that has none, and away only while search results have the sidebar.
    @Test func theOutlineHeaderGoesOnlyForSearchResults() async throws {
        let (window, workspace) = try await workspace(showPDF: true, sidebar: true)
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

    /// A sidebar the window folded is still the user's shown sidebar: it isn't saved as hidden,
    /// View offers to show it, and showing it unfolds it.
    @Test func aFoldedSidebarIsNotAHiddenOne() {
        let app = AppModel()
        let project = ProjectModel(id: "ShellTests", app: app)
        app.sidebarVisible = true
        app.sidebarFolded = true
        #expect(app.sidebarVisible && !app.sidebarShown)
        #expect(UserDefaults.standard.bool(forKey: DefaultsKey.sidebarVisible))
        #expect(app.title(.viewToggleSidebar, on: project) == "Show Sidebar")
        app.perform(.viewToggleSidebar, on: project)
        #expect(app.sidebarShown && !app.sidebarFolded)
        app.perform(.viewToggleSidebar, on: project)
        #expect(!app.sidebarVisible && !UserDefaults.standard.bool(forKey: DefaultsKey.sidebarVisible))
        app.sidebarVisible = true
    }

    /// A menu's PDF action shows the column and goes to the workspace at once.
    @Test func aPDFRequestShowsTheColumnAndReachesTheWorkspace() {
        let app = AppModel()
        app.showPDF = false
        var asked = 0
        app.performPDF = { if case .fitWidth = $0 { asked += 1 } }
        app.requestPDF(.fitWidth)
        app.requestPDF(.fitWidth)
        #expect(app.showPDF && asked == 2)
    }

    /// A track applies each new value once, not a change that leaves the value as it was, and
    /// the first only where it is asked for.
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

    /// A space typed at the end of a new project's name moves the name at once, and a name
    /// longer than its row scrolls in the row, beside its label and inside the sheet.
    @Test func aNewProjectsNameShowsASpaceTypedAtItsEnd() async throws {
        let sheet = NSHostingView(rootView: NewProjectSheet(template: .article, taken: []).environment(AppModel()))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: sheet.fittingSize), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sheet
        func field(_ view: NSView) -> NSTextField? {
            (view as? NSTextField).flatMap { $0.isEditable ? $0 : nil } ?? view.subviews.lazy.compactMap(field).first
        }
        try await waitUntil { field(sheet) != nil }
        let name = try #require(field(sheet))
        window.makeFirstResponder(name)
        let editor = try #require(name.currentEditor() as? NSTextView)
        /// Where the name starts, in the window.
        func start() -> CGFloat {
            sheet.layoutSubtreeIfNeeded()
            return window.convertFromScreen(editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)).minX
        }
        let untitled = start()
        editor.insertText(" ", replacementRange: NSRange(location: 8, length: 0))
        try await waitUntil { start() < untitled - 2 }
        editor.insertText(String(repeating: "m", count: 80), replacementRange: editor.selectedRange())
        try await waitUntil { name.frame.width > 150 }
        // Under its label, the field would start at the row's leading edge.
        let long = name.convert(name.bounds, to: sheet)
        #expect(sheet.bounds.contains(long) && long.minX > sheet.bounds.width / 3)
    }
}
