import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// One at a time: AppKit keeps toolbars of one identifier alike, so a tool taken out of one window's is out of every window's.
@Suite(.serialized)
@MainActor
struct ShellTests {
    private func workspace(showPDF: Bool, sidebar: Bool = false) async throws -> (NSWindow, WorkspaceController) {
        let app = AppModel()
        app.showPDF = showPDF
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let workspace = WorkspaceController(app: app, project: ProjectModel(id: "ShellTests", app: app),
                                            size: window.contentLayoutRect.size)
        window.contentViewController = workspace
        // Over what the split's autosave, which this host shares with the app, restored.
        workspace.sidebarItem.isCollapsed = !sidebar
        workspace.inspectorItem.isCollapsed = true
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

    @Test func aNarrowWindowKeepsEveryToolOrItsMenuForm() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let compile = try item(.compile, in: workspace)
        #expect(compile.view == nil && compile.image != nil && compile.style == .prominent)
        let least = ColumnMetrics.contentMinimum.width
        #expect(least >= ColumnMetrics.sourceMinimum + 1 + ColumnMetrics.pdfMinimum + ColumnMetrics.toolbarInset)
        try await resize(window, to: least)
        #expect(window.contentView?.frame.width == least)
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
    }

    /// Stop takes Compile's place in the same item, so the tools beside it stay where they are.
    @Test func stopTakesCompilesPlace() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let compile = try item(.compile, in: workspace)
        let identifiers = workspace.toolbar.toolbar.items.map(\.itemIdentifier)
        workspace.project.compiling = true
        try await waitUntil { compile.label == MenuCommand.compileStop.title }
        #expect(compile.menuFormRepresentation?.title == MenuCommand.compileStop.title)
        #expect(compile.toolTip == "Stop the build" && compile.backgroundTintColor == .clear && compile.image != nil)
        #expect(workspace.toolbar.toolbar.items.map(\.itemIdentifier) == identifiers)
        workspace.project.compiling = false
        try await waitUntil { compile.label == MenuCommand.compileRun.title }
        #expect(compile.toolTip == "Compile the project" && compile.backgroundTintColor == nil)
    }

    @Test func formatIsAPullDownGroupedAsNotesAa() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let menu = try #require(try item(.format, in: workspace) as? NSMenuToolbarItem).menu
        menu.delegate?.menuNeedsUpdate?(menu)
        // The styles' palette row, the levels, then what goes in.
        let groups = menu.items.split(whereSeparator: \.isSeparatorItem).map(Array.init)
        #expect(groups.count == 3)
        let palette = try #require(groups[0].first?.submenu)
        #expect(groups[0].count == 1 && palette.presentationStyle == .palette && palette.selectionMode == .selectAny)
        #expect(palette.items.map(\.title) == [MenuCommand.editBold, .editItalic, .editUnderline].map(\.title) && palette.selectedItems.isEmpty)
        // The class's levels as the core sets and numbers them, "1.1" for a subsection.
        let headings = workspace.project.headingStyles
        #expect(groups[1].map { $0.attributedTitle?.string ?? "" } == headings.map(\.numberedTitle))
        #expect(headings.contains { $0.marker == "1.1" })
        #expect(groups[1].map(\.state) == [NSControl.StateValue.on] + Array(repeating: NSControl.StateValue.off, count: groups[1].count - 1))
        let fonts = groups[1].compactMap { item in item.attributedTitle.flatMap { $0.attribute(.font, at: $0.length - 1, effectiveRange: nil) as? NSFont } }
        #expect(fonts.count == groups[1].count && fonts[1].pointSize > fonts[0].pointSize)
        #expect(groups[2].first?.title == MenuCommand.editMath.title)
        // No LaTeX file is open.
        #expect(menu.items.allSatisfy { !$0.isEnabled } && palette.items.allSatisfy { !$0.isEnabled })
    }

    @Test func theOutlineFoldsToItsHeaderAndGoesOnlyForSearchResults() async throws {
        let (window, workspace) = try await workspace(showPDF: true, sidebar: true)
        defer { workspace.close(); window.close() }
        let sidebar = try #require(workspace.sidebarItem.viewController as? NSSplitViewController)
        let outline = sidebar.splitViewItems[1]
        func folded() -> Bool {
            window.layoutIfNeeded()
            return !outline.isCollapsed && isClose(outline.viewController.view.frame.height, BarMetrics.height)
        }
        try await waitUntil(folded)
        workspace.project.search.query = "needle"
        try await waitUntil { outline.isCollapsed }
        workspace.project.search.query = ""
        try await waitUntil(folded)
        #expect(outline.maximumThickness == BarMetrics.height)
    }

    @Test func viewsTitlesFollowTheSideColumns() async throws {
        let (window, workspace) = try await workspace(showPDF: true, sidebar: true)
        defer { workspace.close(); window.close() }
        let app = workspace.app, project = workspace.project
        #expect(app.title(.viewToggleSidebar, on: project) == "Hide Sidebar")
        #expect(app.title(.viewToggleInspector, on: project) == "Show Inspector")
        workspace.sidebarItem.isCollapsed = true
        #expect(app.title(.viewToggleSidebar, on: project) == "Show Sidebar")
        app.perform(.viewToggleSidebar, on: project)
        try await waitUntil { !workspace.sidebarItem.isCollapsed }
        #expect(app.title(.viewToggleSidebar, on: project) == "Hide Sidebar")
        app.perform(.viewToggleInspector, on: project)
        try await waitUntil { !workspace.inspectorItem.isCollapsed }
        #expect(app.title(.viewToggleInspector, on: project) == "Hide Inspector")
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
