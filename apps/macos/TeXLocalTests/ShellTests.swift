import AppKit
import Testing
@testable import TeXLocal

/// The window's panes and the toolbar over them.
@MainActor
struct ShellTests {
    /// A workspace in a window on screen, the sidebar and the inspector hidden.
    private func workspace(showPDF: Bool) async throws -> (NSWindow, WorkspaceController) {
        let app = AppModel()
        app.sidebarVisible = false
        app.inspectorVisible = false
        app.showPDF = showPDF
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let workspace = WorkspaceController(app: app, project: ProjectModel(id: "ShellTests", app: app),
                                            size: window.contentLayoutRect.size)
        window.contentViewController = workspace
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
        #expect(try item(.compile, in: workspace).title == MenuCommand.compileRun.title)

        // The least a drag of the window's edge gets to.
        #expect(window.contentMinSize.width == ColumnMetrics.toolbarMinimum)
        #expect(ColumnMetrics.toolbarMinimum >= ColumnMetrics.sourceMinimum + ColumnMetrics.pdfMinimum)
        try await resize(window, to: window.contentMinSize.width)
        // Compile as its symbol, still Compile to the overflow menu and VoiceOver.
        let compile = try item(.compile, in: workspace)
        #expect(workspace.toolbar.compactCompile)
        #expect(compile.title.isEmpty && compile.image != nil && compile.label == MenuCommand.compileRun.title)
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
    }

    /// With the PDF hidden the window is no narrower: its toolbar holds it there.
    @Test func theSourceAloneStopsAtTheToolbarsMinimum() async throws {
        let (window, workspace) = try await workspace(showPDF: false)
        defer { workspace.close(); window.close() }
        #expect(window.contentMinSize.width == ColumnMetrics.toolbarMinimum)
        try await resize(window, to: window.contentMinSize.width)
        #expect(workspace.toolbar.compactCompile)
        #expect(try item(.zoom, in: workspace).isHidden)
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
