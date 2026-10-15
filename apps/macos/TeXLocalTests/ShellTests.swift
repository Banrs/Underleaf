import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// One at a time: AppKit keeps toolbars of one identifier alike, so a tool taken out of one window's is out of every window's.
@Suite(.serialized)
@MainActor
struct ShellTests {
    private func workspace(showPDF: Bool) async throws -> (NSWindow, WorkspaceController) {
        let app = AppModel()
        app.sidebarVisible = false
        app.inspectorVisible = false
        app.showPDF = showPDF
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let workspace = WorkspaceController(app: app, project: ProjectModel(id: "ShellTests", app: app),
                                            size: window.contentLayoutRect.size)
        window.contentViewController = workspace
        window.contentMinSize = ColumnMetrics.contentMinimum
        // Neither loaded nor saved: this host shares the app's saved toolbar, and Compile's form goes by which tools the toolbar holds.
        workspace.toolbar.toolbar.autosavesConfiguration = false
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
