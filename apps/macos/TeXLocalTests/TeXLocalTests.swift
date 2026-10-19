import AppKit
import PDFKit
import Testing
@testable import TeXLocal

/// What a timed-out wait last saw, so a failure on a machine we can't watch says why.
struct TimedOut: Error { var state = "" }

func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool,
               state: () -> String = { "" }) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut(state: state()) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Lets what is queued on the main actor, and what that queues in turn, run: for something that must not happen, where there is no condition to wait for.
func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

/// An empty defaults domain of a test's own, for an `AppModel` whose settings would otherwise go to the user's. A suite
/// holds one for each test, as Swift Testing makes the suite afresh for each, and it goes as the test ends.
nonisolated final class TestDefaults {
    private let name = "TeXLocalTests." + UUID().uuidString
    let store: UserDefaults

    init() { store = UserDefaults(suiteName: name)! }

    deinit { UserDefaults.standard.removePersistentDomain(forName: name) }

    /// What was written, not what the app registers for a key nothing has set.
    func saved(_ key: String) -> Any? { UserDefaults.standard.persistentDomain(forName: name)?[key] }
}

func isClose(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 0.5) -> Bool { abs(a - b) <= tolerance }

/// A blank project in the test library (`TEXLOCAL_DATA`), whose folder the caller removes.
func newProject() async throws -> ProjectInfo {
    try await Core.shared.call("create_project", ["name": "Test \(UUID().uuidString.prefix(8))", "template": "blank"], as: ProjectInfo.self)
}

extension ProjectInfo {
    var folder: URL { Core.libraryFolder.appending(path: id) }

    /// Writes `text` to the project's file at `path`, making its folders, as another app would.
    func write(_ text: String, to path: String) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}

extension [TreeNode] {
    static var sources: [TreeNode] {
        [TreeNode(type: .file, name: "main.tex", path: "main.tex", kind: .tex, children: nil),
         TreeNode(type: .file, name: "references.bib", path: "references.bib", kind: .bib, children: nil)]
    }
}

extension UndoManager {
    /// What `work` registers, as one action.
    func grouping(_ work: () async -> Void) async {
        beginUndoGrouping()
        await work()
        endUndoGrouping()
    }
}

extension NSWindow {
    /// On screen but unseen, and kept until it is closed.
    func orderFrontUnseen() {
        isReleasedWhenClosed = false
        alphaValue = 0
        orderFront(nil)
    }
}

func sizedController() -> PDFController {
    let controller = PDFController()
    controller.view.setFrameSize(NSSize(width: 600, height: 500))
    return controller
}

func showing(_ document: PDFDocument) -> PDFController {
    let controller = sizedController()
    controller.show(document)
    return controller
}

func openFind(_ query: String, in controller: PDFController) {
    controller.find.isOpen = true
    controller.find.text = query
    controller.find.search(query)
}

func textPDF(_ pages: [String], width: CGFloat = 612) throws -> PDFDocument {
    let document = PDFDocument()
    for text in pages {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 792))
        view.string = text
        let page = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
        document.insert(page, at: document.pageCount)
    }
    return document
}
