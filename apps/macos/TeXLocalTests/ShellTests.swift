import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import TeXLocal

@Suite(.serialized)
struct ShellTests {
    private let defaults = TestDefaults()

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

    @Test(arguments: [false, true]) func aNarrowWindowKeepsEveryToolOrItsMenuForm(sidebar: Bool) async throws {
        let (window, workspace) = try await workspace(sidebar: sidebar)
        defer { workspace.close(); window.close() }
        let toolbar = workspace.toolbar
        let compile = try item(.compile, in: workspace)
        let button = try #require(compile.view)
        let word = button.fittingSize.width
        #expect(!toolbar.compactCompile && word > 60 && compile.style == .prominent)
        func shown(_ id: NSToolbarItem.Identifier) -> Bool { toolbar.toolbar.visibleItems?.contains { $0.itemIdentifier == id } == true }
        for width in stride(from: 1300, to: ColumnMetrics.contentMinimum.width, by: -10) {
            try await resize(window, to: width)
            if !toolbar.compactCompile { #expect(shown(.zoom) && shown(.compile), "at \(width)") }
        }
        try await resize(window, to: ColumnMetrics.contentMinimum.width)
        #expect(sidebar || window.contentView?.frame.width == ColumnMetrics.contentMinimum.width)
        for pane in workspace.columns.splitViewItems { #expect(pane.viewController.view.frame.width >= ColumnMetrics.paneMinimum) }
        #expect(toolbar.compactCompile && button.fittingSize == NSSize(width: 36, height: 36))
        #expect(shown(.compile) && shown(.back))
        #expect(compile.label == MenuCommand.compileRun.title && compile.menuFormRepresentation?.title == MenuCommand.compileRun.title)
        for id in [NSToolbarItem.Identifier.format, .math, .insert, .zoom] {
            let item = try item(id, in: workspace)
            #expect(!item.isHidden && item.visibilityPriority == .low)
            #expect(item is NSMenuToolbarItem || item.menuFormRepresentation?.submenu != nil)
        }
        for id in [NSToolbarItem.Identifier.back, .compile, .layout] {
            #expect(try item(id, in: workspace).visibilityPriority == .high)
        }
        try await resize(window, to: 1300)
        #expect(!toolbar.compactCompile && button.fittingSize.width == word)
    }

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
            #expect(button.fittingSize == idle && compile.backgroundTintColor == .clear)
            #expect(compile.menuFormRepresentation?.title == MenuCommand.compileStop.title)
            workspace.project.compiling = false
            try await waitUntil { compile.label == MenuCommand.compileRun.title }
            #expect(button.fittingSize == idle && compile.backgroundTintColor == nil)
        }
    }

    @Test func theToolbarsControlsKeepTheirStateAndWidth() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let tools = workspace.toolbar
        let share = try #require(tools.toolbar(tools.toolbar, itemForItemIdentifier: .share, willBeInsertedIntoToolbar: true)
            as? NSSharingServicePickerToolbarItem)
        #expect(!share.isEnabled && !share.validateMenuItem(share.menuFormRepresentation ?? NSMenuItem()))
        let zoom = try #require(item(.zoom, in: workspace).view as? NSSegmentedControl)
        let width = zoom.intrinsicContentSize.width
        zoom.setLabel("1%", forSegment: 1)
        #expect(zoom.intrinsicContentSize.width == width)
    }

    @Test func theSavedLayoutOverridesRememberedCollapsedPanes() async throws {
        let app = AppModel(defaults: defaults.store)
        app.layout = .split
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let workspace = WorkspaceController(app: app, project: ProjectModel(id: "ShellTests", app: app),
                                            size: window.contentLayoutRect.size)
        defer { workspace.close(); window.close() }
        let source = workspace.columns.splitViewItems[0]
        source.isCollapsed = true
        window.contentViewController = workspace
        window.toolbar = workspace.toolbar.toolbar
        window.orderFrontUnseen()
        try await waitUntil { !source.isCollapsed }
        #expect(workspace.columns.splitViewItems.allSatisfy { !$0.isCollapsed })
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

    @Test func theStatusBarsLineTakesThePanelsDrag() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
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

    @Test func formatIsAPopoverWithAMenuForm() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let format = try item(.format, in: workspace)
        #expect(!(format is NSMenuToolbarItem) && format.action != nil)
        let menu = try #require(format.menuFormRepresentation?.submenu)
        let titles = [MenuCommand.editBold, .editItalic, .editUnderline].map(\.title) + workspace.project.headingStyles.map(\.title)
        try await waitUntil {
            menu.update()
            return menu.items.filter { !$0.isSeparatorItem }.map(\.title) == titles
        }
    }

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

    @Test func aFoldedSidebarIsNotAHiddenOne() async throws {
        let (window, workspace) = try await workspace(sidebar: true)
        defer { workspace.close(); window.close() }
        let app = workspace.app, project = workspace.project
        let saved = defaults.saved(DefaultsKey.sidebarVisible) as? Bool
        #expect(app.title(.viewToggleSidebar, on: project) == "Hide Sidebar")
        workspace.sidebarItem.isCollapsed = true
        #expect(app.sidebarVisible && app.sidebarFolded && !app.sidebarShown)
        #expect(defaults.saved(DefaultsKey.sidebarVisible) as? Bool == saved)
        #expect(app.title(.viewToggleSidebar, on: project) == "Show Sidebar")
        await settle()
        app.perform(.viewToggleSidebar, on: project)
        try await waitUntil { !workspace.sidebarItem.isCollapsed }
        #expect(app.sidebarShown && !app.sidebarFolded)
        app.perform(.viewToggleSidebar, on: project)
        #expect(!app.sidebarVisible && defaults.saved(DefaultsKey.sidebarVisible) as? Bool == false)
    }

    @Test func aHiddenInspectorOpensWithItsFormsLook() async throws {
        let (window, workspace) = try await workspace()
        defer { workspace.close(); window.close() }
        let inspector = try #require(workspace.splitViewItems.last)
        workspace.app.perform(.viewToggleInspector, on: workspace.project)
        try await waitUntil { !inspector.isCollapsed }
        try await resize(window, to: 1300)
        let view = inspector.viewController.view
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let form = try #require(all(view).compactMap { $0 as? NSScrollView }.first)
        let section = try #require(form.documentView?.subviews.first?.subviews.first)
        #expect(section.frame.minX == 20 && section.frame.width == view.bounds.width - 40, "\(section.frame)")
    }

    @Test func aProjectSwitchNeverShowsHome() {
        let app = AppModel(defaults: defaults.store)
        let first = ProjectModel(id: "ShellTests A", app: app), next = ProjectModel(id: "ShellTests B", app: app)
        app.project = next
        #expect(!next.initialLoadComplete && app.workspaceProject(after: first) === first)
        #expect(app.workspaceProject(after: nil) == nil)
        app.project = nil
        #expect(app.workspaceProject(after: first) == nil)
    }

    @Test func aPDFRequestShowsTheColumnAndReachesTheWorkspace() {
        let app = AppModel(defaults: defaults.store)
        app.showPDF = false
        var asked = 0
        app.performPDF = { if case .fitWidth = $0 { asked += 1 } }
        app.requestPDF(.fitWidth)
        app.requestPDF(.fitWidth)
        #expect(app.showPDF && asked == 2 && defaults.saved(DefaultsKey.showPDF) == nil)
    }

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
