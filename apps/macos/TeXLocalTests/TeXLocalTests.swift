import SwiftUI
import Testing
import XCTest
@testable import TeXLocal

final class SyncTeXGeometryTests: XCTestCase {
    // A US Letter page whose box starts at the origin, and one offset the way
    // some producers write a crop box.
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    let offset = CGRect(x: 10, y: 20, width: 612, height: 792)

    func testForwardBoxFlipsFromTopLeftToBottomLeft() {
        let loc = ForwardLoc(page: 1, h: 72, v: 100, width: 468, height: 10)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: letter)
        // Baseline 100pt below the top edge is 692pt above the bottom edge.
        XCTAssertEqual(rect.minX, 70)
        XCTAssertEqual(rect.minY, 690)
        XCTAssertEqual(rect.width, 472)
        XCTAssertEqual(rect.height, 14)
    }

    func testForwardBoxIsNeverNarrowerThanAWord() {
        let loc = ForwardLoc(page: 1, h: 72, v: 100, width: 0, height: nil)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: letter)
        XCTAssertEqual(rect.width, 28)
        XCTAssertEqual(rect.height, 16)
    }

    func testInversePointRoundTripsThroughAnOffsetBox() {
        let synctex = SyncTeXGeometry.synctexPoint(CGPoint(x: 82, y: 712), pageBounds: offset)
        XCTAssertEqual(synctex, CGPoint(x: 72, y: 100))
        let loc = ForwardLoc(page: 1, h: synctex.x, v: synctex.y, width: 0, height: 0)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: offset)
        XCTAssertEqual(rect.minX + 2, 82)
        XCTAssertEqual(rect.minY + 2, 712)
    }
}

/// The core's analysis as the views take it. The counting rules themselves
/// are checked against the web's by the core's shared fixtures
/// (crates/texlocal-core/tests/fixtures/analyze.json).
@MainActor
final class OutlineTests: XCTestCase {
    func testSectionsWithDepthTitlesAndLines() async throws {
        let text = """
        \\documentclass{article}
        \\section{Intro}
        % \\section{Commented out}
        \\subsection*[short]{Details}
        text \\section{}
        """
        let items = try await Outline.analyze(text).items
        XCTAssertEqual(items.map(\.title), ["Intro", "Details", "(untitled)"])
        XCTAssertEqual(items.map(\.level), [2, 3, 2])
        XCTAssertEqual(items.map(\.line), [2, 4, 5])
    }

    func testLinesBreakWhereTheEditorBreaksThemAndCommentsHoldNoWords() async throws {
        let doc = try await Outline.analyze("\\section{One} two words\r\n  % three four\rfive\n")
        XCTAssertEqual(doc.lines, 4)
        XCTAssertEqual(doc.words, 4)
        XCTAssertEqual(doc.items.map(\.title), ["One"])
        let empty = try await Outline.analyze("")
        XCTAssertEqual(empty.lines, 1)
    }

    func testTheBreadcrumbIsTheChainOfEnclosingHeadings() async throws {
        let outline = try await Outline.analyze("""
        \\chapter{A}
        \\section{B}
        \\subsection{C}
        \\section{D}
        text
        """).items
        XCTAssertEqual(Outline.chain(outline, at: 3).map(\.title), ["A", "B", "C"])
        XCTAssertEqual(Outline.chain(outline, at: 5).map(\.title), ["A", "D"])
        XCTAssertEqual(Outline.chain(outline, at: 0).map(\.title), [])
    }
}

@MainActor
final class OutlineDisplayTests: XCTestCase {
    func testDepthFollowsTheNestingNotTheLevel() async throws {
        // A subsection before any section has no parent: it sits flush, as
        // does the section after it; the subsection under that section is
        // one in.
        let outline = try await Outline.analyze("""
        \\subsection{}
        \\section{First Section}
        \\subsection{Detail}
        \\subsubsection{Finer}
        \\section{Second}
        """).items
        XCTAssertEqual(Outline.depths(outline), [0, 0, 1, 2, 0])
    }

    func testTheTreeNestsAsTheHeadingsDo() async throws {
        let outline = try await Outline.analyze("""
        \\subsection{}
        \\section{A}
        \\subsection{A1}
        \\subsection{A2}
        \\section{B}
        """).items
        let tree = Outline.tree(outline)
        XCTAssertEqual(tree.map(\.item.title), ["(untitled)", "A", "B"])
        XCTAssertNil(tree[0].children)
        XCTAssertEqual(tree[1].children?.map(\.item.title), ["A1", "A2"])
        XCTAssertNil(tree[2].children)
    }

    /// A fold is keyed by the heading's level, title and which of its
    /// namesakes it is, so headings added above leave it where it was.
    func testFoldKeysSurviveRenumbering() async throws {
        let text = "\\section{A}\n\\subsection{Results}\n\\section{B}\n\\subsection{Results}"
        let keys = Outline.foldKeys(try await Outline.analyze(text).items)
        XCTAssertEqual(keys, ["2:A#1", "3:Results#1", "2:B#1", "3:Results#2"])
        let later = Outline.foldKeys(try await Outline.analyze("\\section{New}\n\\subsection{Other}\n" + text).items)
        XCTAssertEqual(Array(later.dropFirst(2)), keys)
    }

    func testEmptyHeadingsAreNamedByKind() async throws {
        let outline = try await Outline.analyze("\\subsection{}\n\\chapter{}\n\\section{Named}").items
        XCTAssertEqual(outline.map(Outline.displayTitle), ["Untitled Subsection", "Untitled Chapter", "Named"])
    }
}

/// The pane bars' controls measured off screen, with no window shown.
@MainActor
struct PaneBarLayoutTests {
    private func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.paneBarControls()).fittingSize.height
    }

    /// The UI kit's Unified Compact toolbar, the bars' one size: its
    /// regular controls with 8 pt above and below.
    @Test func theBarIsTheKitsCompactToolbarHeight() {
        #expect(BarMetrics.barHeight == 40)
        #expect(BarMetrics.controlSize == .regular)
        #expect(height(PaneBar { Button("Done") {} }) == BarMetrics.barHeight)
    }

    /// Every control in a bar is the kit's regular height, whatever its
    /// symbol: a group, one control grouped alone (a bordered ellipsis
    /// alone was 12.5 pt), and the compact Compile (21 pt as a symbol alone).
    @Test func everyControlIsTheKitsRegularHeight() {
        let undo = ToolGroup(items: [
            Segment(id: "a", title: "Undo", systemImage: "arrow.uturn.backward", action: {}),
            Segment(id: "b", title: "Redo", systemImage: "arrow.uturn.forward", action: {}),
        ])
        let more = Menu { Button("Figure") {} } label: { Label("More", systemImage: "ellipsis") }.inControlGroup()
        let share = Button("Share PDF", systemImage: "square.and.arrow.up") {}.inControlGroup()
        let compile = Button {} label: { Label("Compile", systemImage: "play.fill").labelStyle(SymbolOnTextLine()) }
            .buttonStyle(.borderedProminent)
        let done = Button("Done") {}
        #expect(height(undo) == BarMetrics.controlHeight)
        #expect(height(more) == BarMetrics.controlHeight)
        #expect(height(share) == BarMetrics.controlHeight)
        #expect(height(compile) == BarMetrics.controlHeight)
        #expect(height(done) == BarMetrics.controlHeight)
    }
}

/// A find bar, measured off screen.
@MainActor
struct FindBarTests {
    /// The PDF's one row fits a pane bar, so it is the bars' height; the
    /// source's replace row adds a row of controls and the gap between.
    @Test func aFindBarIsABarsHeight() {
        let find = FindBar(query: .constant("the"), prompt: "Find in PDF", focus: 0, matches: FindMatches(),
                           searched: "the", step: { _ in }, close: {})
        let replace = FindBar(query: .constant("the"), prompt: "Find", focus: 0, matches: FindMatches(),
                              searched: "the", step: { _ in }, close: {}) {
            GridRow {
                TextField("Replace", text: .constant("")).textFieldStyle(.bordered)
                Button("Replace") {}
            }
        }
        let one = NSHostingView(rootView: find.frame(width: 400)).fittingSize.height
        let two = NSHostingView(rootView: replace.frame(width: 400)).fittingSize.height
        #expect(one == BarMetrics.barHeight)
        #expect(two > one + BarMetrics.controlHeight)
    }
}

/// The open file's watcher: a change on disk, written in place or saved
/// over it the way editors save (a new file renamed over the old), is told.
@MainActor
final class FileWatcherTests: XCTestCase {
    func testChangesInPlaceAndByReplacementAreBothTold() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("main.tex")
        try "one".write(to: url, atomically: false, encoding: .utf8)

        var changes = 0
        let watcher = FileWatcher(url: url) { changes += 1 }
        try "two".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes > 0 }
        let inPlace = changes
        // Atomically: a new file renamed over the old one.
        try "three".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil { changes > inPlace }
        // Still watching the file now at that path.
        try await Task.sleep(for: .milliseconds(300))
        let replaced = changes
        try "four".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes > replaced }
        _ = watcher
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class SplitControllerTests: XCTestCase {
    /// The window holding the test's split, and the autosave to forget.
    private var window: NSWindow?
    private var autosave = ""

    // The async one: XCTest runs it on the main actor, where the window is.
    override func tearDown() async throws {
        // Not saved again as it closes, into the app's own preferences.
        (window?.contentViewController as? NSSplitViewController)?.splitView.autosaveName = nil
        window?.close()
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(autosave)")
        try await super.tearDown()
    }

    /// A split of `size` as a window's content, laid out and its panes
    /// opened at their shares, as when it appears.
    private func split(_ size: NSSize, vertical: Bool, _ panes: [SplitPane]) -> PaneSplitViewController {
        autosave = "SplitControllerTests \(UUID())"
        let controller = PaneSplitViewController(app: AppModel(), vertical: vertical, autosave: autosave, panes: panes)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // At its size before it's the window's content, which would
        // otherwise take the view's.
        controller.view.setFrameSize(size)
        window.contentViewController = controller
        self.window = window
        resize(to: size)
        // On screen, unseen, as the app shows it: it appears, and its panes
        // open at their shares.
        window.alphaValue = 0
        window.orderFront(nil)
        return controller
    }

    private func resize(to size: NSSize) {
        window?.setContentSize(size)
        window?.layoutIfNeeded()
    }

    private func heights(_ controller: PaneSplitViewController) -> [CGFloat] {
        controller.splitViewItems.map(\.viewController.view.frame.height)
    }

    /// The build panel opens at its share, keeps its size as the window
    /// grows, gives way beyond two fifths in a small window, and has its
    /// size back as the window grows again.
    func testThePanelKeepsItsSizeWithinItsLargestShare() {
        let controller = split(NSSize(width: 400, height: 601), vertical: false, [
            SplitPane(minimum: 120) { EmptyView() },
            SplitPane(minimum: 80, maxFraction: 0.4, fraction: 0.3, keepsSize: true) { EmptyView() },
        ])
        XCTAssertEqual(heights(controller), [420, 180])
        resize(to: NSSize(width: 400, height: 801))
        XCTAssertEqual(heights(controller), [620, 180])
        resize(to: NSSize(width: 400, height: 401))
        XCTAssertEqual(heights(controller)[1], 160, accuracy: 0.5)
        resize(to: NSSize(width: 400, height: 601))
        XCTAssertEqual(heights(controller), [420, 180])
    }

    /// The inspector is the system's: its behaviour and its standard
    /// width, not one of ours.
    func testTheInspectorIsTheSystemsAtItsStandardWidth() {
        let controller = split(NSSize(width: 1000, height: 600), vertical: true, [
            SplitPane { EmptyView() },
            SplitPane(inspector: true) { EmptyView() },
        ])
        let inspector = controller.splitViewItems[1]
        XCTAssertEqual(inspector.behavior, .inspector)
        // NSSplitViewItem.h's standard inspector width, not resizable.
        XCTAssertEqual(inspector.viewController.view.frame.width, 270)
        XCTAssertEqual(inspector.minimumThickness, 270)
        XCTAssertEqual(inspector.maximumThickness, 270)
        // Shown and hidden by the app, not by a drag on its divider.
        XCTAssertFalse(inspector.canCollapse)
    }

    /// A pane hidden at first opens at its share the first time it shows,
    /// not at its minimum, sliding in; hidden again it collapses.
    func testAHiddenPaneOpensAtItsShare() async throws {
        func panes(shown: Bool) -> [SplitPane] {
            [SplitPane(minimum: 120) { EmptyView() },
             SplitPane(minimum: 80, fraction: 0.3, keepsSize: true, shown: shown) { EmptyView() }]
        }
        let controller = split(NSSize(width: 400, height: 601), vertical: false, panes(shown: false))
        XCTAssertTrue(controller.splitViewItems[1].isCollapsed)
        controller.update(panes(shown: true))
        try await waitUntil { !controller.splitViewItems[1].isCollapsed }
        try await waitUntil { self.heights(controller) == [420, 180] }
        controller.update(panes(shown: false))
        try await waitUntil { controller.splitViewItems[1].isCollapsed }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<40 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition())
    }
}

/// The sidebar's split (Files over the File Outline), a plain NSSplitView.
@MainActor
final class SidebarSplitTests: XCTestCase {
    /// The window holding the test's split (a view doesn't keep its window).
    private var window: NSWindow?

    /// Two panes, one over the other, in a split of `size` in a window, as
    /// the app has it, the second dragged to `last` points.
    ///
    /// The window sizes the split once it has its delegate, which lays the
    /// panes out before the drag, as in the app. macOS 26's `setPosition`
    /// doesn't lay out panes added since the last layout (27's does), so a
    /// split never sized constrained the drag against empty frames there.
    private func split(_ size: NSSize, _ panes: [SidebarPane],
                       last: CGFloat) -> (NSSplitView, SidebarSplitCoordinator) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 1200),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        let coordinator = SidebarSplitCoordinator(autosave: "SidebarSplitTests \(UUID())")
        coordinator.panes = panes
        coordinator.clips = [PaneClip(content: NSView()), PaneClip(content: NSView())]
        coordinator.clips.forEach(split.addArrangedSubview)
        split.delegate = coordinator
        window.contentView?.addSubview(split)
        resize(split, to: size)
        // Laid out before the drag: the panes fill the split.
        XCTAssertEqual(split.arrangedSubviews[1].frame.maxY, size.height)
        split.setPosition(size.height - last - split.dividerThickness, ofDividerAt: 0)
        layOut(split)
        return (split, coordinator)
    }

    /// The window resizing the split: its new frame, then a layout pass.
    private func resize(_ split: NSSplitView, to size: NSSize) {
        split.setFrameSize(size)
        layOut(split)
    }

    /// The window's layout pass, which lays the split out again: the
    /// panes stay as they were.
    private func layOut(_ split: NSSplitView) {
        split.window?.layoutIfNeeded()
    }

    private func heights(_ split: NSSplitView) -> [CGFloat] {
        split.arrangedSubviews.map(\.frame.height)
    }

    /// A pane squeezed to its minimum by a small window gets its share back
    /// as the window grows, rather than staying at the minimum.
    func testAPaneGetsItsShareBackAfterASmallWindow() throws {
        // The second pane dragged short.
        let (split, coordinator) = split(NSSize(width: 250, height: 936),
                                         [SidebarPane(minimum: 140), SidebarPane(minimum: 140)], last: 200)
        XCTAssertEqual(heights(split), [735, 200])
        resize(split, to: NSSize(width: 250, height: 300))
        XCTAssertEqual(heights(split), [159, 140])
        // Hidden now, it would come back at the share it had, not squeezed.
        XCTAssertEqual(try XCTUnwrap(coordinator.share(split, of: 1)), 200 / 935, accuracy: 0.001)
        resize(split, to: NSSize(width: 250, height: 936))
        XCTAssertEqual(heights(split), [735, 200])
    }

    /// The sidebar's outline folded to its header: the files take the
    /// room, the header stays as the window resizes, its divider doesn't
    /// drag, and unfolding brings back the height it had.
    func testAFoldedPaneKeepsItsHeaderAndUnfoldsToItsHeight() {
        let panes = [
            SidebarPane(minimum: 100),
            SidebarPane(minimum: 80, fraction: 0.45, keepsSize: true),
        ]
        let (split, coordinator) = split(NSSize(width: 250, height: 600), panes, last: 240)
        defer { UserDefaults.standard.removeObject(forKey: "\(coordinator.autosave) Unfolded 1") }
        var folded = panes
        folded[1].collapsed = 28
        coordinator.panes = folded
        coordinator.fold(split, 1, to: 28)
        layOut(split)
        XCTAssertEqual(heights(split), [571, 28])
        XCTAssertEqual(coordinator.splitView(split, effectiveRect: NSRect(x: 0, y: 571, width: 250, height: 1),
                                             forDrawnRect: .zero, ofDividerAt: 0), .zero)
        resize(split, to: NSSize(width: 250, height: 800))
        XCTAssertEqual(split.arrangedSubviews[1].frame.height, 28)
        resize(split, to: NSSize(width: 250, height: 600))
        coordinator.panes = panes
        coordinator.fold(split, 1, to: nil)
        layOut(split)
        XCTAssertEqual(split.arrangedSubviews[1].frame.height, 240)
    }
}

/// The splits as SwiftUI lays them out, and the sidebar's outline folded
/// while it's out of the sidebar.
@MainActor
struct SplitHostingTests {
    /// Hosts `view` in a window of `size`, laid out, until `body` returns;
    /// the autosave it wrote forgotten.
    private func host<V: View>(_ view: V, _ size: CGSize = CGSize(width: 400, height: 600), autosave: String,
                               _ body: (NSHostingView<V>) -> Void) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        body(host)
        window.contentView = nil
        window.close()
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(autosave)")
    }

    /// Neither split's panes' minimums reach the window's layout: the
    /// window can be as small as the app lets it be, not as the panes add
    /// up. The split view controller's items constrain its view, so
    /// `SplitController` sizes itself to the proposal; the sidebar's plain
    /// split has no constraints to pass on.
    @Test func theSplitsLeaveTheWindowItsMinimum() {
        let autosave = "SplitHostingTests \(UUID())"
        let minimum: CGFloat = 300
        let panes = SplitController(app: AppModel(), axis: .vertical, autosave: autosave, panes: [
            SplitPane(minimum: minimum) { Color.clear },
            SplitPane(minimum: minimum) { Color.clear },
        ])
        let sidebar = SidebarSplit(app: AppModel(), autosave: autosave,
                                   top: SidebarPane(minimum: minimum), bottom: SidebarPane(minimum: minimum)) {
            Color.clear
        } bottomContent: {
            Color.clear
        }
        for split in [AnyView(panes), AnyView(sidebar)] {
            host(split, CGSize(width: 900, height: 900), autosave: autosave) { host in
                // The size the window's layout asks of it.
                #expect(host.fittingSize.height < minimum)
            }
        }
    }

    /// View › Hide File Outline during a project search, the outline out of
    /// the sidebar: told at once, with nothing to slide, so the outline's
    /// chevron closes and the pane comes back folded.
    @Test func aFoldWhileTheOutlineIsOutIsToldAtOnce() {
        let autosave = "SplitHostingTests \(UUID())"
        var told: [Bool] = []
        func sidebar(folded: Bool) -> SidebarSplit<Color, Color> {
            SidebarSplit(app: AppModel(), autosave: autosave, top: SidebarPane(minimum: 100),
                         bottom: SidebarPane(minimum: 80, shown: false, collapsed: folded ? 28 : nil,
                                             didFold: { told.append($0) })) {
                Color.clear
            } bottomContent: {
                Color.clear
            }
        }
        host(sidebar(folded: false), autosave: autosave) { host in
            host.rootView = sidebar(folded: true)
            host.layoutSubtreeIfNeeded()
            #expect(told == [true])
            host.rootView = sidebar(folded: false)
            host.layoutSubtreeIfNeeded()
            #expect(told == [true, false])
        }
    }

    /// The outline's rows follow what the fold was told: gone once folded,
    /// back once unfolded, and a stale report changes nothing.
    @Test func theOutlinesRowsFollowTheFold() {
        let key = NavigatorView.outlineCollapsedKey
        let before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        let fold = OutlineFold()
        UserDefaults.standard.set(true, forKey: key)
        fold.slid(folded: false)
        #expect(fold.rowsShown == !(before as? Bool ?? false))
        fold.slid(folded: true)
        #expect(!fold.rowsShown)
        UserDefaults.standard.set(false, forKey: key)
        fold.slid(folded: false)
        #expect(fold.rowsShown)
    }
}

final class CompileResultTests: XCTestCase {
    func testDurationsReadTheSameEverywhere() throws {
        let json = #"{"ok":true,"stopped":false,"durationMs":1234,"pdf":"build/main.pdf","errors":[],"warnings":[],"log":""}"#
        let result = try JSONDecoder().decode(CompileResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.durationText, "1.2 s")
    }
}

final class RenameTests: XCTestCase {
    func testTheOpenFileMovesWithItsFolder() {
        XCTAssertEqual(remapPath("ch/intro.tex", from: "ch/intro.tex", to: "ch/start.tex"), "ch/start.tex")
        XCTAssertEqual(remapPath("ch/intro.tex", from: "ch", to: "chapters"), "chapters/intro.tex")
        XCTAssertEqual(remapPath("ch/a/b.tex", from: "ch/a", to: "x"), "x/b.tex")
        // A sibling that shares the prefix is not inside the folder.
        XCTAssertEqual(remapPath("chapter.tex", from: "ch", to: "chapters"), "chapter.tex")
        XCTAssertEqual(remapPath("main.tex", from: "ch", to: "chapters"), "main.tex")
    }
}

final class FindTests: XCTestCase {
    func testTheCountReadsAsXcodesDoes() {
        XCTAssertEqual(FindMatches(index: 3, total: 12).label(for: "loop"), "3 of 12")
        XCTAssertEqual(FindMatches(index: 0, total: 12).label(for: "loop"), "12 matches")
        XCTAssertEqual(FindMatches(index: 0, total: 1).label(for: "loop"), "1 match")
        XCTAssertEqual(FindMatches(index: 2, total: 1000, limited: true).label(for: "a"), "2 of 1000+")
        XCTAssertEqual(FindMatches().label(for: "loop"), "Not found")
        XCTAssertEqual(FindMatches().label(for: ""), "")
    }

    func testQueriesAreTrimmedAndCapped() {
        XCTAssertEqual(PDFFind.normalize("  theorem \n"), "theorem")
        XCTAssertEqual(PDFFind.normalize(" \t "), "")
        XCTAssertEqual(PDFFind.normalize(String(repeating: "a", count: 300)).count, 256)
    }
}

final class CommandTests: XCTestCase {
    func testAcceleratorsBecomeMenuShortcuts() {
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Return"), KeyboardShortcut(.return, modifiers: .command))
        XCTAssertEqual(MenuCommand.shortcut(for: "Ctrl+Shift+Return"), KeyboardShortcut(.return, modifiers: [.control, .shift]))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Plus"), KeyboardShortcut("=", modifiers: .command))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Shift+\\"), KeyboardShortcut("\\", modifiers: [.command, .shift]))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Alt+F"), KeyboardShortcut("f", modifiers: [.command, .option]))
    }

    func testEveryAcceleratorParses() {
        for command in MenuCommand.allCases {
            for accel in [command.accel, command.macAccel].compactMap(\.self) {
                XCTAssertNotNil(MenuCommand.shortcut(for: accel), command.rawValue)
            }
        }
    }

    func testTheEditorKeepsTheChordsItImplements() {
        let ids = Set(MenuCommand.editorHostKeys.map(\.id))
        XCTAssertTrue(ids.contains("compile.run"))
        XCTAssertTrue(ids.contains("edit.gotoLine"))
        XCTAssertTrue(ids.contains("view.zoomIn"))
        XCTAssertFalse(ids.contains("edit.find"))
        XCTAssertFalse(ids.contains("edit.findNext"))
        XCTAssertFalse(ids.contains("edit.findPrevious"))
        XCTAssertFalse(ids.contains("edit.comment"))
        XCTAssertFalse(ids.contains("edit.undo"))
        XCTAssertFalse(ids.contains("edit.redo"))
        // The Mac's own chords, which the page would otherwise see first.
        for id in ["project.open", "edit.findAndReplace", "view.toggleInspector", "view.actualSize", "compile.stop",
                   "file.pageSetup", "file.print"] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }

    /// web/src/workspace.js as the test scheme's pre-action copies it into
    /// the scratch folder. The tests run inside TeXLocal.app, and reading the
    /// repository in ~/Documents from there asks macOS for Documents access
    /// again after every re-signing build, blocking the read until someone
    /// answers the prompt or it times out.
    private func webWorkspace() throws -> URL {
        let data = try XCTUnwrap(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        return URL(fileURLWithPath: data).appendingPathComponent("workspace.js")
    }

    /// The web's commands with no place in the Mac menus: Settings…, which the
    /// Settings scene adds with ⌘, itself, and the interface size, which on
    /// the Mac is the system's to set.
    private let webOnly: Set<String> = ["app.settings", "view.uiScaleUp", "view.uiScaleDown"]

    /// The Mac's commands the web has no need of: Open… reads a folder from
    /// disk, and the rest are its menu bar's own (Page Setup…, the
    /// inspector, Actual Size…).
    private let macOnly: Set<MenuCommand> = [.projectOpen, .filePageSetup, .filePrint, .editFindAndReplace,
                                              .viewToggleInspector, .viewToggleWordCount, .viewActualSize, .compileStop]

    /// The menu has every other command the web declares, with the same chord.
    func testTheMenuHasEveryWebCommand() throws {
        let source = try String(contentsOf: webWorkspace(), encoding: .utf8)
        var ids: Set<String> = []
        for line in source.split(separator: "\n") {
            guard let match = line.firstMatch(of: /\{ id: '([^']+)'/) else { continue }
            let id = String(match.1)
            ids.insert(id)
            guard !webOnly.contains(id) else { continue }
            let accel = line.firstMatch(of: /accel: '([^']+)'/)
                .map { String($0.1).replacingOccurrences(of: "\\\\", with: "\\") }
            XCTAssertEqual(MenuCommand(rawValue: id)?.accel, accel, id)
        }
        XCTAssertEqual(Set(MenuCommand.allCases.filter { !macOnly.contains($0) }.map(\.rawValue)), ids.subtracting(webOnly))
        XCTAssertTrue(macOnly.allSatisfy { !ids.contains($0.rawValue) })
    }
}

/// The menu bar the running app built, as AppKit sees it.
@MainActor
final class MenuBarTests: XCTestCase {
    private func items() -> [NSMenuItem] {
        func all(_ menu: NSMenu) -> [NSMenuItem] {
            // As AppKit asks before it shows a menu, for any filled in lazily.
            menu.delegate?.menuNeedsUpdate?(menu)
            return menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) }
        }
        return NSApp.mainMenu.map(all) ?? []
    }

    private func item(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        items().first { item in
            var mask = item.keyEquivalentModifierMask
            // AppKit also spells Shift as an upper-case key.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            return item.keyEquivalent.lowercased() == key && mask == modifiers
        }
    }

    func testTheSettingsSceneGivesCommandComma() {
        XCTAssertNotNil(item(","), "Settings… ⌘,")
    }

    func testUndoAndRedoAreTheAppsOwn() throws {
        // Not the standard undo:/redo: items, which ask WebKit's undo manager.
        XCTAssertNotEqual(try XCTUnwrap(item("z")).action, Selector(("undo:")))
        XCTAssertNotEqual(try XCTUnwrap(item("z", [.command, .shift])).action, Selector(("redo:")))
    }

    func testFindNextAndPreviousAreCommandG() throws {
        XCTAssertEqual(try XCTUnwrap(item("g")).title, "Find Next")
        XCTAssertEqual(try XCTUnwrap(item("g", [.command, .shift])).title, "Find Previous")
    }

    /// Apple's chords where the shared table's differ (`MenuCommand.macAccel`).
    func testTheViewMenuHasApplesChords() throws {
        XCTAssertTrue(try XCTUnwrap(item("s", [.command, .control])).title.hasSuffix("Sidebar"))
        XCTAssertEqual(try XCTUnwrap(item("0")).title, "Actual Size")
        XCTAssertEqual(try XCTUnwrap(item("9")).title, "Fit Width")
        XCTAssertEqual(try XCTUnwrap(item("9", [.command, .option])).title, "Fit Height")
    }

    /// TextEdit's and Xcode's: ⌘F Find…, ⌥⌘F Find and Replace…; Find in
    /// PDF… has no chord of its own.
    func testFindHasApplesChords() throws {
        XCTAssertEqual(try XCTUnwrap(item("f")).title, "Find…")
        XCTAssertEqual(try XCTUnwrap(item("f", [.command, .option])).title, "Find and Replace…")
        XCTAssertEqual(items().first { $0.title == "Find in PDF…" }?.keyEquivalent, "")
    }

    func testTheBottomPanelIsTheBuildPanel() throws {
        let title = try XCTUnwrap(item("l", [.command, .shift])).title
        XCTAssertTrue(["Show Build Panel", "Hide Build Panel"].contains(title), title)
    }

    /// The system's spelling commands, which the editor's WebKit spell
    /// checking answers to.
    func testSpellingIsInTheEditMenu() {
        XCTAssertNotNil(item(";"), "Check Document Now ⌘;")
        XCTAssertNotNil(item(":"), "Show Spelling and Grammar ⌘:")
    }
}

/// The menu bar's shape, as the HIG has it (The menu bar), in the running
/// app's menus.
@MainActor
struct MenuStructureTests {
    private func menu(_ title: String) throws -> NSMenu {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu, "\(title) menu")
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        func all(_ menu: NSMenu) -> [NSMenuItem] {
            menu.delegate?.menuNeedsUpdate?(menu)
            return menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) }
        }
        return try #require(all(menu).first { $0.title == title }, "\(title)")
    }

    /// The app's own menus between View and Window, Insert before Compile.
    @Test func theAppsMenusGoBetweenViewAndWindow() throws {
        let order = try #require(NSApp.mainMenu).items.map(\.title)
        let view = try #require(order.firstIndex(of: "View")), window = try #require(order.firstIndex(of: "Window"))
        #expect(Array(order[view...window]) == ["View", "Insert", "Compile", "Window"])
        #expect(try #require(order.firstIndex(of: "Format")) < view)
    }

    /// The system's text-editing items stay whole, the app's searches
    /// beside them: none of them lost to a group of the app's own.
    @Test func editKeepsTheSystemsTextItems() throws {
        let edit = try menu("Edit")
        for title in ["Find", "Spelling and Grammar", "Substitutions", "Transformations", "Speech",
                      "Find in Project…", "Find in PDF…", "Go to Line…"] {
            #expect(titles(edit).contains(title), "\(title)")
        }
        let find = try item("Find", in: edit).submenu
        #expect(find.map(titles) == ["Find…", "Find and Replace…", "Find Next", "Find Previous",
                                     "Use Selection for Find", "Jump to Selection"])
        #expect(try item("Use Selection for Find", in: edit).keyEquivalent == "e")
        #expect(try item("Jump to Selection", in: edit).keyEquivalent == "j")
        #expect(try item("Check Spelling While Typing", in: edit).action == #selector(NSTextView.toggleContinuousSpellChecking(_:)))
    }

    /// Format holds the text's attributes; what inserts text is Insert's.
    @Test func formatStylesAndInsertInserts() throws {
        let format = try menu("Format"), insert = try menu("Insert")
        #expect(titles(format) == ["Bold", "Italic", "Section Level", "Comment Selection"])
        #expect(titles(insert).starts(with: ["Inline Math", "Display Math", "Symbols", "Reference"]))
        #expect(titles(insert).contains("Figure"))
    }

    /// Each Mac command has its HIG chord in the menu.
    @Test func theMacsCommandsHaveTheirChords() throws {
        let file = try menu("File"), view = try menu("View"), compile = try menu("Compile")
        #expect(try item("Open…", in: file).keyEquivalent == "o")
        #expect(try item("Print…", in: file).keyEquivalent == "p")
        let setup = try item("Page Setup…", in: file)
        // AppKit also spells Shift as an upper-case key.
        #expect(setup.keyEquivalent.lowercased() == "p"
                && (setup.keyEquivalent == "P" || setup.keyEquivalentModifierMask.contains(.shift)))
        let inspector = try #require(view.items.first { $0.title.hasSuffix("Inspector") })
        #expect(inspector.keyEquivalent == "i" && inspector.keyEquivalentModifierMask == [.command, .option])
        #expect(try item("Stop", in: compile).keyEquivalent == ".")
    }

    /// Share… as the HIG names it, there even with nothing to share.
    @Test func shareIsOneItem() throws {
        let file = try menu("File")
        #expect(file.items.filter { $0.title.hasPrefix("Share") }.map(\.title) == ["Share…"])
    }
}

/// Edit › Find's items reach the pane with the keyboard through
/// `FindMenuResponder`, by the item's tag.
@MainActor
struct FindMenuResponderTests {
    @Test func theItemsTagPicksTheAction() {
        let responder = FindMenuResponder.Responder()
        var done: [NSTextFinder.Action] = []
        responder.find = { action in action == .showReplaceInterface ? nil : { done.append(action) } }
        let item = NSMenuItem(title: "Find Next", action: #selector(FindMenuResponder.Responder.performFindPanelAction(_:)),
                              keyEquivalent: "g")
        item.tag = NSTextFinder.Action.nextMatch.rawValue
        #expect(responder.validateMenuItem(item))
        responder.performFindPanelAction(item)
        #expect(done == [.nextMatch])
        // A Find the pane can't do is off.
        item.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        #expect(!responder.validateMenuItem(item))
    }

    /// It joins its window's responder chain, after the window, and leaves
    /// it as it was.
    @Test func itJoinsAndLeavesTheResponderChain() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
        let next = NSResponder()
        window.nextResponder = next
        let anchor = FindMenuResponder.Anchor()
        window.contentView?.addSubview(anchor)
        #expect(window.nextResponder === anchor.responder)
        #expect(anchor.responder.nextResponder === next)
        anchor.removeFromSuperview()
        #expect(window.nextResponder === next)
    }

    /// A find bar's field leaves the Find items to its pane; a filter's
    /// keeps the window's field editor.
    @Test func aFindBarsFieldPassesFindOn() {
        let find = SearchField.FocusingSearchField(), window = NSWindow()
        let cell = find.cell as? SearchField.FindFieldCell
        cell?.passesFind = true
        let editor = cell?.fieldEditor(for: find)
        #expect(editor?.isFieldEditor == true)
        #expect(editor?.responds(to: #selector(NSTextView.performFindPanelAction(_:))) == false)
        #expect(editor?.responds(to: #selector(NSTextView.centerSelectionInVisibleArea(_:))) == true)
        cell?.passesFind = false
        window.contentView?.addSubview(find)
        #expect(cell?.fieldEditor(for: find) !== editor)
    }
}

@MainActor
final class CoreTests: XCTestCase {
    func testCommandsRoundTripThroughTheRustCore() async throws {
        // The test scheme points TEXLOCAL_DATA at a scratch folder.
        XCTAssertNotNil(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        let core = Core.shared
        let name = "XCTest \(UUID().uuidString.prefix(8))"
        let info = try await core.call("create_project", ["name": name, "template": "blank"], as: ProjectInfo.self)
        XCTAssertEqual(info.mainFile, "main.tex")

        try await core.perform("write_file", ["id": info.id, "path": "a.tex", "text": "hé"])
        let file = try await core.call("read_file", ["id": info.id, "path": "a.tex"], as: FileText.self)
        XCTAssertEqual(file.text, "hé")

        let tree = try await core.call("file_tree", ["id": info.id], as: [TreeNode].self)
        XCTAssertTrue(tree.contains { $0.path == "a.tex" })

        do {
            _ = try await core.call("read_file", ["id": info.id, "path": "../../x"], as: FileText.self)
            XCTFail("a path outside the project must be refused")
        } catch let error as CoreError {
            XCTAssertEqual(error.status, 400)
        }

        // Not delete_project: it moves the folder to the Trash through Finder,
        // which a headless test host cannot drive. The core's own tests cover
        // that path; here the scratch project is simply removed.
        let data = try XCTUnwrap(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: data).appendingPathComponent(info.id))
    }
}

/// Two opens that overlap — the project restored at launch and an Open With
/// import, or quick successive opens — leave the editor on the one opened
/// last, never on the other's text.
@MainActor
struct OpenRaceTests {
    @Test(.timeLimit(.minutes(1)))
    func theLastOpenHasTheEditor() async throws {
        // What `AppModel` writes to the app's defaults, put back after.
        let defaults = UserDefaults.standard
        let keys = ["autoCompile", "recentProjects"]
        let kept = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) } }

        let core = Core.shared
        func project(_ text: String) async throws -> ProjectInfo {
            let name = "Race \(UUID().uuidString.prefix(8))"
            let info = try await core.call("create_project", ["name": name, "template": "blank"], as: ProjectInfo.self)
            try await core.perform("write_file", ["id": info.id, "path": info.mainFile, "text": text])
            return info
        }
        let first = try await project("first"), second = try await project("second")
        // Removed rather than trashed, as `CoreTests` explains.
        let data = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"]))
        defer { for info in [first, second] { try? FileManager.default.removeItem(at: data.appendingPathComponent(info.id)) } }

        let app = AppModel()
        app.autoCompile = false
        // Started in this order on the main actor, each waiting on the core
        // and the editor's page in turn.
        let opens = [Task { await app.open(first.id) }, Task { await app.open(second.id) }]
        for open in opens { await open.value }

        #expect(app.project?.id == second.id)
        #expect(await app.editor.text() == "second")
        await app.close()
    }
}
