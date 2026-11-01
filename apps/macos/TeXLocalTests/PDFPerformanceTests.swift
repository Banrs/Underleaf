import AppKit
import PDFKit
import Testing
@testable import TeXLocal

private nonisolated let longPDF = URL.homeDirectory.appending(path: "TeXLocal/Test Long (400 pages)/build/main.pdf")

/// Main-thread budgets on the 400-page test project's PDF. A show is measured as the longest run of the main run loop
/// between waits, so work PDFKit defers to its next pass counts too.
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: longPDF.path(percentEncoded: false))))
struct PDFPerformanceTests {
    @Test func showingAndSwappingTheLongPDFStayWithinBudget() async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        let first = try await busiest { await controller.load(longPDF).value }
        #expect(controller.pageCount > 390)
        view.go(to: PDFDestination(page: try #require(view.document?.page(at: 200)), at: CGPoint(x: 0, y: 500)))
        try await Task.sleep(for: .milliseconds(300))
        let swap = try await busiest { await controller.load(longPDF).value }
        #expect(view.shownPlace?.index == 200)
        print("PDFPerformance first show \(first), swap at page 200 \(swap)")
        #expect(first <= .milliseconds(50) && swap <= .milliseconds(50))
    }

    /// The replace itself has the 8 ms budget, as a median: most of it is PDFKit laying out all the document's pages after
    /// each insert and remove. The run-loop pass it is part of also commits the tiles PDFKit renders for the new page,
    /// which no way of swapping the page avoids, so that pass gets twice the budget.
    @Test func aLivePageReplaceStaysWithinBudget() async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        controller.showLive(LiveDocument(path: longPDF.path(percentEncoded: false), changed: []))
        await controller.liveReading?.value
        let document = try #require(view.document)
        view.go(to: PDFDestination(page: try #require(document.page(at: 200)), at: CGPoint(x: 0, y: 500)))
        try await Task.sleep(for: .seconds(2))
        let pdf = try #require(document.page(at: 200)?.dataRepresentation)
        var replaces: [Duration] = [], passes: [Duration] = []
        for _ in 0..<10 {
            let live = try #require(await PDFController.loadPages([200: pdf], covering: view.coverPages))
            passes.append(try await busiest { replaces.append(ContinuousClock().measure { controller.replace(live) }) })
        }
        #expect(view.document === document && view.shownPlace?.index == 200)
        print("PDFPerformance live page replaces \(replaces), their passes \(passes)")
        #expect(replaces.sorted()[replaces.count / 2] <= .milliseconds(8) && passes.max()! <= .milliseconds(16))
    }

    /// The longest the main run loop ran without waiting, from `work` until 300 ms after it.
    private func busiest(_ work: () async -> Void) async throws -> Duration {
        let busy = MainBusy()
        defer { busy.stop() }
        await work()
        try await Task.sleep(for: .milliseconds(300))
        return busy.longest
    }

    private func onScreen(_ controller: PDFController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        controller.view.frame = window.contentView?.bounds ?? .zero
        controller.view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(controller.view)
        window.orderFront(nil)
        return window
    }
}

private final class MainBusy {
    private(set) var longest = Duration.zero
    private var began = ContinuousClock.now
    private var observer: CFRunLoopObserver?

    init() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            guard let self else { return }
            if activity == .afterWaiting { began = .now } else { longest = max(longest, .now - began) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
}
