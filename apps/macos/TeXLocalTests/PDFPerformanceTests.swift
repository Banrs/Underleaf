import AppKit
import PDFKit
import Testing
@testable import TeXLocal

private nonisolated let longPDF = URL.homeDirectory.appending(path: "TeXLocal/Test Long (400 pages)/build/main.pdf")

/// `TEST_RUNNER_TEXLOCAL_PERFORMANCE=1 zsh tools/xctest.sh …`, whose prefix xcodebuild strips for the test host.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PERFORMANCE"] != nil),
       .enabled(if: FileManager.default.fileExists(atPath: longPDF.path(percentEncoded: false))))
struct PDFPerformanceTests {
    @Test func showingAndSwappingTheLongPDFStayWithinBudget() async throws {
        let controller = PDFController(), view = controller.view
        let window = try await onScreen(controller.view, size: NSSize(width: 700, height: 900))
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

    @Test func aLivePageReplaceStaysWithinBudget() async throws {
        let controller = PDFController(), view = controller.view
        let window = try await onScreen(controller.view, size: NSSize(width: 700, height: 900))
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

    private func busiest(_ work: () async -> Void) async throws -> Duration {
        let busy = MainBusy()
        defer { busy.stop() }
        await work()
        try await Task.sleep(for: .milliseconds(300))
        return busy.longest
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
