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

/// A live event's PDF, read on the core's event thread so the main queue gets it ready to draw, in one hop: the page's
/// one-page PDF, or the whole document; nil inside where the file couldn't be read. Nil for any other event.
nonisolated enum LiveRead: Sendable {
    case document(LiveDocument?)
    case page(LivePage?)

    private struct Head: Decodable { let type: String }

    init?(_ event: Data) {
        let decoder = JSONDecoder()
        switch try? decoder.decode(Head.self, from: event).type {
        case "live_document": self = .document((try? decoder.decode(LiveDocumentEvent.self, from: event)).flatMap(TeXpressoSession.read))
        case "live_page": self = .page((try? decoder.decode(LivePageEvent.self, from: event)).flatMap(TeXpressoSession.read))
        default: return nil
        }
    }
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
    @ObservationIgnored var readStatus: @MainActor () async -> TeXpressoStatus? = { nil }
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

    @ObservationIgnored private var missed = false
    @ObservationIgnored private var documentShown = false
    @ObservationIgnored private var waiting: [Int: LivePage] = [:]

    private func reset() {
        waiting.removeAll()
        (missed, documentShown) = (false, false)
    }

    /// A live PDF as `Core` read it where the event arrived, in the order the session sent them.
    func receive(_ read: LiveRead) {
        guard active else { return }
        switch read {
        case .document(nil):
            missed = true
        case .document(var document?):
            // After a document that wasn't read, any page may differ from what shows.
            if missed, document.changed != nil { document.changed = IndexSet(integersIn: 0..<document.document.pageCount) }
            missed = false
            show(document)
        case .page(let page):
            if let page { show(page) }
        }
    }

    /// The file is complete when it is named, and replaced by another of its name, never rewritten: mapped, it is read as its
    /// pages are drawn and stays whole when its name goes. It has no links to see to: the engine writes its pages through
    /// MuPDF's PDF device, which carries no annotations.
    fileprivate nonisolated static func read(_ event: LiveDocumentEvent) -> LiveDocument? {
        let url = URL(filePath: event.path)
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let document = PDFDocument(data: data),
              document.pageCount > 0 else { return nil }
        let changed = event.changed.map { ranges in
            ranges.reduce(into: IndexSet()) { set, range in
                if range.count == 2, range[0] <= range[1] { set.insert(integersIn: range[0]...range[1]) }
            }
        }
        return LiveDocument(url: url, document: document, serial: event.serial, changed: changed, complete: event.complete)
    }

    /// Nil for a file already gone: TeXpresso keeps a page's last two, and a newer one is coming.
    fileprivate nonisolated static func read(_ event: LivePageEvent) -> LivePage? {
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
