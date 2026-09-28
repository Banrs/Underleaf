import SwiftUI
import Testing
import XCTest
@testable import TeXLocal

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
