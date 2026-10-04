import Foundation
import Observation

nonisolated struct TeXpressoStatus: Decodable, Sendable, Equatable {
    let available: Bool
    let running: Bool
    let executable: String?
    let log: String
    let output: String
    let error: String?
    let revision: Int
    let session: String?
}

nonisolated struct TeXpressoFile: Sendable {
    let path: String
    let text: String

    var arguments: [String: String] { ["path": path, "text": text] }
}

/// A session belongs to one open project and never changes a saved preference.
/// All calls share a lane: a late start or edit cannot overtake Stop or a rescan.
@MainActor @Observable
final class TeXpressoSession {
    enum Phase { case stopped, starting, running, stopping }
    typealias Call = @MainActor (String, [String: Any]) async throws -> TeXpressoStatus

    private(set) var phase: Phase = .stopped
    private(set) var status: TeXpressoStatus?
    private var requestFailure: String?
    private var rejected: [String: String] = [:]
    var onFailure: () -> Void = {}
    var onEnded: () -> Void = {}
    var onOwnershipLost: () -> Void = {}

    @ObservationIgnored private let id: String
    @ObservationIgnored private let call: Call
    @ObservationIgnored private var lane: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var flushing: Int?
    @ObservationIgnored private var pending: [String: String] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var lastReportedErrors: Set<String> = []
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var queuedFiles: [TeXpressoFile]?

    init(id: String, call: @escaping Call) {
        self.id = id
        self.call = call
    }

    var active: Bool { phase == .starting || phase == .running }
    var canStart: Bool { !closed && phase == .stopped }
    private var requestErrors: [String] {
        [requestFailure].compactMap { $0 } + rejected.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    }
    var failure: String? {
        let messages = requestErrors
        return messages.isEmpty ? nil : messages.joined(separator: "\n\n")
    }
    var title: String {
        if failure != nil || status?.error != nil { return "TeXpresso Needs Attention" }
        switch phase {
        case .stopped: return "TeXpresso Stopped"
        case .starting: return "Starting TeXpresso…"
        case .running: return "TeXpresso Live"
        case .stopping: return "Stopping TeXpresso…"
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

    func start(files: [TeXpressoFile]) {
        guard canStart else { return }
        beginStart(files: files, replacing: false)
    }

    func restart(files: [TeXpressoFile]) {
        guard !closed, phase != .stopping, owner != nil || phase == .starting else { return }
        if phase == .starting, queuedFiles != nil {
            queuedFiles = files
            pending.removeAll()
            debounce?.cancel()
            return
        }
        beginStart(files: files, replacing: true)
    }

    private func beginStart(files: [TeXpressoFile], replacing: Bool) {
        generation += 1
        phase = .starting
        requestFailure = nil
        rejected.removeAll()
        lastReportedErrors.removeAll()
        debounce?.cancel()
        polling?.cancel()
        pending.removeAll()
        queuedFiles = files
        let current = generation
        enqueue { session in
            guard session.generation == current, !session.closed else { return }
            guard let files = session.queuedFiles else { return }
            session.queuedFiles = nil
            do {
                var arguments: [String: Any] = ["id": session.id, "files": files.map(\.arguments)]
                if replacing {
                    guard let owner = session.owner else { session.ended(); return }
                    arguments["session"] = owner
                }
                let status = try await session.call("texpresso_start", arguments)
                // Stop/close may have superseded Start while it was in flight.
                session.owner = status.session
                guard session.generation == current, !session.closed else { return }
                session.receive(status)
                if session.active { session.poll(current) }
            } catch {
                guard session.generation == current, !session.closed else { return }
                session.fail(error)
                if session.phase != .stopped { session.ended() }
            }
        }
    }

    /// Each file keeps its most recent text even if the editor switches before
    /// the debounce expires. Edits during startup wait behind the start call.
    func update(_ file: TeXpressoFile) {
        guard active, !closed else { return }
        pending[file.path] = file.text
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else { return }
            self?.flushEdits()
        }
    }

    func flushEdits() {
        debounce?.cancel()
        debounce = nil
        guard active, !closed, !pending.isEmpty, flushing != generation else { return }
        let current = generation
        flushing = current
        enqueue { session in
            defer { if session.flushing == current { session.flushing = nil } }
            // Drain the latest snapshots, including edits received during a
            // slow call, without queuing obsolete copies behind that call.
            while session.generation == current, session.active, !session.closed,
                  let path = session.pending.keys.min(), let text = session.pending.removeValue(forKey: path) {
                let file = TeXpressoFile(path: path, text: text)
                if !(await session.request("texpresso_update", file.arguments, generation: current)) {
                    if session.generation == current, session.active, !session.closed, session.pending[path] == nil {
                        session.pending[path] = text
                    }
                    break
                }
            }
        }
    }

    /// Rescan preserves virtual files. Send the latest editor snapshot first;
    /// replaying an older snapshot afterward could overwrite intervening edits.
    func rescan(files: [TeXpressoFile]) {
        guard active, !closed else { return }
        for file in files { pending[file.path] = file.text }
        flushEdits()
        let current = generation
        enqueue { session in
            guard session.generation == current, session.active, !session.closed else { return }
            await session.request("texpresso_rescan", [:], generation: current)
        }
    }

    func stop() {
        guard phase != .stopped else { owner = nil; return }
        generation += 1
        let current = generation
        phase = .stopping
        debounce?.cancel()
        polling?.cancel()
        pending.removeAll()
        queuedFiles = nil
        enqueue { session in
            do {
                if let owner = session.owner {
                    let status = try await session.call("texpresso_stop", ["id": session.id, "session": owner])
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
        debounce?.cancel()
        polling?.cancel()
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

    @discardableResult
    private func request(_ command: String, _ args: [String: String], generation current: Int) async -> Bool {
        guard let owner else { return false }
        do {
            var arguments: [String: Any] = args
            arguments["id"] = id
            arguments["session"] = owner
            let status = try await call(command, arguments)
            guard generation == current, !closed else { return false }
            if command == "texpresso_update", let path = args["path"] { rejected.removeValue(forKey: path) }
            if pending.isEmpty { requestFailure = nil }
            receive(status)
            return true
        } catch {
            guard generation == current, !closed else { return false }
            if command == "texpresso_update", (error as? CoreError)?.status == 400, let path = args["path"] {
                // This snapshot cannot succeed on a timer. Keep its error,
                // allow other files through, and retry only on an edit/rescan.
                rejected[path] = error.localizedDescription
                requestFailure = nil
                reportFailure()
                return true
            }
            fail(error)
            return false
        }
    }

    private func receive(_ status: TeXpressoStatus) {
        if self.status != status { self.status = status }
        reportFailure()
        if status.running {
            phase = .running
        } else {
            if status.error == nil, phase == .starting {
                requestFailure = "TeXpresso did not start. Check the executable and the session log."
                reportFailure()
            }
            ended()
        }
    }

    private func fail(_ error: Error) {
        requestFailure = error.localizedDescription
        if (error as? CoreError)?.status == 409 || requestFailure == "This Live session was replaced. Start Live again." {
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
        if changed { onFailure() }
    }

    private func ended() {
        phase = .stopped
        debounce?.cancel()
        polling?.cancel()
        pending.removeAll()
        rejected.removeAll()
        queuedFiles = nil
        if !closed { onEnded() }
    }

    private func poll(_ current: Int) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled, let self, active, !closed, generation == current else { return }
                enqueue { session in
                    guard session.generation == current, session.active, !session.closed else { return }
                    if await session.request("texpresso_status", [:], generation: current), !session.pending.isEmpty {
                        session.flushEdits()
                    }
                }
                await lane?.value
            }
        }
    }
}
