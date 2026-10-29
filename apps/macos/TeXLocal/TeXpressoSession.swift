import Observation
import PDFKit

nonisolated enum LiveRead: @unchecked Sendable {
    case document(PDFDocument?)
    case page(PDFPage?, at: Int)

    init(_ live: LiveDocument) {
        self = .document(Self.mapped(URL(filePath: live.path)).flatMap { $0.pageCount > 0 ? $0 : nil })
    }

    init(_ live: LivePage) {
        self = .page(Self.mapped(URL(filePath: live.path))?.page(at: 0), at: live.page)
    }

    private static func mapped(_ url: URL) -> PDFDocument? {
        (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap(PDFDocument.init(data:))
    }
}

@Observable
final class TeXpressoSession {
    private(set) var phase = LivePhase.stopped {
        didSet { if phase != .stopped { used = true } }
    }
    private var failed = false
    private(set) var halted = false
    private(set) var engine: Engine?
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

    func alerted() { acknowledged = false }

    func receive(_ state: LiveState) {
        if state.phase == .starting && phase == .stopped { acknowledged = false }
        (phase, engine, halted, failed) = (state.phase, state.engine, state.halted, state.failure != nil || state.error != nil)
        if let log = state.log { self.log = log }
    }
}
