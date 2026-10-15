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
        // As the app's window has them (`MainWindowController`).
        window.contentMinSize = ColumnMetrics.contentMinimum
        // Neither loaded nor saved: this host shares the app's saved toolbar.
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

    /// At its narrowest the panes are at their least or wider, and nothing has left the toolbar
    /// but for its overflow menu, where each tool that can go has a menu form. Compile is the
    /// same prominent symbol at any width, named for the overflow menu and VoiceOver.
    @Test func aNarrowWindowKeepsEveryToolOrItsMenuForm() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let compile = try item(.compile, in: workspace)
        #expect(compile.view == nil && compile.image != nil && compile.style == .prominent)

        // The least a drag of the window's edge gets to: the toolbar's, which the panes' own
        // (with their divider, at most a point) fit in, so they don't hold the window wider.
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
        // The tools Customize Toolbar can add are among the first to go.
        for id in [NSToolbarItem.Identifier.undo, .redo, .bold, .italic, .underline, .share] {
            let added = workspace.toolbar.toolbar(workspace.toolbar.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false)
            #expect(added?.visibilityPriority == .low, "\(id.rawValue)")
        }
    }

    /// Stop takes Compile's place in the same item, a symbol as Compile is, so the tools beside it
    /// stay where they are as a build starts and ends. The overflow menu and VoiceOver have Stop
    /// by name, and its help tag says what it does.
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

    /// With the PDF hidden the window is no narrower: its toolbar holds it there.
    @Test func theSourceAloneStopsAtTheToolbarsMinimum() async throws {
        let (window, workspace) = try await workspace(showPDF: false)
        defer { workspace.close(); window.close() }
        try await resize(window, to: ColumnMetrics.contentMinimum.width)
        #expect(window.contentView?.frame.width == ColumnMetrics.contentMinimum.width)
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

    /// Aa is a pull-down of the styles, Inline Math and the class's levels, each level in its font,
    /// all off with no LaTeX file open.
    @Test func formatIsAPullDownOfStylesAndLevels() async throws {
        let (window, workspace) = try await workspace(showPDF: true)
        defer { workspace.close(); window.close() }
        let menu = try #require(try item(.format, in: workspace) as? NSMenuToolbarItem).menu
        menu.delegate?.menuNeedsUpdate?(menu)
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == [MenuCommand.editBold, .editItalic, .editUnderline, .editMath].map(\.title) + HeadingLevel.all.map(\.title))
        #expect(items.allSatisfy { !$0.isEnabled })
        let fonts = items.suffix(HeadingLevel.all.count).compactMap { $0.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }
        #expect(fonts.count == HeadingLevel.all.count && fonts[1].pointSize > fonts[0].pointSize)
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

    /// The File Outline is at the sidebar's foot from the first, folded to its header, a status
    /// bar's height, for a file that has no outline, and away only while search results have
    /// the sidebar.
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

    /// The side columns are the split's: View's titles follow their panes however they shut, and
    /// View's toggles open and shut the panes.
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
