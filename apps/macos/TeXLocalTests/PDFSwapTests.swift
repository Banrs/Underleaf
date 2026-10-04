import AppKit
import PDFKit
import Testing
@testable import TeXLocal

/// A rebuilt PDF's pages replace the last's in the document showing: the pane never flashes
/// empty, as a new document would, and nothing on the pages leads back to the old ones.
@MainActor
struct PDFSwapTests {
    /// Each page's text drawn as text, so PDFKit reads it.
    private func document(_ pages: [String]) throws -> PDFDocument {
        let document = PDFDocument()
        for text in pages {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            view.string = String(repeating: text + " ", count: 200)
            let page = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
            document.insert(page, at: document.pageCount)
        }
        return document
    }

    /// The pane's white pixels as it shows, sampled small: none is an empty pane.
    private func paper(_ view: NSView) -> Int {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: image)
        var count = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: image.pixelsWide, by: 8) where (image.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.92 {
                count += 1
            }
        }
        return count
    }

    /// In an on-screen window, unseen: PDFKit draws pages only there.
    private func onScreen(_ controller: PDFController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.alphaValue = 0
        window.orderFront(nil)
        return window
    }

    private func text(_ view: PDFView) -> [String] {
        guard let document = view.document else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string?.components(separatedBy: " ").first ?? "" }
    }

    @Test(arguments: [1, 3]) func aRebuildNeverShowsAnEmptyPane(rebuilds: Int) async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        controller.show(try document(["first"]))
        try await waitUntil(timeout: .seconds(5)) { paper(view) > 0 }
        let shown = view.document
        // Back to back, as live preview writes them while typing.
        for index in 0..<rebuilds { controller.show(try document(["rebuild\(index)"])) }
        let start = ContinuousClock.now
        var samples: [Int] = []
        while ContinuousClock.now - start < .milliseconds(400) {
            samples.append(paper(view))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!samples.contains(0), "samples \(samples)")
        #expect(view.document === shown)
        #expect(text(view) == ["rebuild\(rebuilds - 1)"])
    }

    /// A rebuild with more or fewer pages keeps the page being read, and the count.
    @Test func aRebuildChangesThePageCount() throws {
        let controller = PDFController(), view = controller.view
        view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try document(["a", "b", "c"]))
        controller.go(toPage: 2)
        controller.show(try document(["a2", "b2", "c2", "d2"]))
        #expect(text(view) == ["a2", "b2", "c2", "d2"])
        #expect(controller.page == 2 && controller.pageCount == 4)
        controller.show(try document(["a3"]))
        #expect(text(view) == ["a3"])
        #expect(controller.page == 1 && controller.pageCount == 1)
    }

    /// A link to another page of the document leads to that page as shown, not the build's copy.
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
        let controller = PDFController(), view = controller.view
        view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try linked())
        controller.show(try linked())
        let shown = try #require(view.document)
        let link = try #require(shown.page(at: 0)?.annotations.first { $0.type == "Link" })
        let target = try #require(link.destination?.page ?? (link.action as? PDFActionGoTo)?.destination.page)
        #expect(target === shown.page(at: 1))
    }
}
