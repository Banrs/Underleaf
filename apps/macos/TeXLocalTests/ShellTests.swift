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

    /// A wide window shows every tool; at its narrowest Insert stands for Format and Math and
    /// Zoom has gone, Compile keeping its word; widened again, they are all back.
    @Test func theToolbarGivesWayToANarrowWindowAndTakesItBack() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let fit = workspace.toolbar.fit
        #expect(!fit.mergesEditing && !fit.compactCompile && !fit.hidesZoom)
        #expect(try item(.compile, in: workspace).title == MenuCommand.compileRun.title)

        try await resize(window, to: 100)
        let narrowest = ColumnMetrics.sourceMinimum(sidebarHidden: true, pdfHidden: false) + ColumnMetrics.pdfMinimum
        #expect(abs(window.contentLayoutRect.width - narrowest) < 2)
        #expect(fit.mergesEditing && !fit.compactCompile && fit.hidesZoom)
        #expect(try item(.format, in: workspace).isHidden && item(.math, in: workspace).isHidden)
        #expect(try !item(.insert, in: workspace).isHidden)
        let insert = try #require(try item(.insert, in: workspace) as? NSMenuToolbarItem).menu
        insert.delegate?.menuNeedsUpdate?(insert)
        #expect(insert.items.prefix(2).map(\.title) == ["Format", "Math"])
        #expect(insert.items.prefix(2).allSatisfy { $0.submenu?.items.isEmpty == false })
        #expect(try item(.zoom, in: workspace).isHidden)
        #expect(try item(.compile, in: workspace).title == MenuCommand.compileRun.title)

        try await resize(window, to: 1300)
        #expect(!fit.mergesEditing && !fit.compactCompile && !fit.hidesZoom)
        #expect(try !item(.format, in: workspace).isHidden && !item(.zoom, in: workspace).isHidden)
    }

    /// With the PDF hidden the source holds Compile and the toggles too, in a narrower window.
    @Test func theSourceAloneFitsANarrowerWindow() async throws {
        let (window, workspace) = try await workspace(showPDF: false)
        defer { workspace.close(); window.close() }
        try await resize(window, to: 100)
        #expect(abs(window.contentLayoutRect.width - ColumnMetrics.contentMinimum.width) < 2)
        #expect(ColumnMetrics.contentMinimum.width
                < ColumnMetrics.sourceMinimum(sidebarHidden: true, pdfHidden: false) + ColumnMetrics.pdfMinimum)
        #expect(workspace.toolbar.fit.mergesEditing && workspace.toolbar.fit.compactCompile)
        #expect(try item(.zoom, in: workspace).isHidden)
        // Compile as its symbol, still Compile to the overflow menu and VoiceOver.
        let compile = try item(.compile, in: workspace)
        #expect(compile.title.isEmpty && compile.image != nil && compile.label == MenuCommand.compileRun.title)
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
