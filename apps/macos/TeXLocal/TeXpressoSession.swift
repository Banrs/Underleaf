import Observation
import PDFKit

nonisolated struct LiveState: Decodable, Sendable {
    let phase: TeXpressoSession.Phase
    let halted: Bool
    let failure, error: String?
    /// The Live Preview Log's whole text, while the window shows it (`session_live_log`) and with an alert.
    let log: String?
    /// An error not shown yet, which the Live Preview Log opens on.
    let alert: Bool?
}

/// A whole document TeXpresso wrote (`live_document`); `changed` is nil when any page may differ.
nonisolated struct LiveDocumentEvent: Decodable, Sendable {
    let path: String
    var changed: [[Int]]?
    /// TeX reached the document's end, so pages past its last are gone; a construct half typed stops TeX short of them.
    let complete: Bool
}

/// One page typeset again (`live_page`). The session sends a batch's document before the batch's pages and drops the
/// pages a document has, so a page is newer than any document before it.
nonisolated struct LivePageEvent: Decodable, Sendable { let page: Int, path: String }

/// Read on the core's event thread as the event is decoded, so the main actor gets it ready to draw.
nonisolated enum LiveRead: Sendable {
    case document(LiveDocument?)
    case page(LivePage?)

    /// Mapped: the file is replaced, never rewritten, so it stays whole when its name goes. It has no links to see to.
    init(_ event: LiveDocumentEvent) {
        guard let document = Self.mapped(URL(filePath: event.path)), document.pageCount > 0 else {
            self = .document(nil)
            return
        }
        let changed = event.changed.map { ranges in
            ranges.reduce(into: IndexSet()) { set, range in
                if range.count == 2, range[0] <= range[1] { set.insert(integersIn: range[0]...range[1]) }
            }
        }
        self = .document(LiveDocument(document: document, changed: changed, complete: event.complete))
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
nonisolated struct LiveDocument: @unchecked Sendable { let document: PDFDocument, changed: IndexSet?, complete: Bool }

nonisolated struct LivePage: @unchecked Sendable { let index: Int, page: PDFPage }

@Observable
final class TeXpressoSession {
    nonisolated enum Phase: String, Decodable, Sendable { case stopped, starting, running, stopping }

    private(set) var phase = Phase.stopped {
        didSet { if phase != .stopped { used = true } }
    }
    private var failed = false
    private(set) var halted = false
    private(set) var log = ""
    private(set) var used = false
    private var acknowledged = false
    /// The setting's as this session started: a change waits for the next.
    private var viewer = LiveViewer.pane

    var active: Bool { phase == .starting || phase == .running }
    var inWindow: Bool { active && viewer == .window }
    var needsAttention: Bool { halted || !acknowledged && failed }
    var title: LocalizedStringResource {
        switch phase {
        case .stopped: needsAttention ? "Live Preview Needs Attention" : "Live Preview Stopped"
        case .starting: "Starting Live Preview…"
        case .running: halted ? "Live Preview Paused at an Error" : needsAttention ? "Live Preview Needs Attention" : "Live Preview On"
        case .stopping: "Stopping Live Preview…"
        }
    }

    // MARK: - The session's state

    /// At once, not when the session says so: the toggle that asked follows the click.
    func starting(in viewer: LiveViewer) {
        (phase, self.viewer) = (.starting, viewer)
        acknowledged = false
    }

    func stopping() { if active { phase = .stopping } }

    /// An ended session's trouble counts as seen once its log closes.
    func logClosed() { if phase == .stopped { acknowledged = true } }

    func receive(_ state: LiveState) {
        if state.alert == true || state.phase == .starting && phase == .stopped { acknowledged = false }
        (phase, halted, failed) = (state.phase, state.halted, state.failure != nil || state.error != nil)
        if let log = state.log { self.log = log }
    }
}

/// Read as a session starts.
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
