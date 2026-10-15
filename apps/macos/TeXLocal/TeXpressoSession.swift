import Foundation
import Observation
import PDFKit
import Synchronization

nonisolated struct TeXpressoStatus: Decodable, Sendable, Equatable {
    let running: Bool
    let log: String
    let output: String
    let error: String?
    let session: String?
    var revision = 0
}

nonisolated struct TeXpressoEvents: Decodable, Sendable {
    struct Document: Decodable, Sendable {
        let path: String
        /// Rises by one with each document the session writes: a gap is one the core replaced unread.
        let version: Int
        let serial: Int
        let pages: Int
        var run: String?
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
    var pages: [Page] = []
    var done: RunEnd?
}

nonisolated struct TeXpressoFile: Sendable {
    let path: String
    let text: String
}

nonisolated struct TeXpressoCaret: Equatable, Sendable {
    let path: String
    let offset: Int
}

/// Made on the session's thread and handed to the main actor, which alone uses it from then on.
nonisolated struct LiveDocument: @unchecked Sendable {
    let url: URL
    let document: PDFDocument
    let serial: Int
    var changed: IndexSet?
    /// TeX reached the document's end: pages past this document's last are gone. Otherwise they stay, as a construct half typed stops TeX short of them.
    var complete: Bool
}

nonisolated struct LivePage: @unchecked Sendable {
    let index: Int
    let serial: Int
    let page: PDFPage
}

nonisolated struct LiveNews: Sendable {
    var running = true
    var error: String?
    var revision = 0
    var document: LiveDocument?
    var pages: [Int: LivePage] = [:]
    var stopped: Bool?
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

/// Starts, stops and whole texts share a lane, so none overtakes another; a keystroke's edit goes to the core where it is made; a thread of the session's own waits in the core for pages.
@Observable
final class TeXpressoSession {
    enum Phase { case stopped, starting, running, stopping }

    struct Calls {
        var status: @MainActor (String, [String: any Sendable]) async throws -> TeXpressoStatus
        var update: @MainActor ([String: any Sendable]) async throws -> Void
        var now: @MainActor (String, [String: any Sendable]) throws -> Void
        var wait: @Sendable ([String: any Sendable]) throws -> TeXpressoEvents
    }

    private(set) var phase: Phase = .stopped
    private(set) var status: TeXpressoStatus?
    private var requestFailure: String?
    private var rejected: [String: String] = [:]
    private(set) var halted = false
    private var acknowledged = false
    var onFailure: () -> Void = {}
    var onEnded: (_ restartable: Bool) -> Void = { _ in }
    var onOwnershipLost: () -> Void = {}
    @ObservationIgnored var showDocument: (LiveDocument) -> Void = { _ in }
    @ObservationIgnored var showPage: (PDFPage, Int) -> Void = { _, _ in }
    @ObservationIgnored var shownPages: () -> Int = { 0 }
    @ObservationIgnored var showsLog = false {
        didSet {
            if showsLog { fetchStatus() } else if oldValue, phase == .stopped { acknowledged = true }
        }
    }

    @ObservationIgnored private let id: String
    @ObservationIgnored private let calls: Calls
    @ObservationIgnored private let haltsAfter: Duration
    @ObservationIgnored private var lane: Task<Void, Never>?
    @ObservationIgnored private var flushing: Int?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: String] = [:]
    @ObservationIgnored private var synced: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var lastReportedErrors: Set<String> = []
    @ObservationIgnored private(set) var owner: String?
    @ObservationIgnored private var queued: Start?
    @ObservationIgnored private var inbox: Inbox?
    @ObservationIgnored private var started: ContinuousClock.Instant?
    @ObservationIgnored private var documentShown = false
    @ObservationIgnored private var waiting: [Int: LivePage] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var statusFetch: Task<Void, Never>?
    @ObservationIgnored private var halting: Task<Void, Never>?
    @ObservationIgnored private var viewed: ClosedRange<Int>?
    @ObservationIgnored private var sentView: ClosedRange<Int>?
    @ObservationIgnored private var caret: TeXpressoCaret?
    @ObservationIgnored private var settling: Task<Void, Never>?

    struct Start {
        var files: [TeXpressoFile]
        var caret: TeXpressoCaret?
    }

    init(id: String, haltsAfter: Duration = .seconds(1), calls: Calls) {
        self.id = id
        self.calls = calls
        self.haltsAfter = haltsAfter
    }

    var active: Bool { phase == .starting || phase == .running }
    var canStart: Bool { !closed && phase == .stopped }
    var files: Set<String> { synced.union(pending.keys).union(queued?.files.map(\.path) ?? []) }
    private var requestErrors: [String] {
        [requestFailure].compactMap { $0 } + rejected.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    }
    var failure: String? {
        let messages = requestErrors
        return messages.isEmpty ? nil : messages.joined(separator: "\n\n")
    }
    var needsAttention: Bool { halted || !acknowledged && (failure != nil || status?.error != nil) }
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

    // MARK: - Starting and stopping

    func start(_ start: Start) {
        guard canStart else { return }
        beginStart(start, replacing: false)
    }

    func restart(_ start: Start) {
        guard !closed, phase != .stopping, owner != nil || phase == .starting else { return }
        if phase == .starting, queued != nil {
            queued = start
            for file in start.files { pending[file.path] = nil }
            return
        }
        beginStart(start, replacing: true)
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
        let current = generation
        enqueue { session in
            guard session.generation == current, !session.closed, let start = session.queued else { return }
            session.queued = nil
            do {
                // A patched build writes the document for the PDF pane rather than opening a window.
                var arguments: [String: any Sendable] = ["id": session.id, "files": start.files.map { ["path": $0.path, "text": $0.text] }, "pdf": true]
                if let view = session.viewed { arguments["view"] = [view.lowerBound, view.upperBound] }
                if let caret = start.caret { arguments["caret"] = ["path": caret.path, "offset": caret.offset] as [String: any Sendable] }
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

    func waitForPendingCalls() async { await lane?.value }

    private func enqueue(_ action: @escaping @MainActor (TeXpressoSession) async -> Void) {
        let previous = lane
        lane = Task {
            await previous?.value
            await action(self)
        }
    }

    // MARK: - Edits

    /// `whole` is the text after it, for a file the core has no copy of or whose copy the edit doesn't fit.
    func edit(_ path: String, _ range: NSRange, _ text: String, whole: () -> String) {
        guard active, !closed else { return }
        // Typing takes the engine's snapshot along: the caret there is no news.
        caret = TeXpressoCaret(path: path, offset: range.location + (text as NSString).length)
        if phase == .running, let owner, synced.contains(path), pending[path] == nil {
            do {
                try calls.now("texpresso_edit", ["session": owner, "path": path, "start": range.location,
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

    func update(_ file: TeXpressoFile) {
        guard active, !closed else { return }
        // Not edit by edit until it is there: a key's edit sent meanwhile could reach the core first, and this older text would then replace it.
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
                    try await session.calls.update(["id": session.id, "session": owner, "path": path, "text": text, "brief": true])
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
                    TeXLocal.restart(&session.retry, after: .milliseconds(750)) { [weak session] in session?.flushEdits() }
                    return
                }
            }
        }
    }

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

    // MARK: - The view and the caret

    func view(_ pages: ClosedRange<Int>) {
        viewed = pages
        guard phase == .running, pages != sentView, let owner else { return }
        sentView = pages
        try? calls.now("texpresso_view", ["session": owner, "first": pages.lowerBound, "last": pages.upperBound])
    }

    func caretMoved(_ path: String, _ offset: Int) {
        let moved = TeXpressoCaret(path: path, offset: offset)
        guard phase == .running, caret != moved else { return }
        TeXLocal.restart(&settling, after: .milliseconds(150)) { [weak self] in
            guard let self, phase == .running, let owner, synced.contains(path), pending[path] == nil,
                  caret != moved else { return }
            caret = moved
            try? calls.now("texpresso_caret", ["session": owner, "path": path, "offset": offset])
        }
    }

    // MARK: - What the session sends back

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

    /// A thread of the session's own: the wait blocks for up to half a minute, which neither the main thread nor Swift's pool may.
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
                        // The core keeps the latest document only: one it replaced before this thread asked again took its list of changed pages with it.
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

    /// The file is complete when it is named, and replaced by another of its name, never rewritten: mapped, it is read as its
    /// pages are drawn and stays whole when its name goes. It has no links to see to: the engine writes its pages through
    /// MuPDF's PDF device, which carries no annotations.
    private nonisolated static func read(_ pdf: TeXpressoEvents.Document, whole: Bool) -> LiveDocument? {
        let url = URL(filePath: pdf.path)
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
        guard let data = try? Data(contentsOf: URL(filePath: page.path), options: .alwaysMapped),
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

    /// A brace or a dollar half typed stops TeX for a moment at every other key, so a stopped run is said so only once it has lasted a second.
    private func runEnded(stopped: Bool) {
        if !stopped {
            halting?.cancel()
            (halting, halted) = (nil, false)
        } else if !halted, halting == nil {
            TeXLocal.restart(&halting, after: haltsAfter) { [weak self] in
                guard let self else { return }
                (halting, halted) = (nil, true)
            }
        }
    }

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

    private func fail(_ error: any Error) {
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
