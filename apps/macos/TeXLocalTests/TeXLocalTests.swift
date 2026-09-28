import SwiftUI
import Testing
import XCTest
@testable import TeXLocal

struct TimedOut: Error {}

/// Polls `condition` on the main actor until it holds; throws once `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
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

/// The counting rules are the core's (tests/fixtures/analyze.json); these
/// check what the views make of its outline.
@MainActor
final class OutlineTests: XCTestCase {
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

/// The accessory bars measured off screen, with no window shown.
@MainActor
struct PaneBarLayoutTests {
    private func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.paneBarControls()).fittingSize.height
    }

    @Test func aBarIsARegularControlAndItsInsets() {
        #expect(height(PaneBar { Button("Done") {} }) == regularControlHeight() + 2 * BarMetrics.inset)
    }

    /// A control group draws a little taller than a button, but still inside the bar.
    @Test func everyControlFitsTheBar() {
        let bar = height(PaneBar { Button("Done") {} })
        let steps = ControlGroup {
            Button("Previous Match", systemImage: "chevron.up") {}
            Button("Next Match", systemImage: "chevron.down") {}
        }.fixedSize()
        let copy = Button("Copy Log", systemImage: "document.on.document") {}
            .buttonStyle(.accessoryBar).labelStyle(.iconOnly)
        for control in [height(steps), height(copy), height(Button("Done") {})] {
            #expect(control <= bar - 2 * BarMetrics.spacing)
        }
    }
}

/// A regular push button's fitting height, as the system draws it.
@MainActor
func regularControlHeight() -> CGFloat {
    NSHostingView(rootView: Button("Done") {}.controlSize(.regular)).fittingSize.height
}

@MainActor
struct FindBarTests {
    /// One row is a pane bar's height; the replace row adds at least a control's.
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
        let control = regularControlHeight()
        let one = NSHostingView(rootView: find.frame(width: 400)).fittingSize.height
        let two = NSHostingView(rootView: replace.frame(width: 400)).fittingSize.height
        #expect(one == control + 2 * BarMetrics.inset)
        #expect(two >= one + control)
    }
}

/// The project folder's watcher: a write in place, a save over a file (a new
/// one renamed over it) and a delete then recreate are all told, by path;
/// items coming and going in a subfolder are told as structural.
@MainActor
final class FolderWatcherTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A watcher of the folder, and the changes it has told about `path`.
    private func watch(_ path: String) -> (FolderWatcher, () -> [FolderWatcher.Change]) {
        var told: [FolderWatcher.Change] = []
        let watcher = FolderWatcher(folder: folder) { told += $0 }
        return (watcher, { told.filter { watcher.relativePath($0.path) == path } })
    }

    func testChangesInPlaceAndByReplacementAreBothTold() async throws {
        let url = folder.appending(path: "main.tex")
        try "one".write(to: url, atomically: false, encoding: .utf8)
        let (watcher, changes) = watch("main.tex")

        try "two".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { !changes().isEmpty }
        let inPlace = changes().count
        try "three".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil { changes().count > inPlace }
        // Still watching the new file at that path.
        let replaced = changes().count
        try "four".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes().count > replaced }
        _ = watcher
    }

    func testAFileDeletedThenRecreatedIsStillTold() async throws {
        let url = folder.appending(path: "main.tex")
        try "one".write(to: url, atomically: false, encoding: .utf8)
        let (watcher, changes) = watch("main.tex")

        try FileManager.default.removeItem(at: url)
        try await waitUntil { changes().contains(where: \.structural) }
        // Past the watcher's settle time, so the recreate is an event of its own.
        try await Task.sleep(for: .milliseconds(500))
        let deleted = changes().count
        try "two".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes().count > deleted }
        _ = watcher
    }

    func testAnItemAddedInASubfolderIsStructural() async throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "chapters"), withIntermediateDirectories: true)
        let (watcher, changes) = watch("chapters/one.tex")

        try "text".write(to: folder.appending(path: "chapters/one.tex"), atomically: false, encoding: .utf8)
        try await waitUntil { changes().contains(where: \.structural) }
        _ = watcher
    }
}

@MainActor
final class SplitControllerTests: XCTestCase {
    /// The window holding the test's split, and the autosave to forget.
    private var window: NSWindow?
    private var autosave = ""

    // Async, so XCTest runs it on the main actor, where the window is.
    override func tearDown() async throws {
        window?.close()
        // Out of its window, the split stores no more sizes (a hide still finishing).
        window?.contentViewController = nil
        UserDefaults.standard.removeObject(forKey: PaneSizes.key(autosave))
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
}

/// The sidebar's split (Files over the File Outline), a plain NSSplitView.
@MainActor
final class SidebarSplitTests: XCTestCase {
    /// The window holding the test's split (a view doesn't keep its window).
    private var window: NSWindow?
    private var autosave = ""

    override func tearDown() async throws {
        window?.close()
        UserDefaults.standard.removeObject(forKey: PaneSizes.key(autosave))
        try await super.tearDown()
    }

    /// Two panes in a split of `size` in a window, the second dragged to
    /// `last` points. Sized before the drag: macOS 26's `setPosition` doesn't
    /// lay out panes added since the last layout.
    private func split(_ size: NSSize, _ panes: [SidebarPane],
                       last: CGFloat) -> (NSSplitView, SidebarSplitCoordinator) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 1200),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        autosave = "SidebarSplitTests \(UUID())"
        let coordinator = SidebarSplitCoordinator(autosave: autosave)
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
    /// the sizes it saved forgotten.
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
        UserDefaults.standard.removeObject(forKey: PaneSizes.key(autosave))
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
        let fold = OutlineFold(collapsed: false)
        #expect(fold.rowsShown)
        fold.slid(folded: true)
        #expect(fold.rowsShown)
        fold.collapsed = true
        fold.slid(folded: true)
        #expect(!fold.rowsShown)
        fold.collapsed = false
        fold.slid(folded: false)
        #expect(fold.rowsShown)
    }
}

@MainActor
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

/// The gallery's and the sidebar's rename in place.
@MainActor
struct InPlaceRenameTests {
    @Test func aRenameEndsOnceWithItsNewName() {
        let rename = InPlaceRename<String>()
        rename.begin("ch/intro.tex", name: "intro.tex")
        rename.name = "  start.tex "
        #expect(rename.end("ch/intro.tex", from: "intro.tex") == "start.tex")
        #expect(rename.id == nil)
        // Return, then the field losing focus as it goes: the second finds
        // the rename over.
        #expect(rename.end("ch/intro.tex", from: "intro.tex") == nil)
    }

    @Test func anEmptyOrUnchangedNameRenamesNothing() {
        let rename = InPlaceRename<String>()
        for name in ["   ", "intro.tex"] {
            rename.begin("intro.tex", name: "intro.tex")
            rename.name = name
            #expect(rename.end("intro.tex", from: "intro.tex") == nil)
            #expect(rename.id == nil)
        }
    }

    @Test func anotherRowLeavesTheRenameOpen() {
        let rename = InPlaceRename<String>()
        rename.begin("a.tex", name: "a.tex")
        rename.name = "b.tex"
        #expect(rename.end("c.tex", from: "c.tex") == nil)
        #expect(rename.id == "a.tex")
    }
}

@MainActor
final class FindTests: XCTestCase {
    func testTheMatchCountLabel() {
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

@MainActor
final class CommandTests: XCTestCase {
    func testAcceleratorsBecomeMenuShortcuts() {
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Return"), KeyboardShortcut(.return, modifiers: .command))
        XCTAssertEqual(MenuCommand.shortcut(for: "Ctrl+Shift+Return"), KeyboardShortcut(.return, modifiers: [.control, .shift]))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Plus"), KeyboardShortcut("=", modifiers: .command))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Shift+\\"), KeyboardShortcut("\\", modifiers: [.command, .shift]))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Alt+F"), KeyboardShortcut("f", modifiers: [.command, .option]))
    }

    /// The build copies the shared table in; without it every shared chord is gone.
    func testTheSharedTableIsInTheApp() {
        XCTAssertEqual(MenuCommand.compileRun.accel, "CmdOrCtrl+Return")
        XCTAssertEqual(MenuCommand.editBold.shortcut, KeyboardShortcut("b", modifiers: .command))
    }

    func testEveryAcceleratorParses() {
        for command in MenuCommand.allCases {
            for accel in [command.accel, command.macAccel].compactMap(\.self) {
                XCTAssertNotNil(MenuCommand.shortcut(for: accel), command.rawValue)
            }
        }
    }

    func testNoTwoCommandsShareAMacChord() {
        var seen: [KeyboardShortcut: MenuCommand] = [:]
        for command in MenuCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            XCTAssertNil(seen[shortcut], "\(command.rawValue) and \(seen[shortcut]?.rawValue ?? "")")
            seen[shortcut] = command
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

    /// web/src/workspace.js, copied into the scratch folder by the test scheme:
    /// reading ~/Documents from the test host prompts for access after every build.
    private func webWorkspace() throws -> URL {
        let data = try XCTUnwrap(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        return URL(fileURLWithPath: data).appendingPathComponent("workspace.js")
    }

    /// Settings… is the Settings scene's own; the interface size is the system's.
    private let webOnly: Set<String> = ["app.settings", "view.uiScaleUp", "view.uiScaleDown"]

    /// Open… reads a folder from disk; the rest are the Mac menu bar's own.
    private let macOnly: Set<MenuCommand> = [.projectOpen, .filePageSetup, .filePrint, .editFindAndReplace,
                                              .viewToggleProjectSettings, .viewToggleWordCount, .viewActualSize,
                                              .compileStop]

    /// The menu has every other command the web declares. Their chords are
    /// the one table both read (web/src/shortcuts.json).
    func testTheMenuHasEveryWebCommand() throws {
        let source = try String(contentsOf: webWorkspace(), encoding: .utf8)
        var ids: Set<String> = []
        for line in source.split(separator: "\n") {
            guard let match = line.firstMatch(of: /\{ id: '([^']+)'/) else { continue }
            ids.insert(String(match.1))
        }
        XCTAssertEqual(Set(MenuCommand.allCases.filter { !macOnly.contains($0) }.map(\.rawValue)), ids.subtracting(webOnly))
        XCTAssertTrue(macOnly.allSatisfy { !ids.contains($0.rawValue) })
    }
}

/// The running app's menu bar (HIG, The menu bar).
@MainActor
struct MenuStructureTests {
    /// Every item under `menu`, filled in as AppKit fills lazy menus before showing them.
    private func all(_ menu: NSMenu) -> [NSMenuItem] {
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) }
    }

    private func menu(_ title: String) throws -> NSMenu {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu, "\(title) menu")
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try #require(all(menu).first { $0.title == title }, "\(title)")
    }

    /// The item with this chord anywhere in the menu bar.
    private func item(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSMenuItem {
        let items = NSApp.mainMenu.map(all) ?? []
        return try #require(items.first { item in
            var mask = item.keyEquivalentModifierMask
            // AppKit also spells Shift as an upper-case key.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            return item.keyEquivalent.lowercased() == key && mask == modifiers
        }, "\(modifiers) \(key)")
    }

    @Test func undoAndRedoAreTheAppsOwn() throws {
        // Not the standard undo:/redo:, which ask WebKit's undo manager.
        #expect(try item("z").action != Selector(("undo:")))
        #expect(try item("z", [.command, .shift]).action != Selector(("redo:")))
    }

    @Test func findNextAndPreviousAreCommandG() throws {
        #expect(try item("g").title == "Find Next")
        #expect(try item("g", [.command, .shift]).title == "Find Previous")
    }

    /// The Mac's chords where the shared table's differ (`MenuCommand.macAccel`).
    @Test func theViewMenuHasTheMacsChords() throws {
        #expect(try item("s", [.command, .control]).title.hasSuffix("Sidebar"))
        #expect(try item("0").title == "Actual Size")
        #expect(try item("9").title == "Fit Width")
        #expect(try item("9", [.command, .option]).title == "Fit Height")
    }

    /// Find in PDF… has no chord of its own: ⌥⌘F is Find and Replace….
    @Test func findHasTheMacsChords() throws {
        #expect(try item("f").title == "Find…")
        #expect(try item("f", [.command, .option]).title == "Find and Replace…")
        #expect(try item("Find in PDF…", in: menu("Edit")).keyEquivalent == "")
    }

    @Test func theBottomPanelIsTheBuildPanel() throws {
        let title = try item("l", [.command, .shift]).title
        #expect(["Show Build Panel", "Hide Build Panel"].contains(title), "\(title)")
    }

    /// The system's spelling commands, which WebKit's spell checking answers.
    @Test func spellingIsInTheEditMenu() throws {
        _ = try item(";")
        _ = try item(":")
    }

    @Test func theAppsMenusGoBetweenViewAndWindow() throws {
        let order = try #require(NSApp.mainMenu).items.map(\.title)
        let view = try #require(order.firstIndex(of: "View")), window = try #require(order.firstIndex(of: "Window"))
        #expect(Array(order[view...window]) == ["View", "Insert", "Compile", "Window"])
        #expect(try #require(order.firstIndex(of: "Format")) < view)
    }

    /// None of the system's text-editing items lost to a group of the app's own.
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

    /// The Mac-only commands have their HIG chords (HIG, Keyboards).
    @Test func theMacsCommandsHaveTheirChords() throws {
        let file = try menu("File"), view = try menu("View"), compile = try menu("Compile")
        #expect(try item("Open…", in: file).keyEquivalent == "o")
        #expect(try item("Print…", in: file).keyEquivalent == "p")
        let setup = try item("Page Setup…", in: file)
        #expect(setup.keyEquivalent.lowercased() == "p"
                && (setup.keyEquivalent == "P" || setup.keyEquivalentModifierMask.contains(.shift)))
        let settings = try #require(view.items.first { $0.title.hasSuffix("Project Settings") })
        #expect(settings.keyEquivalent == "i" && settings.keyEquivalentModifierMask == [.command, .option])
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
    @Test func aFindBarsFieldPassesFindOn() throws {
        let find = SearchField.FocusingSearchField(), window = NSWindow()
        let cell = find.cell as? SearchField.FindFieldCell
        cell?.passesFind = true
        let editor = try #require(cell?.fieldEditor(for: find))
        #expect(editor.isFieldEditor)
        let pane = FindMenuResponder.Responder()
        var done: [NSTextFinder.Action] = []
        pane.find = { action in action == .showReplaceInterface ? nil : { done.append(action) } }
        editor.nextResponder = pane
        let item = NSMenuItem(title: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)),
                              keyEquivalent: "g")
        item.tag = NSTextFinder.Action.nextMatch.rawValue
        #expect(editor.validateMenuItem(item))
        editor.performFindPanelAction(item)
        #expect(done == [.nextMatch])
        item.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        #expect(!editor.validateMenuItem(item))
        editor.nextResponder = nil
        cell?.passesFind = false
        window.contentView?.addSubview(find)
        #expect(cell?.fieldEditor(for: find) !== editor)
    }
}

@MainActor
final class CoreTests: XCTestCase {
    func testCommandsRoundTripThroughTheRustCore() async throws {
        // The test scheme points TEXLOCAL_DATA at a scratch library.
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

        // Not delete_project: it trashes through Finder, which a headless
        // test host can't drive. The core's own tests cover it.
        try FileManager.default.removeItem(at: Core.libraryFolder.appending(path: info.id))
    }

    /// Every template the projects screen offers is one the core can make.
    func testEveryTemplateMakesAProject() async throws {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        for template in ProjectTemplate.all {
            let name = "XCTest \(template.id) \(UUID().uuidString.prefix(8))"
            let info = try await Core.shared.call("create_project", ["name": name, "template": template.id],
                                                  as: ProjectInfo.self)
            try FileManager.default.removeItem(at: Core.libraryFolder.appending(path: info.id))
        }
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
        let keys = [DefaultsKey.autoCompile, DefaultsKey.recentProjects]
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
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        defer { for info in [first, second] { try? FileManager.default.removeItem(at: Core.libraryFolder.appending(path: info.id)) } }

        let app = AppModel()
        app.autoCompile = false
        // Started in this order on the main actor, each waiting on the core
        // and the editor's page in turn.
        let opens = [Task { await app.open(first.id) }, Task { await app.open(second.id) }]
        for open in opens { await open.value }

        #expect(app.project?.id == second.id)
        let document = await app.project?.editor.document()
        #expect(document?.path == second.mainFile)
        #expect(document?.text == "second")
        await app.close()
    }
}

/// A save writes the page's text to the file the page says it belongs to.
@MainActor
struct SaveTests {
    @Test(.timeLimit(.minutes(1)))
    func anEditReachesTheDisk() async throws {
        let defaults = UserDefaults.standard
        let keys = [DefaultsKey.autoCompile, DefaultsKey.recentProjects]
        let kept = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) } }

        let core = Core.shared
        let info = try await core.call("create_project", ["name": "Save \(UUID().uuidString.prefix(8))", "template": "blank"],
                                       as: ProjectInfo.self)
        try await core.perform("write_file", ["id": info.id, "path": info.mainFile, "text": "text"])
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        let folder = Core.libraryFolder.appending(path: info.id)
        defer { try? FileManager.default.removeItem(at: folder) }

        let app = AppModel()
        app.autoCompile = false
        await app.open(info.id)
        let project = try #require(app.project)
        #expect(await project.editor.command(.bold))
        try await waitUntil { project.hasUnsavedText }
        #expect(await project.save())
        let saved = try String(contentsOf: folder.appending(path: info.mainFile), encoding: .utf8)
        #expect(saved.contains("\\textbf{}"))
        await app.close()
    }
}

/// Files another app adds, renames or deletes show in the sidebar's tree.
@MainActor
struct TreeWatchTests {
    @Test(.timeLimit(.minutes(1)))
    func anotherAppsFilesComeAndGo() async throws {
        let defaults = UserDefaults.standard
        let keys = [DefaultsKey.autoCompile, DefaultsKey.recentProjects]
        let kept = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) } }

        let core = Core.shared
        let info = try await core.call("create_project", ["name": "Tree \(UUID().uuidString.prefix(8))", "template": "blank"],
                                       as: ProjectInfo.self)
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        let folder = Core.libraryFolder.appending(path: info.id)
        defer { try? FileManager.default.removeItem(at: folder) }

        let app = AppModel()
        app.autoCompile = false
        await app.open(info.id)
        let project = try #require(app.project)
        let paths = { Set(project.tree.flattened.map(\.path)) }
        let files = FileManager.default

        try "x".write(to: folder.appending(path: "notes.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { paths().contains("notes.tex") }
        try files.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: false)
        try files.moveItem(at: folder.appending(path: "notes.tex"), to: folder.appending(path: "parts/notes.tex"))
        try await waitUntil(timeout: .seconds(5)) { paths().contains("parts/notes.tex") && !paths().contains("notes.tex") }
        try files.removeItem(at: folder.appending(path: "parts"))
        try await waitUntil(timeout: .seconds(5)) { !paths().contains("parts") }
        await app.close()
    }

    /// Deleted by another app, the open file closes; with unsaved edits it asks
    /// first, saving nothing meanwhile, and Save Again makes it again.
    @Test(.timeLimit(.minutes(1)))
    func anOpenFileDeletedElsewhere() async throws {
        let defaults = UserDefaults.standard
        let keys = [DefaultsKey.autoCompile, DefaultsKey.recentProjects]
        let kept = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) } }

        let core = Core.shared
        let info = try await core.call("create_project", ["name": "Gone \(UUID().uuidString.prefix(8))", "template": "blank"],
                                       as: ProjectInfo.self)
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        let folder = Core.libraryFolder.appending(path: info.id)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appending(path: "notes.tex")
        try "notes".write(to: notes, atomically: false, encoding: .utf8)

        let app = AppModel()
        app.autoCompile = false
        await app.open(info.id)
        let project = try #require(app.project)

        await project.open("notes.tex")
        try FileManager.default.removeItem(at: notes)
        try await waitUntil(timeout: .seconds(5)) { project.openPath == nil }
        #expect(project.missingFile == nil)

        try "notes".write(to: notes, atomically: false, encoding: .utf8)
        await project.open("notes.tex")
        try FileManager.default.removeItem(at: notes)
        #expect(await project.editor.command(.bold))
        try await waitUntil(timeout: .seconds(5)) { project.missingFile == "notes.tex" }
        // Past the autosave, which would have made the file again.
        try await Task.sleep(for: .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: notes.path(percentEncoded: false)))
        project.saveMissingFile()
        try await waitUntil(timeout: .seconds(5)) { FileManager.default.fileExists(atPath: notes.path(percentEncoded: false)) }
        #expect(try String(contentsOf: notes, encoding: .utf8).contains("\\textbf{}"))
        await app.close()
    }
}
