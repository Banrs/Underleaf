import Observation
import PDFKit

nonisolated struct LiveState: Decodable, Sendable {
    let phase: TeXpressoSession.Phase
    let engine: String
    let halted: Bool
    let failure, error: String?
    let log: String?
    let alert: Bool?
}

nonisolated struct LiveDocumentEvent: Decodable, Sendable {
    let path: String
    var changed: [[Int]]?
    let complete: Bool
}

nonisolated struct LivePageEvent: Decodable, Sendable { let page: Int, path: String }

nonisolated enum LiveRead: Sendable {
    case document(LiveDocument?)
    case page(LivePage?)

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

    init(_ event: LivePageEvent) {
        self = .page(Self.mapped(URL(filePath: event.path))?.page(at: 0).map { LivePage(index: event.page, page: $0) })
    }

    private static func mapped(_ url: URL) -> PDFDocument? {
        (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap(PDFDocument.init(data:))
    }
}

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
    private(set) var engine: String?
    private(set) var log = ""
    private(set) var used = false
    private var acknowledged = false

    var active: Bool { phase == .starting || phase == .running }
    var needsAttention: Bool { halted || !acknowledged && failed }
    var title: LocalizedStringResource {
        switch phase {
        case .stopped: needsAttention ? "Live Preview Needs Attention" : "Live Preview Stopped"
        case .starting: "Starting Live Preview…"
        case .running: halted ? "Live Preview Paused at an Error" : needsAttention ? "Live Preview Needs Attention" : "Live Preview On"
        case .stopping: "Stopping Live Preview…"
        }
    }

    func starting() {
        phase = .starting
        acknowledged = false
    }

    func stopping() { if active { phase = .stopping } }

    func logClosed() { if phase == .stopped { acknowledged = true } }

    func receive(_ state: LiveState) {
        if state.alert == true || state.phase == .starting && phase == .stopped { acknowledged = false }
        (phase, engine, halted, failed) = (state.phase, state.engine, state.halted, state.failure != nil || state.error != nil)
        if let log = state.log { self.log = log }
    }
}
