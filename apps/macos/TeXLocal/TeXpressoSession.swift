import Observation
import PDFKit

/// The session's `live` event, and its answer to Start and Stop.
nonisolated struct LiveState: Decodable, Sendable {
    let phase: TeXpressoSession.Phase
    let halted: Bool
    let failure, error: String?
    /// The Live Preview Log's whole text, while the window shows it (`session_live_log`) and with an alert; nil otherwise.
    let log: String?
    /// An error the window hasn't been shown yet: the Live Preview Log opens on it. Start's and Stop's answers have none.
    let alert: Bool?
}

/// A whole document TeXpresso wrote (`live_document`); `changed` is nil when any page may differ.
nonisolated struct LiveDocumentEvent: Decodable, Sendable {
    let path: String
    var changed: [[Int]]?
    /// TeX reached the document's end: pages past this document's last are gone. Otherwise they stay, as a construct half typed stops TeX short of them.
    let complete: Bool
}

/// One page typeset again (`live_page`). The session sends a batch's document before the batch's pages and drops the
/// pages a document has, so a page is newer than any document before it.
nonisolated struct LivePageEvent: Decodable, Sendable { let page: Int, path: String }

/// A live event's PDF, read on the core's event thread as the event is decoded, so the main actor gets it ready to draw:
/// the page's one-page PDF, or the whole document; nil inside where the file couldn't be read.
nonisolated enum LiveRead: Sendable {
    case document(LiveDocument?)
    case page(LivePage?)

    /// The file is complete when it is named, and replaced by another of its name, never rewritten: mapped, it is read as its
    /// pages are drawn and stays whole when its name goes. It has no links to see to: the engine writes its pages through
    /// MuPDF's PDF device, which carries no annotations.
    init(_ event: LiveDocumentEvent) {
        let url = URL(filePath: event.path)
        guard let document = Self.mapped(url), document.pageCount > 0 else {
            self = .document(nil)
            return
        }
        let changed = event.changed.map { ranges in
            ranges.reduce(into: IndexSet()) { set, range in
                if range.count == 2, range[0] <= range[1] { set.insert(integersIn: range[0]...range[1]) }
            }
        }
        self = .document(LiveDocument(url: url, document: document, changed: changed, complete: event.complete))
    }

    /// None for a file already gone: TeXpresso keeps a page's last two, and a newer one is coming.
    init(_ event: LivePageEvent) {
        self = .page(Self.mapped(URL(filePath: event.path))?.page(at: 0).map { LivePage(index: event.page, page: $0) })
    }

    private static func mapped(_ url: URL) -> PDFDocument? {
        (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap(PDFDocument.init(data:))
    }
}

/// Made off the main actor and handed to it, which alone uses it from then on.
nonisolated struct LiveDocument: @unchecked Sendable {
    let url: URL
    let document: PDFDocument
    let changed: IndexSet?
    let complete: Bool
}

nonisolated struct LivePage: @unchecked Sendable { let index: Int, page: PDFPage }

/// Live Preview as the window shows it: the core's session runs it and says how it goes. Its PDFs go to the PDF pane.
@Observable
final class TeXpressoSession {
    nonisolated enum Phase: String, Decodable, Sendable { case stopped, starting, running, stopping }

    private(set) var phase = Phase.stopped {
        didSet { if phase != .stopped { used = true } }
    }
    private(set) var failure: String?
    private var error: String?
    private(set) var halted = false
    /// The Live Preview Log as the session last sent it.
    private(set) var log = ""
    /// Whether Live Preview has started in this window.
    private(set) var used = false
    private var acknowledged = false
    @ObservationIgnored var onAlert: () -> Void = {}
    @ObservationIgnored var onEnded: () -> Void = {}
    @ObservationIgnored private var logWatch: Task<Void, Never>?

    var active: Bool { phase == .starting || phase == .running }
    var canStart: Bool { phase == .stopped }
    var needsAttention: Bool { halted || !acknowledged && (failure != nil || error != nil) }
    var title: LocalizedStringResource {
        switch phase {
        case .stopped: needsAttention ? "Live Preview Needs Attention" : "Live Preview Stopped"
        case .starting: "Starting Live Preview…"
        case .running: halted ? "Live Preview Paused at an Error" : needsAttention ? "Live Preview Needs Attention" : "Live Preview On"
        case .stopping: "Stopping Live Preview…"
        }
    }

    /// The session sends the log while the panel shows it, as `tell` says, and the trouble of a session that has ended counts
    /// as seen once the log closes.
    func watchLog(_ shows: @escaping @MainActor @Sendable () -> Bool, tell: @escaping @MainActor (Bool) -> Void) {
        logWatch = track(shows, initial: false) { [weak self] shows in
            guard let self else { return }
            tell(shows)
            if !shows, phase == .stopped { acknowledged = true }
        }
    }

    isolated deinit { logWatch?.cancel() }

    // MARK: - The session's state

    /// Shown at once, not when the session says so: the toggle that asked follows the click.
    func starting() {
        guard phase == .stopped else { return }
        phase = .starting
        acknowledged = false
    }

    func stopping() { if active { phase = .stopping } }

    /// Stop's answer, for a preview that had ended already, which sends no event.
    func stopped(_ state: LiveState) {
        if state.phase == .stopped, phase == .stopping { receive(state) }
    }

    func receive(_ state: LiveState) {
        let was = phase
        if state.phase == .starting, was == .stopped { acknowledged = false }
        (phase, halted, failure, error) = (state.phase, state.halted, state.failure, state.error)
        // A log not sent is the one before.
        if let log = state.log { self.log = log }
        if state.alert == true {
            acknowledged = false
            onAlert()
        }
        if phase == .stopped, was != .stopped { onEnded() }
    }
}

/// Where live preview shows the document: the PDF pane, or TeXpresso's own window. Read as a session starts.
nonisolated enum LiveViewer: String, CaseIterable, Identifiable {
    case pane, window

    static var current: Self {
        UserDefaults.standard.string(forKey: DefaultsKey.liveViewer).flatMap(Self.init) ?? .pane
    }

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .pane: "PDF Pane"
        case .window: "TeXpresso’s Window"
        }
    }
}
