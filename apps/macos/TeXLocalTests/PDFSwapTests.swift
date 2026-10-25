import AppKit
import PDFKit
import Testing
@testable import TeXLocal

/// The pane never flashes empty, as a new document would, and nothing on the pages leads back to the old ones.
struct PDFSwapTests {
    private func document(_ pages: [String]) throws -> PDFDocument {
        try textPDF(pages.map { String(repeating: $0 + " ", count: 200) })
    }

    private func page(_ text: String) throws -> PDFPage {
        try #require(try document([text]).page(at: 0))
    }

    private func paper(_ view: NSView) -> Int {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: image)
        return stride(from: 0, to: image.pixelsHigh, by: 8).reduce(0) { count, y in
            count + stride(from: 0, to: image.pixelsWide, by: 8).count { (image.colorAt(x: $0, y: y)?.brightnessComponent ?? 0) > 0.92 }
        }
    }

    /// PDFKit draws pages only once the view is in an on-screen window.
    private func onScreen(_ controller: PDFController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFrontUnseen()
        return window
    }

    private func live(_ pages: [String], changed: IndexSet) throws -> LiveRead {
        .document(LiveDocument(document: try document(pages), changed: changed, complete: true))
    }

    private func text(_ view: PDFView) -> [String] {
        guard let document = view.document else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string?.components(separatedBy: " ").first ?? "" }
    }

    /// A new document would show only PDFKit's background until its pages draw; the pages go into the one showing instead.
    @Test func aRebuildNeverShowsAnEmptyPane() async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        controller.show(try document(["first"]))
        try await waitUntil(timeout: .seconds(5)) { paper(view) > 0 }
        let shown = try #require(view.document)
        // Back to back, as live preview writes them while typing.
        for index in 0..<3 {
            controller.show(try document(["rebuild\(index)"]))
            #expect(view.document === shown && text(view) == ["rebuild\(index)"] && controller.pageCount == 1)
        }
        let start = ContinuousClock.now
        var samples: [Int] = []
        while ContinuousClock.now - start < .milliseconds(400) {
            samples.append(paper(view))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!samples.contains(0), "samples \(samples)")
    }

    @Test func aLiveDocumentTakesOnlyThePagesThatChanged() throws {
        let controller = showing(try document(["a", "b", "c", "d"])), view = controller.view
        controller.go(toPage: 3)
        let shown = try #require(view.document), first = shown.page(at: 0), version = controller.shownVersion
        controller.showLive(try document(["a2", "b2"]), changed: [1], complete: false)
        #expect(text(view) == ["a", "b2", "c", "d"])
        #expect(shown.page(at: 0) === first && view.document === shown && controller.page == 3 && controller.pageCount == 4)
        controller.showLive(try document(["a3", "b3", "c3"]), changed: [2], complete: true)
        #expect(text(view) == ["a", "b2", "c3"] && controller.pageCount == 3)
        controller.showLive(try document(["a4", "b4", "c4", "d4", "e4"]), changed: [3, 4], complete: true)
        #expect(text(view) == ["a", "b2", "c3", "d4", "e4"] && controller.pageCount == 5)
        // A forward search under way still lands: these are the pages it was asked about.
        #expect(controller.shownVersion == version && shown.page(at: 0) === first)
        controller.showLive(try document(["x"]), changed: nil, complete: true)
        #expect(text(view) == ["x"] && view.document === shown)
    }

    @Test func aLiveDocumentAfterOneNotReadTakesEveryPage() throws {
        let controller = showing(try document(["a", "b"])), view = controller.view
        let shown = try #require(view.document)
        controller.showLive(.document(nil))
        controller.showLive(try live(["a2", "b2"], changed: [1]))
        #expect(text(view) == ["a2", "b2"] && view.document === shown)
        controller.showLive(try live(["a3", "b3"], changed: [1]))
        #expect(text(view) == ["a2", "b3"])
        // A page past the document showing goes: the next document has it.
        controller.showLive(.page(LivePage(index: 2, page: try page("c"))))
        #expect(text(view) == ["a2", "b3"] && controller.pageCount == 2)
    }

    @Test func aLivePageWaitsForItsOwnRunsDocument() throws {
        let controller = showing(try document(["a", "b"])), view = controller.view
        func first(_ text: String) throws -> LiveRead { .page(LivePage(index: 0, page: try page(text))) }
        // Not over the build's PDF. Out of a window, a page PDFKit's document takes at once.
        controller.showLive(try first("a1"))
        #expect(text(view) == ["a", "b"])
        controller.showLive(try live(["a2", "b2"], changed: [1]))
        controller.showLive(try first("a3"))
        #expect(text(view) == ["a3", "b2"])
        // Nor over the last run's; and that run's unread document leaves the next run's first its own changes.
        controller.showLive(.document(nil))
        controller.endLiveRun()
        controller.showLive(try first("a4"))
        #expect(text(view) == ["a3", "b2"])
        controller.showLive(try live(["a5", "b5"], changed: [1]))
        #expect(text(view) == ["a3", "b5"])
    }

    @Test func aLivePageUpdatesTheDocumentAndPreservesOtherSelections() async throws {
        let controller = showing(try document(["alpha", "beta", "alpha"])), view = controller.view
        let shown = try #require(view.document)
        openFind("alpha", in: controller)
        try await waitUntil(timeout: .seconds(5)) { controller.find.matches.count == 400 }
        let selection = try #require(shown.page(at: 1)?.selection(for: NSRange(location: 0, length: 4)))
        view.setCurrentSelection(selection, animate: false)
        controller.showLive(try page("gamma"), at: 0)
        #expect(text(view) == ["gamma", "beta", "alpha"])
        #expect(view.currentSelection?.string == "beta" && controller.find.matches.count == 200)
        try await waitUntil(timeout: .seconds(5)) { view.highlightedSelections?.count == 200 }
        controller.showLive(try page("alpha"), at: 1)
        #expect(view.currentSelection == nil)
        try await waitUntil(timeout: .seconds(5)) { controller.find.matches.count == 400 }
    }

    @Test func aLongLiveUpdateYieldsAndKeepsNewerPages() async throws {
        func many(_ text: String) throws -> PDFDocument {
            let page = try page(text), document = PDFDocument()
            for index in 0..<100 { document.insert(try #require(page.copy() as? PDFPage), at: index) }
            return document
        }
        let controller = showing(try many("original"))
        controller.showLive(try many("updated"), changed: IndexSet(integersIn: 0..<100), complete: true)
        #expect(text(controller.view).last == "original")
        controller.showLive(try many("latest"), changed: [0], complete: true)
        controller.showLive(try page("streamed"), at: 90)
        try await waitUntil { controller.livePending == nil }
        let shown = text(controller.view)
        #expect(shown[0] == "latest" && shown[1] == "updated" && shown[99] == "latest")
        #expect(shown[90] == "streamed")
        controller.showLive(try many("cancelled"), changed: IndexSet(integersIn: 0..<100), complete: true)
        controller.show(try document(["build"]))
        await settle()
        #expect(text(controller.view) == ["build"])
    }

    @Test(arguments: [false, true]) func aGrowingLiveDocumentKeepsStreamedPagesUntilTheyCanBeInserted(complete: Bool) async throws {
        var expected = (0..<100).map { "page\($0)" }
        let controller = showing(try document(["original"]))
        defer { controller.endLiveRun() }
        controller.showLive(try document(expected), changed: IndexSet(integersIn: 0..<expected.count), complete: complete)
        try #require(controller.pageCount <= 90)
        controller.showLive(try page("streamed"), at: 90)
        try await waitUntil { controller.livePending == nil }
        expected[90] = "streamed"
        #expect(text(controller.view) == expected && controller.pageCount == expected.count)
    }

    @Test func aDocumentIsShownWholeOnceTheAppHasGrown() throws {
        let controller = sizedController(), view = controller.view
        controller.show(try document(["a", "b"]))
        let first = try #require(view.document)
        controller.showLive(try document(["a2", "b"]), changed: [0], complete: true)
        #expect(view.document === first && text(view) == ["a2", "b"])
        controller.wholeAt = 0
        // TeX stopped short of the end: the pages past there aren't in its document.
        controller.showLive(try document(["a3"]), changed: [0], complete: false)
        #expect(view.document === first && text(view) == ["a3", "b"])
        let whole = try document(["a4", "b4"])
        controller.showLive(whole, changed: [0], complete: true)
        #expect(view.document === whole && text(view) == ["a4", "b4"])
        // Counted from there on.
        controller.showLive(try document(["a5", "b4"]), changed: [0], complete: true)
        #expect(view.document === whole && text(view) == ["a5", "b4"])
        controller.wholeAt = 0
        let build = try document(["c"])
        controller.show(build)
        #expect(view.document === build)
    }

    @Test func linksLeadToThePagesShowing() throws {
        func linked() throws -> PDFDocument {
            let source = try document(["one", "two"])
            let target = try #require(source.page(at: 1)), page = try #require(source.page(at: 0))
            let link = PDFAnnotation(bounds: CGRect(x: 72, y: 72, width: 100, height: 20), forType: .link, withProperties: nil)
            link.destination = PDFDestination(page: target, at: CGPoint(x: 0, y: 792))
            page.addAnnotation(link)
            // As a build writes it, read back.
            let data = try #require(source.dataRepresentation())
            return try #require(PDFDocument(data: data))
        }
        let controller = showing(try linked()), view = controller.view
        controller.show(try linked())
        let shown = try #require(view.document)
        let link = try #require(shown.page(at: 0)?.annotations.first { $0.type == "Link" })
        let target = try #require(link.destination?.page ?? (link.action as? PDFActionGoTo)?.destination.page)
        #expect(target === shown.page(at: 1))
    }
}
