import AppKit
import PDFKit
import Testing
@testable import TeXLocal

private nonisolated let longPDF = ProcessInfo.processInfo.environment["TEXLOCAL_LONG_PDF"].map { URL(filePath: $0) }
    ?? URL.homeDirectory.appending(path: "TeXLocal/Test Long (400 pages)/build/main.pdf")
private nonisolated let chapters = longPDF.deletingLastPathComponent().deletingLastPathComponent().appending(path: "chapters")

/// A performance run asked for without the book fails, rather than skipping and passing with nothing measured.
private func requireBook(_ part: URL) throws {
    try #require(FileManager.default.fileExists(atPath: part.path(percentEncoded: false)),
                 "No \(part.path(percentEncoded: false)): build the book tools/perf-book.py writes, or set TEST_RUNNER_TEXLOCAL_LONG_PDF")
}

/// `TEST_RUNNER_TEXLOCAL_PERFORMANCE=1 zsh tools/xctest.sh …`, whose prefix xcodebuild strips for the test host;
/// `TEST_RUNNER_TEXLOCAL_LONG_PDF` points them at a build of the book `tools/perf-book.py` writes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PERFORMANCE"] != nil))
struct PDFPerformanceTests {
    init() throws { try requireBook(longPDF) }

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
        await controller.feed.reading?.value
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

/// The long book's 40 chapters, beside its build folder, as one file of 1.2 MB.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PERFORMANCE"] != nil))
struct EditorPerformanceTests {
    init() throws { try requireBook(chapters) }

    private static func chapter(_ number: Int) throws -> String {
        try String(contentsOf: chapters.appending(path: String(format: "ch%02d.tex", number)), encoding: .utf8)
    }

    private static func book() throws -> String { try (0..<40).map(chapter).joined(separator: "\n") }

    private func editor(_ text: String) async throws -> (SourceEditor, NSWindow) {
        let editor = SourceEditor()
        let window = try await onScreen(editor.scrollView, size: NSSize(width: 700, height: 900))
        editor.open(path: "main.tex", source: SourceDocument(text: text))
        editor.textView.undo.groupsByEvent = false
        editor.shown = true
        window.makeFirstResponder(editor.textView)
        try await Task.sleep(for: .milliseconds(500))
        return (editor, window)
    }

    @Test func indentingTwoThousandLines() async throws {
        let (editor, window) = try await editor(try Self.book())
        defer { window.close() }
        let text = editor.textView, before = text.string
        let from = text.document.lineStart(1001), to = text.document.lineStart(3001)
        text.selection = NSRange(location: from, length: to - from)
        let indent = ContinuousClock().measure { text.insertTab(nil) }
        let indented = text.string
        #expect(text.document.text == indented && indented != before && text.undo.undoActionName == "Indent")
        try await Task.sleep(for: .milliseconds(300))
        let undo = ContinuousClock().measure { text.undo.undo() }
        #expect(text.string == before && text.document.text == before)
        let redo = ContinuousClock().measure { text.undo.redo() }
        #expect(text.string == indented && text.document.text == indented)
        print("EditorPerformance indenting 2,000 lines \(ms(indent)), its undo \(ms(undo)), redo \(ms(redo))")
        #expect(indent <= .seconds(3) && undo <= .seconds(3) && redo <= .seconds(3))
    }
}

private func ms(_ duration: Duration) -> String {
    String(format: "%.1f ms", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
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
