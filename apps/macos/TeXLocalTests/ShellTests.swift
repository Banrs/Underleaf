import AppKit
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
        window.toolbar = workspace.toolbar.toolbar
        window.orderFront(nil)
        try await resize(window, to: 1300)
        return (window, workspace)
    }

    /// The models reach the panes a turn later, and the panes' frames the toolbar at layout.
    private func resize(_ window: NSWindow, to width: CGFloat) async throws {
        window.setContentSize(NSSize(width: width, height: 600))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
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
        #expect(least == ColumnMetrics.toolbarMinimum)
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
            try await Task.sleep(for: .milliseconds(50))
            #expect(button.fittingSize == idle)
            #expect(compile.label == MenuCommand.compileStop.title)
            #expect(compile.menuFormRepresentation?.title == MenuCommand.compileStop.title)
            #expect(compile.backgroundTintColor == .clear)
            workspace.project.compiling = false
            try await Task.sleep(for: .milliseconds(50))
            #expect(button.fittingSize == idle && compile.backgroundTintColor == nil)
        }
    }

    /// With the PDF hidden the window is no narrower: its toolbar holds it there, and the
    /// workspace leaves the window's minimum as it found it.
    @Test func theSourceAloneStopsAtTheToolbarsMinimum() async throws {
        let (window, workspace) = try await workspace(showPDF: false)
        defer { workspace.close(); window.close() }
        try await resize(window, to: ColumnMetrics.contentMinimum.width)
        #expect(window.contentMinSize == ColumnMetrics.contentMinimum)
        #expect(workspace.toolbar.compactCompile)
        #expect(try item(.zoom, in: workspace).isHidden)
    }

    /// Compile's room is reckoned from the default tools' widths. In a toolbar customised to
    /// others it keeps its word, where the default one has it as its symbol, and AppKit's overflow
    /// menu acts alone; with the default tools back, it is its symbol again.
    @Test func aCustomisedToolbarKeepsCompilesWord() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let toolbar = workspace.toolbar.toolbar
        // Not saved: this host may share the app's saved toolbar.
        toolbar.autosavesConfiguration = false
        let defaults = workspace.toolbar.toolbarDefaultItemIdentifiers(toolbar)
        #expect(workspace.toolbar.holdsDefaultItems)
        try await resize(window, to: ColumnMetrics.contentMinimum.width)
        #expect(workspace.toolbar.compactCompile)

        for id in [NSToolbarItem.Identifier.format, .math, .insert, .zoom] {
            toolbar.removeItem(identifier: id)
        }
        // The toolbar tells the workspace a turn later.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!workspace.toolbar.holdsDefaultItems && !workspace.toolbar.compactCompile)

        toolbar.itemIdentifiers = defaults
        try await Task.sleep(for: .milliseconds(100))
        #expect(workspace.toolbar.holdsDefaultItems && workspace.toolbar.compactCompile)
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
}
