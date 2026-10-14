import AppKit
import Foundation
import PDFKit
import Synchronization
import Testing
@testable import TeXLocal

/// Events for a session's thread, which waits here as it does in the core.
private final class Feed: Sendable {
    private let state = Mutex<(answers: [Result<TeXpressoEvents, CoreError>], asked: [Int])>(([], []))
    private let news = DispatchSemaphore(value: 0)

    /// The `after` of each wait so far.
    var asked: [Int] { state.withLock { $0.asked } }

    func send(_ events: TeXpressoEvents) {
        state.withLock { $0.answers.append(.success(events)) }
        news.signal()
    }

    func fail(_ error: CoreError) {
        state.withLock { $0.answers.append(.failure(error)) }
        news.signal()
    }

    func wait(after: Int) throws -> TeXpressoEvents {
        state.withLock { $0.asked.append(after) }
        news.wait()
        return try state.withLock { $0.answers.removeFirst() }.get()
    }
}

/// The core as a session calls it: what it was asked, in order, and answers a test can change.
@MainActor
private final class FakeCore {
    var commands: [String] = []
    var starts: [[String: Any]] = []
    /// Each edit as "path start remove text", each whole text as "path=text".
    var sent: [String] = []
    var views: [[Int]] = [], carets: [Int] = []
    var status: @MainActor (String, [String: Any]) async throws -> TeXpressoStatus = { command, _ in
        FakeCore.status(running: command != "texpresso_stop")
    }
    var update: @MainActor (String, String) async throws -> Void = { _, _ in }
    var edit: @MainActor (String) throws -> Void = { _ in }
    let feed = Feed()

    nonisolated static func status(running: Bool = true, error: String? = nil) -> TeXpressoStatus {
        TeXpressoStatus(running: running, log: "", output: "", error: error, session: running ? "owner" : nil)
    }

    func session(haltsAfter: Duration = .seconds(1)) -> TeXpressoSession {
        TeXpressoSession(id: "project", haltsAfter: haltsAfter, calls: .init(
            status: { [self] command, arguments in
                commands.append(command)
                #expect(arguments["id"] as? String == "project")
                if command == "texpresso_start" { starts.append(arguments) }
                // As the core does: a session stopped has news for whoever waits on it.
                if command == "texpresso_stop" { feed.send(TeXpressoEvents(seq: 1_000, running: false)) }
                return try await status(command, arguments)
            },
            update: { [self] arguments in
                commands.append("texpresso_update")
                #expect(arguments["session"] as? String == "owner" && arguments["brief"] as? Bool == true)
                let path = arguments["path"] as? String ?? "", text = arguments["text"] as? String ?? ""
                sent.append("\(path)=\(text)")
                try await update(path, text)
            },
            now: { [self] command, arguments in
                #expect(arguments["session"] as? String == "owner")
                switch command {
                case "texpresso_edit":
                    let edit = "\(arguments["path"] ?? "") \(arguments["start"] ?? "") \(arguments["remove"] ?? "") \(arguments["text"] ?? "")"
                    try self.edit(edit)
                    sent.append(edit)
                case "texpresso_view": views.append([arguments["first"] as? Int ?? -1, arguments["last"] as? Int ?? -1])
                case "texpresso_caret": carets.append(arguments["offset"] as? Int ?? -1)
                default: Issue.record("Unexpected \(command)")
                }
            },
            wait: { [feed] arguments in try feed.wait(after: arguments["after"] as? Int ?? -1) }))
    }
}

/// A PDF on disk, each page's text drawn as text, as TeXpresso leaves its documents and pages.
@MainActor
private func writePDF(_ pages: [String]) throws -> URL {
    let document = PDFDocument()
    for text in pages {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        view.string = String(repeating: text + " ", count: 50)
        let page = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
        document.insert(page, at: document.pageCount)
    }
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
    try #require(document.dataRepresentation()).write(to: url)
    return url
}

@MainActor
struct TeXpressoSessionTests {
    private let main = TeXpressoFile(path: "main.tex", text: "old")

    private func until(_ ready: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if ready() { return }
            await Task.yield()
        }
        throw NSError(domain: "TeXpressoSessionTests", code: 1)
    }

    private func word(_ page: PDFPage?) -> String { page?.string?.components(separatedBy: " ").first ?? "" }

    // ---------- edits ----------

    /// A key is one call, made where the edit is: the range in the old text and what replaced it.
    @Test func eachEditOfAFileSentGoesAtOnceAndInOrder() async {
        let core = FakeCore(), session = core.session()
        session.start(files: [main])
        await session.waitForPendingCalls()
        session.edit("main.tex", NSRange(location: 3, length: 0), "é") { Issue.record("The whole text isn't needed"); return "" }
        session.edit("main.tex", NSRange(location: 1, length: 2), "🦆") { "" }
        #expect(core.sent == ["main.tex 3 0 é", "main.tex 1 2 🦆"])
        session.stop()
        await session.waitForPendingCalls()
    }

    /// An edit the core's copy doesn't fit is put right by the whole text, once; the edits
    /// before it aren't sent again, and the ones after it are edits again.
    @Test func anEditThatDoesNotFitSendsTheWholeTextAndCarriesOn() async {
        let core = FakeCore(), session = core.session()
        core.edit = { _ in throw CoreError(message: "The edit doesn't fit the text TeXpresso has.", status: 412) }
        session.start(files: [main])
        await session.waitForPendingCalls()
        session.edit("main.tex", NSRange(location: 9, length: 0), "a") { "whole a" }
        // Typed while the whole text is on its way: it goes whole too, the latest only.
        session.edit("main.tex", NSRange(location: 10, length: 0), "b") { "whole ab" }
        session.edit("main.tex", NSRange(location: 11, length: 0), "c") { "whole abc" }
        core.edit = { _ in }
        await session.waitForPendingCalls()
        #expect(core.sent == ["main.tex=whole abc"] && session.failure == nil)
        session.edit("main.tex", NSRange(location: 12, length: 0), "d") { "" }
        #expect(core.sent == ["main.tex=whole abc", "main.tex 12 0 d"])
        session.stop()
        await session.waitForPendingCalls()
    }

    /// A file the session wasn't started with has no copy in the core until its whole text is sent.
    @Test func aFileNotSentYetGoesWholeFirst() async {
        let core = FakeCore(), session = core.session()
        session.start(files: [main])
        await session.waitForPendingCalls()
        session.edit("parts/a.tex", NSRange(location: 0, length: 0), "x") { "x include" }
        await session.waitForPendingCalls()
        session.edit("parts/a.tex", NSRange(location: 1, length: 0), "y") { "" }
        #expect(core.sent == ["parts/a.tex=x include", "parts/a.tex 1 0 y"])
        #expect(session.files == ["main.tex", "parts/a.tex"])
        session.stop()
        await session.waitForPendingCalls()
    }

    /// Edits made while TeXpresso starts follow the start whole, each file's latest text once.
    @Test func editsDuringStartFollowItWhole() async throws {
        let core = FakeCore(), session = core.session()
        var start: CheckedContinuation<TeXpressoStatus, Never>?
        core.status = { command, _ in
            if command == "texpresso_start" { return await withCheckedContinuation { start = $0 } }
            return FakeCore.status(running: command != "texpresso_stop")
        }
        session.start(files: [main])
        try await until { start != nil }
        session.edit("main.tex", NSRange(location: 3, length: 0), "e") { "olde" }
        session.edit("main.tex", NSRange(location: 4, length: 0), "r") { "older" }
        session.update(TeXpressoFile(path: "parts/a.tex", text: "include"))
        #expect(core.sent.isEmpty)
        start?.resume(returning: FakeCore.status())
        await session.waitForPendingCalls()
        #expect(core.sent == ["main.tex=older", "parts/a.tex=include"])
        session.edit("main.tex", NSRange(location: 5, length: 0), "!") { "" }
        #expect(core.sent.last == "main.tex 5 0 !")
        session.stop()
        await session.waitForPendingCalls()
    }

    /// A text the core can't take keeps its error and doesn't hold other files back.
    @Test func aRejectedTextDoesNotBlockOtherFiles() async {
        let core = FakeCore(), session = core.session()
        var failures = 0
        core.update = { path, text in
            if path == "a.tex", text != "fixed" { throw CoreError(message: "TeXpresso takes files of up to 8 MB.", status: 400) }
        }
        session.onFailure = { failures += 1 }
        session.start(files: [])
        await session.waitForPendingCalls()
        session.update(TeXpressoFile(path: "a.tex", text: "rejected"))
        session.update(TeXpressoFile(path: "z.tex", text: "valid"))
        await session.waitForPendingCalls()
        #expect(core.sent == ["a.tex=rejected", "z.tex=valid"])
        #expect(failures == 1 && session.failure == "a.tex: TeXpresso takes files of up to 8 MB." && session.active)
        session.edit("z.tex", NSRange(location: 0, length: 0), "v") { "" }
        #expect(core.sent.last == "z.tex 0 0 v")
        session.edit("a.tex", NSRange(location: 0, length: 0), "f") { "fixed" }
        await session.waitForPendingCalls()
        #expect(session.failure == nil && failures == 1)
        session.stop()
        await session.waitForPendingCalls()
    }

    /// A whole text that fails for another reason is tried again without more typing.
    @Test func anUnsentTextIsTriedAgain() async throws {
        let core = FakeCore(), session = core.session()
        var attempts = 0
        core.update = { _, _ in
            attempts += 1
            if attempts == 1 { throw NSError(domain: "transport", code: 1) }
        }
        session.start(files: [])
        await session.waitForPendingCalls()
        session.update(TeXpressoFile(path: "main.tex", text: "unsent $"))
        await session.waitForPendingCalls()
        #expect(attempts == 1 && session.failure != nil)
        try await waitUntil(timeout: .seconds(5)) { attempts == 2 && session.failure == nil }
        #expect(core.sent == ["main.tex=unsent $", "main.tex=unsent $"] && session.active)
        session.stop()
        await session.waitForPendingCalls()
    }

    /// A whole text sent again for a file the core has, as when the file is opened again, is on
    /// its way when a key is typed: the key follows it whole. Sent as an edit it could reach the
    /// core first, and the older text would then replace it.
    @Test func anEditWhileAWholeTextIsOnItsWayFollowsItWhole() async throws {
        let core = FakeCore(), session = core.session()
        var sending: CheckedContinuation<Void, Never>?
        core.update = { _, text in
            if text == "reopened" { await withCheckedContinuation { sending = $0 } }
        }
        session.start(files: [main])
        await session.waitForPendingCalls()
        session.update(TeXpressoFile(path: "main.tex", text: "reopened"))
        try await until { sending != nil }
        session.edit("main.tex", NSRange(location: 8, length: 0), "!") { "reopened!" }
        #expect(core.sent == ["main.tex=reopened"])
        sending?.resume()
        await session.waitForPendingCalls()
        #expect(core.sent == ["main.tex=reopened", "main.tex=reopened!"])
        session.edit("main.tex", NSRange(location: 9, length: 0), "?") { "" }
        #expect(core.sent.last == "main.tex 9 0 ?")
        session.stop()
        await session.waitForPendingCalls()
    }

    // ---------- the view and the caret ----------

    /// The engine has the pane's pages and the caret from the start, the pages again as they
    /// change, and the caret when it rests where typing didn't take it.
    @Test func theViewAndTheCaretAreToldWhenTheyChange() async throws {
        let core = FakeCore(), session = core.session()
        session.view(3...4)
        session.start(files: [main], caret: ("main.tex", 2))
        await session.waitForPendingCalls()
        #expect(core.starts.first?["view"] as? [Int] == [3, 4])
        #expect((core.starts.first?["caret"] as? [String: Any])?["offset"] as? Int == 2)
        session.view(3...4)
        session.view(4...5)
        session.view(4...5)
        #expect(core.views == [[4, 5]])
        // Where it was at the start, and where a key just put it: no news.
        session.caretMoved("main.tex", 2)
        session.edit("main.tex", NSRange(location: 2, length: 0), "a") { "" }
        session.caretMoved("main.tex", 3)
        // A click elsewhere, then another before the first has rested.
        session.caretMoved("main.tex", 0)
        session.caretMoved("main.tex", 1)
        try await waitUntil { !core.carets.isEmpty }
        // The first click's settling, had it not been cancelled, would be due with the second's.
        try await Task.sleep(for: .milliseconds(50))
        #expect(core.carets == [1])
        session.stop()
        await session.waitForPendingCalls()
    }

    // ---------- documents and pages ----------

    /// What waits for the main actor is the latest document and the latest of each page newer
    /// than it: a page typeset twice is drawn once, and a document not shown hands its changes on.
    @Test func newsWaitingIsTheLatestOnly() throws {
        func document(_ serial: Int, _ changed: IndexSet?) throws -> LiveDocument {
            LiveDocument(url: URL(filePath: "/tmp/live.pdf"), document: PDFDocument(), serial: serial, changed: changed, complete: true)
        }
        func page(_ index: Int, _ serial: Int) -> LivePage { LivePage(index: index, serial: serial, page: PDFPage()) }
        var news = LiveNews()
        news.add(LiveNews(revision: 3, pages: [2: page(2, 5), 4: page(4, 6)]))
        news.add(LiveNews(revision: 4, pages: [2: page(2, 7)], stopped: true))
        #expect(news.pages.mapValues(\.serial) == [2: 7, 4: 6] && news.document == nil && news.stopped == true)
        // A document holds every page sent before it.
        news.add(LiveNews(document: try document(8, [2, 4]), pages: [4: page(4, 9)]))
        #expect(news.pages.mapValues(\.serial) == [4: 9] && news.document?.serial == 8 && news.stopped == true)
        news.add(LiveNews(revision: 9, document: try document(12, [7]), stopped: false))
        #expect(news.document?.changed == [2, 4, 7] && news.pages.isEmpty && news.revision == 9 && news.stopped == false)
        // An older build's document may differ anywhere, and so does what follows one not shown.
        news.add(LiveNews(document: try document(13, nil)))
        news.add(LiveNews(document: try document(14, [1])))
        #expect(news.document?.serial == 14 && news.document?.changed == nil)
    }

    /// In one answer the document comes before the pages; a page past the end of what shows
    /// waits for the document that makes room for it; and the wait goes on from the last answer.
    @Test func theDocumentIsShownBeforeItsPagesAndMakesRoomForThem() async throws {
        let core = FakeCore(), session = core.session()
        var shown: [String] = [], count = 0
        session.showDocument = { live in
            shown.append("document \(live.document.pageCount) \(live.changed.map(Array.init) ?? [-1]) \(live.complete)")
            count = live.document.pageCount
        }
        session.showPage = { page, index in shown.append("page \(index) \(word(page))") }
        session.shownPages = { count }
        session.start(files: [main])
        await session.waitForPendingCalls()
        let two = try writePDF(["a", "b"]), three = try writePDF(["a", "b", "c"])
        let first = try writePDF(["first"]), second = try writePDF(["second"]), third = try writePDF(["third"])
        func page(_ index: Int, _ url: URL, _ serial: Int) -> TeXpressoEvents.Page { .init(page: index, path: url.path, serial: serial) }
        // A page before the session's first document waits for it.
        core.feed.send(TeXpressoEvents(seq: 1, running: true, pages: [page(0, first, 1)]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown.isEmpty)
        core.feed.send(TeXpressoEvents(seq: 4, running: true,
                                       pdf: .init(path: two.path, version: 1, serial: 2, pages: 2, run: "partial", changed: [[0, 1]]),
                                       pages: [page(1, second, 4)]))
        try await waitUntil { shown.count == 2 }
        #expect(shown == ["document 2 [0, 1] false", "page 1 second"])
        // The third page has nowhere to go until the document has three.
        core.feed.send(TeXpressoEvents(seq: 5, running: true, pages: [page(2, third, 5)]))
        core.feed.send(TeXpressoEvents(seq: 6, running: true, pages: [page(0, first, 6)]))
        try await waitUntil { shown.count == 3 }
        #expect(shown.last == "page 0 first")
        core.feed.send(TeXpressoEvents(seq: 8, running: true,
                                       pdf: .init(path: three.path, version: 2, serial: 8, pages: 3, run: "complete", changed: [[2, 2]])))
        try await waitUntil { shown.count == 4 }
        // The page was sent before the document, which has it.
        #expect(shown.last == "document 3 [2] true")
        core.feed.send(TeXpressoEvents(seq: 9, running: true, pages: [page(2, third, 9)]))
        try await waitUntil { shown.count == 5 && core.feed.asked.last == 9 }
        #expect(shown.last == "page 2 third" && core.feed.asked == [0, 1, 4, 5, 6, 8, 9])
        session.stop()
        await session.waitForPendingCalls()
    }

    /// A build that never says which pages changed, or how its run ended, has its documents
    /// shown whole; and a page whose file has gone by the time it is read is passed over.
    @Test func anOlderBuildsDocumentIsShownWhole() async throws {
        let core = FakeCore(), session = core.session()
        var documents: [LiveDocument] = [], pages = 0
        session.showDocument = { documents.append($0) }
        session.showPage = { _, _ in pages += 1 }
        session.shownPages = { documents.last?.document.pageCount ?? 0 }
        session.start(files: [main])
        await session.waitForPendingCalls()
        core.feed.send(TeXpressoEvents(seq: 1, running: true, pdf: .init(path: try writePDF(["a", "b"]).path, version: 1, serial: 1, pages: 2),
                                       pages: [.init(page: 0, path: "/tmp/gone-\(UUID().uuidString).pdf", serial: 2)]))
        try await waitUntil { documents.count == 1 }
        #expect(documents[0].changed == nil && documents[0].complete && pages == 0)
        // No pages, as TeX leaves the document when it stops in the preamble: what shows stays.
        core.feed.send(TeXpressoEvents(seq: 3, running: true, pdf: .init(path: "/tmp/none.pdf", version: 2, serial: 3, pages: 0, run: "stopped", changed: [])))
        core.feed.send(TeXpressoEvents(seq: 4, running: true, revision: 7))
        try await waitUntil { core.feed.asked.last == 4 }
        #expect(documents.count == 1)
        session.stop()
        await session.waitForPendingCalls()
    }

    /// A document that couldn't be read leaves the next one's list of changes short: all of
    /// that one's pages are taken. So does one the core replaced before it was asked for, which
    /// the gap in the documents' numbers tells; one with no pages has its number all the same.
    @Test func aDocumentMissedMakesTheNextOneWhole() async throws {
        let core = FakeCore(), session = core.session()
        var documents: [LiveDocument] = []
        session.showDocument = { documents.append($0) }
        session.start(files: [main])
        await session.waitForPendingCalls()
        func document(_ version: Int, _ path: String, pages: Int = 3) -> TeXpressoEvents {
            TeXpressoEvents(seq: version, running: true,
                            pdf: .init(path: path, version: version, serial: version, pages: pages, run: "complete", changed: [[1, 1]]))
        }
        let whole = try writePDF(["a", "b", "c"]).path
        core.feed.send(document(1, "/tmp/gone-\(UUID().uuidString).pdf"))
        core.feed.send(document(2, whole))
        try await waitUntil { documents.count == 1 }
        #expect(documents[0].changed == [0, 1, 2])
        core.feed.send(document(3, whole))
        try await waitUntil { documents.count == 2 }
        #expect(documents[1].changed == [1])
        core.feed.send(document(5, whole))
        try await waitUntil { documents.count == 3 }
        #expect(documents[2].changed == [0, 1, 2])
        core.feed.send(document(6, "/tmp/none.pdf", pages: 0))
        core.feed.send(document(7, whole))
        try await waitUntil { documents.count == 4 }
        #expect(documents[3].changed == [1])
        session.stop()
        await session.waitForPendingCalls()
    }

    // ---------- starting, stopping and ending ----------

    /// TeX stopped at an error is said so once it has lasted, and not for a brace half typed.
    @Test func aRunStoppedAtAnErrorIsSaidOnceItLasts() async throws {
        // A tenth of a second for the app's second.
        let core = FakeCore(), session = core.session(haltsAfter: .milliseconds(100))
        session.start(files: [main])
        await session.waitForPendingCalls()
        core.feed.send(TeXpressoEvents(seq: 1, running: true, done: .init(run: "stopped")))
        core.feed.send(TeXpressoEvents(seq: 2, running: true, done: .init(run: "complete")))
        try await waitUntil { core.feed.asked.last == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!session.halted && session.title == "Live Preview On")
        core.feed.send(TeXpressoEvents(seq: 3, running: true, done: .init(run: "stopped")))
        try await waitUntil { session.halted }
        #expect(session.needsAttention && session.title == "Live Preview Paused at an Error")
        core.feed.send(TeXpressoEvents(seq: 4, running: true, done: .init(run: "complete")))
        try await waitUntil { !session.halted }
        session.stop()
        await session.waitForPendingCalls()
    }

    /// TeXpresso going by itself ends the session and says why; the warning lasts until its log has been read.
    @Test func aSessionThatEndsByItselfSaysWhy() async throws {
        let core = FakeCore(), session = core.session()
        var ended: [Bool] = [], failures = 0
        session.onEnded = { ended.append($0) }
        session.onFailure = { failures += 1 }
        core.status = { command, _ in
            FakeCore.status(running: command == "texpresso_start", error: command == "texpresso_status" ? "TeXpresso exited (signal 11)." : nil)
        }
        session.start(files: [main])
        await session.waitForPendingCalls()
        core.feed.send(TeXpressoEvents(seq: 1, running: false, error: "TeXpresso exited (signal 11)."))
        try await waitUntil { !ended.isEmpty }
        // It had only just started: starting it again by itself would loop.
        #expect(ended == [false] && failures == 1 && session.phase == .stopped && session.canStart)
        #expect(session.needsAttention && session.log == "TeXpresso exited (signal 11).")
        try await waitUntil { core.commands.last == "texpresso_status" }
        session.showsLog = true
        #expect(session.needsAttention)
        session.showsLog = false
        #expect(!session.needsAttention && session.title == "Live Preview Stopped" && session.log == "TeXpresso exited (signal 11).")
    }

    /// The log is asked for while it shows and has changed, not at every answer.
    @Test func theLogIsReadOnlyWhileItShows() async throws {
        let core = FakeCore(), session = core.session()
        session.start(files: [main])
        await session.waitForPendingCalls()
        core.feed.send(TeXpressoEvents(seq: 1, running: true, revision: 5))
        core.feed.send(TeXpressoEvents(seq: 2, running: true, revision: 6))
        try await waitUntil { core.feed.asked.last == 2 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(core.commands == ["texpresso_start"])
        core.status = { _, _ in TeXpressoStatus(running: true, log: "log", output: "", error: nil, session: "owner", revision: 6) }
        session.showsLog = true
        try await waitUntil { session.log == "log" }
        try await Task.sleep(for: .milliseconds(400))
        #expect(core.commands == ["texpresso_start", "texpresso_status"])
        core.status = { command, _ in FakeCore.status(running: command != "texpresso_stop") }
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func closeWaitsForAnInFlightStartThenStopsIt() async throws {
        let core = FakeCore(), session = core.session()
        var start: CheckedContinuation<TeXpressoStatus, Never>?
        var ended = 0
        core.status = { command, arguments in
            if command == "texpresso_start" { return await withCheckedContinuation { start = $0 } }
            #expect(arguments["session"] as? String == "owner")
            return FakeCore.status(running: false)
        }
        session.onEnded = { _ in ended += 1 }
        session.start(files: [])
        try await until { start != nil }
        session.update(TeXpressoFile(path: "main.tex", text: "pending"))
        session.close()
        #expect(session.phase == .stopping && !session.canStart)
        start?.resume(returning: FakeCore.status())
        await session.waitForPendingCalls()
        #expect(core.commands == ["texpresso_start", "texpresso_stop"])
        #expect(session.phase == .stopped && ended == 0)
    }

    @Test func failedStartShowsItsLogAndCanBeRetried() async {
        let core = FakeCore(), session = core.session()
        var starts = 0, failures = 0, ended = 0
        core.status = { command, _ in
            if command == "texpresso_start" { starts += 1 }
            return starts == 1 ? FakeCore.status(running: false, error: "Executable unavailable")
                : FakeCore.status(running: command != "texpresso_stop")
        }
        session.onFailure = { failures += 1 }
        session.onEnded = { _ in ended += 1 }
        session.start(files: [])
        await session.waitForPendingCalls()
        #expect(session.canStart && session.log == "Executable unavailable")
        #expect(failures == 1 && ended == 1)
        session.start(files: [])
        await session.waitForPendingCalls()
        #expect(session.active && session.log.isEmpty)
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test(arguments: ["texpresso_edit", "texpresso_update", "texpresso_start", "texpresso_wait"])
    func replacedOwnershipStopsLocalWorkWithoutStoppingTheReplacement(command failed: String) async throws {
        let core = FakeCore(), session = core.session()
        let replaced = CoreError(message: "Another window started TeXpresso for this project. Start TeXpresso again to preview here.", status: 409)
        var ownershipLosses = 0, ended = 0
        core.status = { _, _ in
            if core.commands.count > 1 { throw replaced }
            return FakeCore.status()
        }
        core.update = { _, _ in throw replaced }
        core.edit = { _ in throw replaced }
        session.onOwnershipLost = { ownershipLosses += 1 }
        session.onEnded = { _ in ended += 1 }
        session.start(files: [main])
        await session.waitForPendingCalls()
        switch failed {
        case "texpresso_start": session.restart(files: [])
        case "texpresso_edit": session.edit("main.tex", NSRange(location: 0, length: 0), "x") { "" }
        case "texpresso_update": session.update(TeXpressoFile(path: "main.tex", text: "old owner"))
        default: core.feed.fail(replaced)
        }
        await session.waitForPendingCalls()
        try await waitUntil { ended == 1 }
        #expect(!session.active && session.failure != nil && ownershipLosses == 1)
        session.restart(files: [])
        session.close()
        await session.waitForPendingCalls()
        #expect(core.commands == ["texpresso_start"] + (failed == "texpresso_edit" || failed == "texpresso_wait" ? [] : [failed]))
        if failed != "texpresso_wait" { core.feed.send(TeXpressoEvents(seq: 1, running: false)) }
    }

    @Test(arguments: [true, false])
    func restartDuringStartOnlyUsesAcquiredOwnership(started: Bool) async throws {
        let core = FakeCore(), session = core.session()
        var first: CheckedContinuation<TeXpressoStatus, Never>?
        core.status = { command, _ in
            if command == "texpresso_start", core.starts.count == 1 { return await withCheckedContinuation { first = $0 } }
            return FakeCore.status(running: command != "texpresso_stop")
        }
        session.start(files: [])
        try await until { first != nil }
        session.restart(files: [TeXpressoFile(path: "main.tex", text: "changed main")])
        first?.resume(returning: FakeCore.status(running: started))
        await session.waitForPendingCalls()
        #expect(core.starts.map { $0["session"] as? String } == (started ? [nil, "owner"] : [nil]))
        #expect(session.active == started)
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func restartCoalescesIntoAnUndispatchedExplicitStart() async {
        let core = FakeCore(), session = core.session()
        session.start(files: [TeXpressoFile(path: "old.tex", text: "old")])
        session.restart(files: [TeXpressoFile(path: "main.tex", text: "latest")])
        await session.waitForPendingCalls()
        #expect(core.starts.count == 1 && session.active)
        #expect(core.starts[0]["session"] == nil)
        #expect(core.starts[0]["files"] as? [[String: String]] == [["path": "main.tex", "text": "latest"]])
        // For the PDF pane, not TeXpresso's own window.
        #expect(core.starts[0]["pdf"] as? Bool == true)
        session.stop()
        await session.waitForPendingCalls()
    }
}
