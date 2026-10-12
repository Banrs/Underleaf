import Foundation
import Observation
import PDFKit
import Synchronization

/// The core's status of a session: its log, which is large, so asked for only when it shows.
nonisolated struct TeXpressoStatus: Decodable, Sendable, Equatable {
    let running: Bool
    let log: String
    let output: String
    let error: String?
    let session: String?
    /// Rises when the log, the output or the error changes.
    var revision = 0
}

/// What is new in a session since the last answer (`texpresso_wait`).
nonisolated struct TeXpressoEvents: Decodable, Sendable {
    struct Document: Decodable, Sendable {
        let path: String
        /// Rises by one with each document the session writes: a gap is one the core replaced unread.
        let version: Int
        let serial: Int
        let pages: Int
        /// `complete`, `stopped` at an error before the end, or `partial` while the first is typeset; nil from an older build.
        var run: String?
        /// Ranges, first and last, of the pages that differ from the document before; nil from an older build, when any may.
        var changed: [[Int]]?
    }

    struct Page: Decodable, Sendable {
        let page: Int
        let path: String
        let serial: Int
    }

    struct RunEnd: Decodable, Sendable {
        let run: String
    }

    let seq: Int
    let running: Bool
    var error: String?
    var revision = 0
    /// The whole document, written again; it comes before `pages`, which are all newer.
    var pdf: Document?
    /// The latest of each page typeset since, each alone in a file.
    var pages: [Page] = []
    var done: RunEnd?
}

/// An edit's number in its session, which is all the core says of one; 0 when nothing was sent.
nonisolated struct TeXpressoEdit: Decodable, Sendable {
    let edit: Int
}

nonisolated struct TeXpressoFile: Sendable {
    let path: String
    let text: String
}

/// A live document read from its file. Made on the session's thread and handed to the main
/// actor, which alone uses it from then on.
nonisolated struct LiveDocument: @unchecked Sendable {
    let url: URL
    let document: PDFDocument
    let serial: Int
    /// The pages that differ from the live document before; nil when any may, from an older build.
    var changed: IndexSet?
    /// TeX reached the document's end: pages past this document's last are gone. Otherwise
    /// they stay, as a construct half typed stops TeX short of them.
    var complete: Bool
}

/// A live page read from its file, as `LiveDocument`.
nonisolated struct LivePage: @unchecked Sendable {
    let index: Int
    let serial: Int
    let page: PDFPage
}

/// What the session's thread has read and the main actor hasn't taken yet: the latest
/// document, and the latest of each page newer than it.
nonisolated struct LiveNews: Sendable {
    var running = true
    var error: String?
    var revision = 0
    var document: LiveDocument?
    var pages: [Int: LivePage] = [:]
    /// How the last run of TeX ended: stopped at an error, or at the document's end.
    var stopped: Bool?
    /// The wait itself failed.
    var failure: CoreError?

    mutating func add(_ newer: LiveNews) {
        (running, error, revision, failure) = (newer.running, newer.error, max(revision, newer.revision), newer.failure)
        stopped = newer.stopped ?? stopped
        if var next = newer.document {
            // The one not shown is skipped, so its changes are this one's too.
            if let waiting = document {
                next.changed = waiting.changed.flatMap { waiting in next.changed.map { $0.union(waiting) } }
            }
            document = next
            pages = pages.filter { $0.value.serial > next.serial }
        }
        pages.merge(newer.pages) { $0.serial > $1.serial ? $0 : $1 }
    }
}

/// A session belongs to one open project and never changes a saved preference. Starts, stops
/// and whole texts share a lane, so none overtakes another; a keystroke's edit goes to the
/// core where it is made; and a thread of the session's own waits in the core for pages.
@MainActor @Observable
final class TeXpressoSession {
    enum Phase { case stopped, starting, running, stopping }

    /// The core, as the session calls it.
    struct Calls {
        /// Start, stop, rescan and status, which answer with the status.
        var status: @MainActor (String, [String: Any]) async throws -> TeXpressoStatus
        /// A file's whole text; its edit's number.
        var update: @MainActor ([String: Any]) async throws -> Int
        /// An edit, the view or the caret, answered at once on the main thread; an edit's number.
        var now: @MainActor (String, [String: Any]) throws -> Int
        /// Blocks until the session has news, on the session's thread.
        var wait: @Sendable ([String: any Sendable]) throws -> TeXpressoEvents
    }

    private(set) var phase: Phase = .stopped
    private(set) var status: TeXpressoStatus?
    private var requestFailure: String?
    private var rejected: [String: String] = [:]
    /// TeX has stopped at an error before the document's end for a second or more: the pages
    /// past it are from before.
    private(set) var halted = false
    /// The failure has been read: it stays in the log, without the status bar's warning.
    private var acknowledged = false
    var onFailure: () -> Void = {}
    /// The session is over; `restartable` when TeXpresso went by itself after running a while.
    var onEnded: (_ restartable: Bool) -> Void = { _ in }
    var onOwnershipLost: () -> Void = {}
    /// The PDF pane: a whole document, a page of it, and how many pages it shows.
    @ObservationIgnored var showDocument: (LiveDocument) -> Void = { _ in }
    @ObservationIgnored var showPage: (PDFPage, Int) -> Void = { _, _ in }
    @ObservationIgnored var shownPages: () -> Int = { 0 }
    /// The log is on screen, so it follows the session; otherwise it is read when the session ends.
    @ObservationIgnored var showsLog = false {
        didSet {
            if showsLog { fetchStatus() } else if oldValue, phase == .stopped { acknowledged = true }
        }
    }

    @ObservationIgnored private let id: String
    @ObservationIgnored private let calls: Calls
    @ObservationIgnored private var lane: Task<Void, Never>?
    @ObservationIgnored private var flushing: Int?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Whole texts to send: files the core has no copy of, or whose copy an edit didn't fit.
    @ObservationIgnored private var pending: [String: String] = [:]
    /// The files whose copy in the core follows the editor's edit by edit.
    @ObservationIgnored private var synced: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var lastReportedErrors: Set<String> = []
    /// The core's token for this client's session, which its other calls name.
    @ObservationIgnored private(set) var owner: String?
    @ObservationIgnored private var queued: Start?
    @ObservationIgnored private var inbox: Inbox?
    @ObservationIgnored private var started: ContinuousClock.Instant?
    /// The session has shown a document; pages before its first wait for it.
    @ObservationIgnored private var documentShown = false
    /// Pages past the end of what shows, until a document makes room.
    @ObservationIgnored private var waiting: [Int: LivePage] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var statusFetch: Task<Void, Never>?
    @ObservationIgnored private var halting: Task<Void, Never>?
    /// The pages the pane shows and where the caret is, as the engine was last told.
    @ObservationIgnored private var viewed: ClosedRange<Int>?
    @ObservationIgnored private var sentView: ClosedRange<Int>?
    @ObservationIgnored private var caret: (path: String, offset: Int)?
    @ObservationIgnored private var settling: Task<Void, Never>?
    /// The document goes to the PDF pane, not TeXpresso's own window.
    @ObservationIgnored private var inPane = true

    private typealias Start = (files: [TeXpressoFile], caret: (path: String, offset: Int)?)

    init(id: String, calls: Calls) {
        self.id = id
        self.calls = calls
    }

    var active: Bool { phase == .starting || phase == .running }
    var canStart: Bool { !closed && phase == .stopped }
    /// The files the session has a copy of, which it keeps until it ends.
    var files: Set<String> { synced.union(pending.keys).union(queued?.files.map(\.path) ?? []) }
    private var requestErrors: [String] {
        [requestFailure].compactMap { $0 } + rejected.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    }
    var failure: String? {
        let messages = requestErrors
        return messages.isEmpty ? nil : messages.joined(separator: "\n\n")
    }
    var needsAttention: Bool { halted || !acknowledged && (failure != nil || status?.error != nil) }
    /// Started in this window, so it has a log to show.
    var used: Bool { phase != .stopped || status != nil || failure != nil }
    var title: String {
        switch phase {
        case .stopped: return needsAttention ? "Live Preview Needs Attention" : "Live Preview Stopped"
        case .starting: return "Starting Live Preview…"
        case .running: return halted ? "Live Preview Paused at an Error" : needsAttention ? "Live Preview Needs Attention" : "Live Preview On"
        case .stopping: return "Stopping Live Preview…"
        }
    }

    var log: String {
        var parts: [String] = []
        if let failure { parts.append(failure) }
        if let error = status?.error, error != failure { parts.append(error) }
        if let text = status?.log, !text.isEmpty { parts.append(text) }
        if let text = status?.output, !text.isEmpty { parts.append(text) }
        return parts.joined(separator: "\n\n")
    }

    // ---------- starting and stopping ----------

    /// `caret` is where the first key will land, in one of `files`: TeX is ready there.
    func start(files: [TeXpressoFile], caret: (path: String, offset: Int)? = nil) {
        guard canStart else { return }
        beginStart((files, caret), replacing: false)
    }

    func restart(files: [TeXpressoFile], caret: (path: String, offset: Int)? = nil) {
        guard !closed, phase != .stopping, owner != nil || phase == .starting else { return }
        if phase == .starting, queued != nil {
            queued = (files, caret)
            for file in files { pending[file.path] = nil }
            return
        }
        beginStart((files, caret), replacing: true)
    }

    private func beginStart(_ start: Start, replacing: Bool) {
        generation += 1
        phase = .starting
        requestFailure = nil
        rejected.removeAll()
        lastReportedErrors.removeAll()
        acknowledged = false
        reset()
        queued = start
        inPane = LiveViewer.current == .pane
        let current = generation
        enqueue { session in
            guard session.generation == current, !session.closed, let start = session.queued else { return }
            session.queued = nil
            do {
                // A patched build writes the document for the PDF pane rather than opening a window;
                // TeXpresso's own window, which draws with MuPDF, is the fallback Settings offers.
                var arguments: [String: Any] = ["id": session.id, "files": start.files.map { ["path": $0.path, "text": $0.text] }, "pdf": session.inPane]
                if let view = session.viewed { arguments["view"] = [view.lowerBound, view.upperBound] }
                if let caret = start.caret { arguments["caret"] = ["path": caret.path, "offset": caret.offset] }
                if replacing {
                    guard let owner = session.owner else { session.ended(); return }
                    arguments["session"] = owner
                }
                let status = try await session.calls.status("texpresso_start", arguments)
                // Stop/close may have superseded Start while it was in flight.
                session.owner = status.session
                guard session.generation == current, !session.closed else { return }
                // An edit since the files were read is waiting whole.
                session.synced = Set(start.files.map(\.path)).subtracting(session.pending.keys)
                (session.sentView, session.caret) = (session.viewed, start.caret)
                session.receive(status)
                guard session.active else { return }
                session.started = .now
                session.listen()
                session.flushEdits()
            } catch {
                guard session.generation == current, !session.closed else { return }
                session.fail(error)
                if session.phase != .stopped { session.ended() }
            }
        }
    }

    func stop() {
        guard phase != .stopped else { owner = nil; return }
        generation += 1
        let current = generation
        phase = .stopping
        reset()
        enqueue { session in
            do {
                if let owner = session.owner {
                    let status = try await session.calls.status("texpresso_stop", ["id": session.id, "session": owner])
                    if session.owner == owner { session.owner = nil }
                    if session.generation == current { session.status = status }
                }
            } catch {
                if !session.closed { session.fail(error) }
            }
            guard session.generation == current else { return }
            if session.phase != .stopped { session.ended() }
        }
    }

    func close() {
        closed = true
        stop()
    }

    /// Nothing of the session that was is waited for or sent.
    private func reset() {
        inbox?.cancel()
        inbox = nil
        for task in [retry, statusFetch, halting, settling] { task?.cancel() }
        (retry, statusFetch, halting, settling) = (nil, nil, nil, nil)
        pending.removeAll()
        synced.removeAll()
        waiting.removeAll()
        queued = nil
        (documentShown, halted, started, sentView, caret) = (false, false, nil, nil, nil)
    }

    /// Waits for the currently queued work without starting or stopping a process.
    func waitForPendingCalls() async { await lane?.value }

    private func enqueue(_ action: @escaping @MainActor (TeXpressoSession) async -> Void) {
        let previous = lane
        lane = Task {
            await previous?.value
            await action(self)
        }
    }

    // ---------- edits ----------

    /// An edit as the text storage made it: `range` of the text before it, replaced by `text`.
    /// It reaches the core here, and TeXpresso from there, without a wait. `whole` is the text
    /// after it, for a file the core has no copy of or whose copy the edit doesn't fit.
    func edit(_ path: String, _ range: NSRange, _ text: String, whole: () -> String) {
        guard active, !closed else { return }
        // Typing takes the engine's snapshot along: the caret there is no news.
        caret = (path, range.location + (text as NSString).length)
        if phase == .running, let owner, synced.contains(path), pending[path] == nil {
            do {
                _ = try calls.now("texpresso_edit", ["session": owner, "path": path, "start": range.location,
                                                     "remove": range.length, "text": text])
                return
            } catch {
                // Another window's session now: nothing more is sent.
                if (error as? CoreError)?.status == 409 { return fail(error) }
                // Refused, so the core's copy is a step behind: the whole text puts it right, or says why not.
                synced.remove(path)
            }
        }
        pending[path] = whole()
        flushEdits()
    }

    /// A file's whole text: one just opened, or changed by another app.
    func update(_ file: TeXpressoFile) {
        guard active, !closed else { return }
        // Not edit by edit until it is there: a key's edit sent meanwhile could reach the core
        // first, and this older text would then replace it.
        synced.remove(file.path)
        pending[file.path] = file.text
        flushEdits()
    }

    private func flushEdits() {
        guard phase == .running, !closed, !pending.isEmpty, flushing != generation else { return }
        let current = generation
        flushing = current
        retry?.cancel()
        enqueue { session in
            defer { if session.flushing == current { session.flushing = nil } }
            // The latest text of each file, including what was typed while a call was out.
            while session.generation == current, session.phase == .running, !session.closed,
                  let path = session.pending.keys.min(), let text = session.pending.removeValue(forKey: path) {
                guard let owner = session.owner else { return }
                do {
                    _ = try await session.calls.update(["id": session.id, "session": owner, "path": path, "text": text, "brief": true])
                    guard session.generation == current, !session.closed else { return }
                    session.rejected[path] = nil
                    if session.pending.isEmpty { session.requestFailure = nil }
                    // Edits made meanwhile are in a newer whole text, sent next.
                    if session.pending[path] == nil { session.synced.insert(path) }
                } catch {
                    guard session.generation == current, !session.closed else { return }
                    if (error as? CoreError)?.status == 400 {
                        // This text can't be taken, whenever it is sent: its error stays until the file is edited.
                        session.rejected[path] = error.localizedDescription
                        session.requestFailure = nil
                        session.reportFailure()
                        continue
                    }
                    session.fail(error)
                    guard session.phase == .running else { return }
                    if session.pending[path] == nil { session.pending[path] = text }
                    session.retry = Task { [weak session] in
                        guard (try? await Task.sleep(for: .milliseconds(750))) != nil else { return }
                        session?.flushEdits()
                    }
                    return
                }
            }
        }
    }

    /// TeXpresso looks at the files on disk again; the texts it was sent stay as sent.
    func rescan() {
        guard active, !closed else { return }
        let current = generation
        enqueue { session in
            guard session.generation == current, session.phase == .running, !session.closed, let owner = session.owner else { return }
            do {
                session.receive(try await session.calls.status("texpresso_rescan", ["id": session.id, "session": owner]))
            } catch {
                if session.generation == current, !session.closed { session.fail(error) }
            }
        }
    }

    // ---------- the view and the caret ----------

    /// The pages the PDF pane shows, from 0: TeX typesets as far as the last of them first.
    func view(_ pages: ClosedRange<Int>) {
        viewed = pages
        guard phase == .running, inPane, pages != sentView, let owner else { return }
        sentView = pages
        _ = try? calls.now("texpresso_view", ["session": owner, "first": pages.lowerBound, "last": pages.upperBound])
    }

    /// The caret has moved. Once it rests where typing didn't take it, TeX gets ready there,
    /// and the first key costs what the ones after it do.
    func caretMoved(_ path: String, _ offset: Int) {
        guard phase == .running, inPane, caret.map({ $0 != (path, offset) }) ?? true else { return }
        settling?.cancel()
        settling = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(150))) != nil, let self, phase == .running, let owner,
                  synced.contains(path), pending[path] == nil, caret.map({ $0 != (path, offset) }) ?? true else { return }
            caret = (path, offset)
            _ = try? calls.now("texpresso_caret", ["session": owner, "path": path, "offset": offset])
        }
    }

    // ---------- what the session sends back ----------

    /// What the thread has read, for the main actor to take once however much has come.
    private nonisolated final class Inbox: Sendable {
        private let state = Mutex<(news: LiveNews?, cancelled: Bool)>((nil, false))

        var cancelled: Bool { state.withLock { $0.cancelled } }
        func cancel() { state.withLock { $0 = (nil, true) } }

        /// True when nothing was waiting, so the main actor has yet to be told.
        func add(_ news: LiveNews) -> Bool {
            state.withLock { state in
                guard !state.cancelled else { return false }
                let first = state.news == nil
                var all = state.news ?? LiveNews()
                all.add(news)
                state.news = all
                return first
            }
        }

        func take() -> LiveNews? {
            state.withLock { state in
                defer { state.news = nil }
                return state.news
            }
        }
    }

    /// A thread of the session's own: the wait blocks for up to half a minute, which neither
    /// the main thread nor Swift's pool may.
    private func listen() {
        guard let owner else { return }
        let inbox = Inbox()
        self.inbox = inbox
        let (id, wait) = (id, calls.wait)
        let thread = Thread { [weak self] in
            var after = 0, version = 0, missed = false
            while !inbox.cancelled {
                var news = LiveNews()
                do {
                    let events = try wait(["id": id, "session": owner, "after": after, "timeout": 30_000])
                    after = events.seq
                    (news.running, news.error, news.revision) = (events.running, events.error, events.revision)
                    news.stopped = (events.done?.run ?? events.pdf?.run).flatMap { $0 == "partial" ? nil : $0 == "stopped" }
                    if let pdf = events.pdf {
                        // The core keeps the latest document only: one it replaced before this
                        // thread asked again took its list of changed pages with it.
                        let skipped = pdf.version != version + 1
                        version = pdf.version
                        if pdf.pages > 0 {
                            news.document = Self.read(pdf, whole: missed || skipped)
                            missed = news.document == nil
                        }
                    }
                    for page in events.pages {
                        news.pages[page.page] = Self.read(page)
                    }
                } catch {
                    (news.running, news.failure) = (false, error as? CoreError ?? CoreError(message: error.localizedDescription))
                }
                if inbox.add(news) {
                    DispatchQueue.main.async { self?.take(inbox) }
                }
                if !news.running { return }
            }
        }
        thread.name = "TeXpresso"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The file is complete when it is named, and replaced by another of its name, never rewritten:
    /// mapped, it is read as its pages are drawn and stays whole when its name goes. It has no
    /// links to see to, as a build's has: the engine writes its pages through MuPDF's PDF
    /// device, which carries content and no annotations.
    private nonisolated static func read(_ pdf: TeXpressoEvents.Document, whole: Bool) -> LiveDocument? {
        let url = URL(fileURLWithPath: pdf.path)
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let document = PDFDocument(data: data),
              document.pageCount > 0 else { return nil }
        var changed = pdf.changed.map { ranges in
            ranges.reduce(into: IndexSet()) { set, range in
                if range.count == 2, range[0] <= range[1] { set.insert(integersIn: range[0]...range[1]) }
            }
        }
        // After a document that wasn't read, any page may differ from what shows.
        if whole, changed != nil { changed = IndexSet(integersIn: 0..<document.pageCount) }
        return LiveDocument(url: url, document: document, serial: pdf.serial, changed: changed, complete: pdf.run != "stopped" && pdf.run != "partial")
    }

    /// Nil for a file already gone: TeXpresso keeps a page's last two, and a newer one is coming.
    private nonisolated static func read(_ page: TeXpressoEvents.Page) -> LivePage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: page.path), options: .alwaysMapped),
              let read = PDFDocument(data: data)?.page(at: 0) else { return nil }
        return LivePage(index: page.page, serial: page.serial, page: read)
    }

    private func take(_ inbox: Inbox) {
        guard inbox === self.inbox, let news = inbox.take() else { return }
        if news.revision > revision {
            revision = news.revision
            if showsLog { fetchStatus() }
        }
        if let document = news.document { show(document) }
        for page in news.pages.values.sorted(by: { $0.index < $1.index }) { show(page) }
        if let stopped = news.stopped { runEnded(stopped: stopped) }
        if let failure = news.failure {
            // Another window's session now, or a core that can't be asked.
            fail(failure)
            if phase != .stopped { ended() }
        } else if !news.running {
            // By itself: Stop takes the inbox away first.
            let restartable = news.error != nil && owner != nil && started.map { .now - $0 > .seconds(10) } == true
            if !restartable, let error = news.error {
                requestFailure = error
                reportFailure()
            }
            ended(restartable: restartable)
            // Its last words, unless it has been started again.
            if phase == .stopped { fetchStatus() }
        }
    }

    private func show(_ document: LiveDocument) {
        documentShown = true
        showDocument(document)
        // Pages older than the document are in it.
        let count = shownPages()
        for (index, page) in waiting.sorted(by: { $0.key < $1.key }) where page.serial < document.serial || index < count {
            waiting[index] = nil
            if page.serial > document.serial { showPage(page.page, index) }
        }
    }

    private func show(_ page: LivePage) {
        if documentShown, page.index < shownPages() {
            showPage(page.page, page.index)
        } else {
            waiting[page.index] = page
        }
    }

    /// A run stopped at an error is said so once it has lasted a second: a brace or a dollar
    /// half typed stops TeX for a moment at every other key.
    private func runEnded(stopped: Bool) {
        if !stopped {
            halting?.cancel()
            (halting, halted) = (nil, false)
        } else if !halted, halting == nil {
            halting = Task { [weak self] in
                guard (try? await Task.sleep(for: .seconds(1))) != nil, let self else { return }
                (halting, halted) = (nil, true)
            }
        }
    }

    /// The log, when what it shows is behind; once at a time, and not for every key.
    private func fetchStatus() {
        guard statusFetch == nil, let owner, (status?.revision ?? -1) < revision || phase == .stopped else { return }
        let current = generation, ended = phase == .stopped
        statusFetch = Task { [weak self] in
            if !ended { try? await Task.sleep(for: .milliseconds(250)) }
            guard let self, !Task.isCancelled else { return }
            let status = try? await calls.status("texpresso_status", ["id": id, "session": owner])
            guard !Task.isCancelled, generation == current else { return }
            statusFetch = nil
            // A session that has ended keeps its log for whoever started it.
            if let status, status.session != nil || ended { self.status = status }
            if showsLog, phase == .running { fetchStatus() }
        }
    }

    private func receive(_ status: TeXpressoStatus) {
        self.status = status
        revision = max(revision, status.revision)
        reportFailure()
        if status.running {
            phase = .running
        } else {
            if status.error == nil, phase == .starting {
                requestFailure = "TeXpresso didn’t start. Check its location in Settings and the log below."
                reportFailure()
            }
            ended()
        }
    }

    private func fail(_ error: Error) {
        requestFailure = error.localizedDescription
        if (error as? CoreError)?.status == 409 {
            generation += 1
            owner = nil
            onOwnershipLost()
            ended()
        }
        reportFailure()
    }

    private func reportFailure() {
        let errors = Set(requestErrors + [status?.error].compactMap { $0 })
        let changed = !errors.isSubset(of: lastReportedErrors)
        lastReportedErrors = errors
        if changed {
            acknowledged = false
            onFailure()
        }
    }

    private func ended(restartable: Bool = false) {
        phase = .stopped
        reset()
        rejected.removeAll()
        if !closed { onEnded(restartable) }
    }
}

/// Where live preview shows the document: the PDF pane, or TeXpresso's own window. Read as a
/// session starts.
nonisolated enum LiveViewer: String, CaseIterable, Identifiable {
    case pane, window

    static let key = "liveViewer"
    static var current: Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .pane
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .pane: "PDF Pane"
        case .window: "TeXpresso’s Window"
        }
    }
}
