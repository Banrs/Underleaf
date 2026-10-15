import Foundation
import Observation
import PDFKit

nonisolated struct TeXpressoStatus: Decodable, Sendable, Equatable {
    let running: Bool
    let log: String
    let output: String
    let error: String?
    let session: String?
    var revision = 0
}

/// The session's `live` event, and its answer to Start and Stop.
nonisolated struct LiveState: Decodable, Sendable {
    let phase: TeXpressoSession.Phase
    let halted: Bool
    let failure: String?
    let error: String?
    let token: String?
    let revision: Int
    /// An error the window hasn't been shown yet: the Live Preview Log opens on it.
    let alert: Bool?
}

/// A whole document TeXpresso wrote (`live_document`); `changed` is nil when any page may differ.
nonisolated struct LiveDocumentEvent: Decodable, Sendable {
    let path: String
    let serial: Int
    var changed: [[Int]]?
    /// TeX reached the document's end: pages past this document's last are gone. Otherwise they stay, as a construct half typed stops TeX short of them.
    let complete: Bool
}

/// One page typeset again (`live_page`), newer than any document of a lower serial.
nonisolated struct LivePageEvent: Decodable, Sendable {
    let page: Int
    let path: String
    let serial: Int
}

/// Made off the main actor and handed to it, which alone uses it from then on.
nonisolated struct LiveDocument: @unchecked Sendable {
    let url: URL
    let document: PDFDocument
    let serial: Int
    var changed: IndexSet?
    var complete: Bool
}

nonisolated struct LivePage: @unchecked Sendable {
    let index: Int
    let serial: Int
    let page: PDFPage
}

/// Live Preview as the window shows it: the core's session runs it and says what changed; this reads the PDFs it writes.
@Observable
final class TeXpressoSession {
    nonisolated enum Phase: String, Decodable, Sendable { case stopped, starting, running, stopping }

    private(set) var phase = Phase.stopped
    private(set) var status: TeXpressoStatus?
    private(set) var failure: String?
    private var error: String?
    private(set) var halted = false
    private var acknowledged = false
    /// TeXpresso's session, for SyncTeX against its PDF.
    @ObservationIgnored private(set) var token: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored var onAlert: () -> Void = {}
    @ObservationIgnored var onEnded: () -> Void = {}
    @ObservationIgnored var showDocument: (LiveDocument) -> Void = { _ in }
    @ObservationIgnored var showPage: (PDFPage, Int) -> Void = { _, _ in }
    @ObservationIgnored var shownPages: () -> Int = { 0 }
    @ObservationIgnored var readStatus: () async -> TeXpressoStatus? = { nil }
    @ObservationIgnored var showsLog = false {
        didSet {
            if showsLog { fetchStatus() } else if oldValue, phase == .stopped { acknowledged = true }
        }
    }

    var active: Bool { phase == .starting || phase == .running }
    var canStart: Bool { phase == .stopped }
    var needsAttention: Bool { halted || !acknowledged && (failure != nil || error != nil) }
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

    // MARK: - The session's state

    /// Shown at once, not when the session says so: the toggle that asked follows the click.
    func starting() {
        guard phase == .stopped else { return }
        phase = .starting
        acknowledged = false
        reset()
    }

    func stopping() {
        guard active else { return }
        phase = .stopping
        reset()
    }

    /// Stop's answer, for a preview that had ended already, which sends no event.
    func stopped(_ state: LiveState) {
        if state.phase == .stopped, phase == .stopping { receive(state) }
    }

    func receive(_ state: LiveState) {
        let was = phase
        if state.phase == .starting, was == .stopped { acknowledged = false }
        (phase, halted, failure, error, token) = (state.phase, state.halted, state.failure, state.error, state.token)
        if state.alert == true {
            acknowledged = false
            onAlert()
        }
        if state.revision > revision {
            revision = state.revision
            if showsLog { fetchStatus() }
        }
        if !active { reset() }
        guard phase == .stopped, was != .stopped else { return }
        // Its last words, unless it starts again.
        fetchStatus()
        onEnded()
    }

    @ObservationIgnored private var statusFetch: Task<Void, Never>?

    private func fetchStatus() {
        guard statusFetch == nil, (status?.revision ?? -1) < revision || phase == .stopped else { return }
        let ended = phase == .stopped, asked = revision
        statusFetch = Task { [weak self] in
            guard let self else { return }
            let status = await readStatus()
            statusFetch = nil
            // A session that has ended keeps its log for whoever started it.
            if let status, status.session != nil || ended { self.status = status }
            if showsLog, revision > asked { fetchStatus() }
        }
    }

    // MARK: - Its PDFs

    private nonisolated struct Batch: Sendable {
        var document: LiveDocumentEvent?
        var pages: [Int: LivePageEvent] = [:]
        var isEmpty: Bool { document == nil && pages.isEmpty }
    }

    /// What came while the last was being read: the latest document and each page's latest.
    @ObservationIgnored private var batch = Batch()
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var missed = false
    @ObservationIgnored private var documentShown = false
    @ObservationIgnored private var waiting: [Int: LivePage] = [:]

    private func reset() {
        generation += 1
        batch = Batch()
        waiting.removeAll()
        (missed, documentShown) = (false, false)
    }

    func receive(_ event: LiveDocumentEvent) {
        guard active else { return }
        var document = event
        // The one not shown is skipped, so its changes are this one's too.
        if let skipped = batch.document?.changed, let changed = document.changed {
            document.changed = changed + skipped
        } else if batch.document != nil {
            document.changed = nil
        }
        batch.document = document
        batch.pages = batch.pages.filter { $0.value.serial > document.serial }
        readBatch()
    }

    func receive(_ event: LivePageEvent) {
        guard active, (batch.pages[event.page]?.serial ?? -1) < event.serial else { return }
        batch.pages[event.page] = event
        readBatch()
    }

    private func readBatch() {
        guard !reading, !batch.isEmpty else { return }
        reading = true
        let taken = batch, whole = missed, current = generation
        batch = Batch()
        Task {
            let read = await Self.read(taken, whole: whole)
            reading = false
            if current == generation {
                if taken.document != nil { missed = read.document == nil }
                if let document = read.document { show(document) }
                for page in read.pages { show(page) }
            }
            readBatch()
        }
    }

    @concurrent private nonisolated static func read(_ batch: Batch, whole: Bool) async -> (document: LiveDocument?, pages: [LivePage]) {
        let document = batch.document.flatMap { read($0, whole: whole) }
        return (document, batch.pages.values.sorted { $0.page < $1.page }.compactMap { read($0) })
    }

    /// The file is complete when it is named, and replaced by another of its name, never rewritten: mapped, it is read as its
    /// pages are drawn and stays whole when its name goes. It has no links to see to: the engine writes its pages through
    /// MuPDF's PDF device, which carries no annotations.
    private nonisolated static func read(_ event: LiveDocumentEvent, whole: Bool) -> LiveDocument? {
        let url = URL(filePath: event.path)
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let document = PDFDocument(data: data),
              document.pageCount > 0 else { return nil }
        var changed = event.changed.map { ranges in
            ranges.reduce(into: IndexSet()) { set, range in
                if range.count == 2, range[0] <= range[1] { set.insert(integersIn: range[0]...range[1]) }
            }
        }
        // After a document that wasn't read, any page may differ from what shows.
        if whole, changed != nil { changed = IndexSet(integersIn: 0..<document.pageCount) }
        return LiveDocument(url: url, document: document, serial: event.serial, changed: changed, complete: event.complete)
    }

    /// Nil for a file already gone: TeXpresso keeps a page's last two, and a newer one is coming.
    private nonisolated static func read(_ event: LivePageEvent) -> LivePage? {
        guard let data = try? Data(contentsOf: URL(filePath: event.path), options: .alwaysMapped),
              let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        return LivePage(index: event.page, serial: event.serial, page: page)
    }

    private func show(_ document: LiveDocument) {
        documentShown = true
        showDocument(document)
        // Pages older than the document are in it; a page waiting for the page count to reach it goes in once it does.
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
}
