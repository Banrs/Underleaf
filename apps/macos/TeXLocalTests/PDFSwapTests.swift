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

    /// In an on-screen window, unseen: PDFKit gives a page its overlay, which a live page is drawn over, only there.
    private func onScreen(_ controller: PDFController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFrontUnseen()
        return window
    }

    private func live(_ pages: [String], changed: IndexSet) throws -> LiveRead {
        .document(LiveDocument(url: URL(filePath: "/live.pdf"), document: try document(pages), changed: changed, complete: true))
    }

    private func text(_ view: PDFView) -> [String] {
        guard let document = view.document else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string?.components(separatedBy: " ").first ?? "" }
    }

    /// A new document would show only PDFKit's background until its pages draw; the pages go into the one showing
    /// instead. What reaches the screen is the on-screen checks' to see: a view's cached display has none of PDFKit's tiles.
    @Test(arguments: [1, 3]) func aRebuildKeepsTheDocumentShowing(rebuilds: Int) throws {
        let controller = PDFController(), view = controller.view
        view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try document(["first"]))
        let shown = try #require(view.document)
        // Back to back, as live preview writes them while typing.
        for index in 0..<rebuilds {
            controller.show(try document(["rebuild\(index)"]))
            #expect(view.document === shown && text(view) == ["rebuild\(index)"] && controller.pageCount == 1)
        }
    }

    @Test func aRebuildChangesThePageCount() throws {
        let controller = showing(try document(["a", "b", "c"])), view = controller.view
        controller.go(toPage: 2)
        controller.show(try document(["a2", "b2", "c2", "d2"]))
        #expect(text(view) == ["a2", "b2", "c2", "d2"] && controller.page == 2 && controller.pageCount == 4)
        controller.show(try document(["a3"]))
        #expect(text(view) == ["a3"] && controller.page == 1 && controller.pageCount == 1)
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

    @Test(arguments: [false, true])
    func aLivePageLeavesTheSelectionAndFindOnOtherPages(inView: Bool) async throws {
        let controller = inView ? PDFController() : sizedController(), view = controller.view
        let window = inView ? onScreen(controller) : nil
        defer { window?.close() }
        controller.show(try document(["alpha", "beta", "alpha"]))
        let shown = try #require(view.document)
        if inView {
            let first = try #require(shown.page(at: 0))
            try await waitUntil(timeout: .seconds(5)) { view.shownOverlay(of: first) != nil }
        }
        openFind("alpha", in: controller)
        try await waitUntil(timeout: .seconds(5)) { controller.find.matches.count == 400 }
        let selection = try #require(shown.page(at: 1)?.selection(for: NSRange(location: 0, length: 4)))
        view.setCurrentSelection(selection, animate: false)
        controller.showLive(try page("gamma"), at: inView ? 0 : 2)
        if inView {
            // Over the page, which PDFKit's document still has as it was.
            #expect(view.hasLive(at: 0) && text(view) == ["alpha", "beta", "alpha"])
            #expect(view.currentSelection?.string == "beta" && controller.find.matches.count == 400)
            controller.showLive(try document(["gamma", "beta", "alpha"]), changed: [0], complete: true)
            #expect(text(view) == ["gamma", "beta", "alpha"] && view.document === shown)
        } else {
            // Out of view, so PDFKit's document takes it at once.
            #expect(text(view) == ["alpha", "beta", "gamma"])
        }
        #expect(view.currentSelection?.string == "beta" && controller.find.matches.count == 200)
        try await waitUntil(timeout: .seconds(5)) { controller.find.query == "alpha" && view.highlightedSelections?.count == 200 }
        #expect(view.currentSelection?.string == "beta")
        if inView {
            // The layer goes once PDFKit's own page has drawn beneath it.
            try await waitUntil(timeout: .seconds(5)) { !view.hasLive(at: 0) }
        } else {
            controller.showLive(try page("alpha"), at: 1)
            #expect(view.currentSelection == nil)
            try await waitUntil(timeout: .seconds(5)) { controller.find.matches.count == 400 }
        }
    }

    @Test func aDocumentIsShownWholeOnceTheAppHasGrown() throws {
        let controller = sizedController(), view = controller.view
        var memory: UInt64 = 1 << 30
        controller.memory = { memory }
        controller.show(try document(["a", "b"]))
        let first = try #require(view.document)
        controller.showLive(try document(["a2", "b"]), changed: [0], complete: true)
        #expect(view.document === first && text(view) == ["a2", "b"])
        memory += 513 << 20
        // TeX stopped short of the end: the pages past there aren't in its document.
        controller.showLive(try document(["a3"]), changed: [0], complete: false)
        #expect(view.document === first && text(view) == ["a3", "b"])
        let whole = try document(["a4", "b4"])
        controller.showLive(whole, changed: [0], complete: true)
        #expect(view.document === whole && text(view) == ["a4", "b4"])
        // Counted from there on.
        controller.showLive(try document(["a5", "b4"]), changed: [0], complete: true)
        #expect(view.document === whole && text(view) == ["a5", "b4"])
        memory += 513 << 20
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

    @Test func clearingThePDFClosesItsFind() throws {
        let controller = PDFController()
        controller.show(try document(["one"]))
        (controller.find.isOpen, controller.find.text) = (true, "one")
        controller.clear()
        #expect(!controller.find.isOpen && controller.find.text.isEmpty && controller.pageCount == 0)
    }
}
