import Foundation
import Observation

@Observable
final class TeXpressoSession {
    private let store: SessionStore
    private(set) var used = false
    private var acknowledged = false

    init(store: SessionStore) { self.store = store }

    var phase: LivePhase { store.live?.phase ?? .stopped }
    var engine: Engine? { store.live?.engine }
    var active: Bool { phase == .starting || phase == .running }
    private var halted: Bool { store.live?.halted == true }
    var needsAttention: Bool { halted || !acknowledged && store.live?.failures.isEmpty == false }

    var log: String {
        guard let live = store.live else { return "" }
        return (live.failures.map(\.text) + [live.log ?? ""]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var title: LocalizedStringResource {
        switch phase {
        case .stopped: needsAttention ? "Live Preview Needs Attention" : "Live Preview Stopped"
        case .starting: "Starting Live Preview…"
        case .running: halted ? "Live Preview Paused at an Error" : needsAttention ? "Live Preview Needs Attention" : "Live Preview On"
        }
    }

    func heard(_ state: LiveState) {
        if state.phase != .stopped { used = true }
        if state.phase == .starting { acknowledged = false }
    }

    func logClosed() { if phase == .stopped { acknowledged = true } }

    func alerted() { acknowledged = false }
}
