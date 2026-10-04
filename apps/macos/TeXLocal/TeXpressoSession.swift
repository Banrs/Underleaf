import Foundation
import Observation

nonisolated struct TeXpressoStatus: Decodable, Sendable {
    let available: Bool
    let running: Bool
    let executable: String?
    let log: String
    let output: String
    let error: String?
    let revision: Int
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
    private(set) var failure: String?
    var onFailure: () -> Void = {}
    var onEnded: () -> Void = {}

    @ObservationIgnored private let id: String
    @ObservationIgnored private let call: Call
    @ObservationIgnored private var lane: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: String] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var lastReportedError: String?

    init(id: String, call: @escaping Call) {
        self.id = id
        self.call = call
    }

    var active: Bool { phase == .starting || phase == .running }
    var canStart: Bool { !closed && phase == .stopped }
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
        generation += 1
        phase = .starting
        failure = nil
        lastReportedError = nil
        pending.removeAll()
        let current = generation
        enqueue { session in
            guard session.generation == current, !session.closed else { return }
            do {
                let status = try await session.call("texpresso_start", ["id": session.id, "files": files.map(\.arguments)])
                guard session.generation == current, !session.closed else { return }
                session.receive(status)
                if session.active { session.poll(current) }
            } catch {
                guard session.generation == current, !session.closed else { return }
                session.fail(error)
                session.ended()
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
        guard active, !closed, !pending.isEmpty else { return }
        let files = pending.sorted { $0.key < $1.key }.map { TeXpressoFile(path: $0.key, text: $0.value) }
        pending.removeAll()
        let current = generation
        enqueue { session in
            guard session.generation == current, session.active, !session.closed else { return }
            for file in files {
                guard session.generation == current, session.active, !session.closed else { return }
                await session.request("texpresso_update", file.arguments, generation: current)
            }
        }
    }

    /// Refresh includes, images, renames and external edits, then reapply the
    /// editor snapshot so an unsaved buffer remains the preview's authority.
    func rescan(files: [TeXpressoFile]) {
        guard active, !closed else { return }
        flushEdits()
        let current = generation
        enqueue { session in
            guard session.generation == current, session.active, !session.closed else { return }
            await session.request("texpresso_rescan", [:], generation: current)
            for file in files {
                guard session.generation == current, session.active, !session.closed else { return }
                await session.request("texpresso_update", file.arguments, generation: current)
            }
        }
    }

    func stop() {
        guard phase != .stopped else { return }
        generation += 1
        let current = generation
        phase = .stopping
        debounce?.cancel()
        polling?.cancel()
        pending.removeAll()
        enqueue { session in
            do {
                let status = try await session.call("texpresso_stop", ["id": session.id])
                if session.generation == current { session.status = status }
            } catch {
                if !session.closed { session.fail(error) }
            }
            guard session.generation == current else { return }
            session.ended()
        }
    }

    func close() {
        closed = true
        stop()
        debounce?.cancel()
        polling?.cancel()
    }

    /// Used before restarting after a main-file change, and by isolated tests.
    func waitForPendingCalls() async { await lane?.value }

    private func enqueue(_ action: @escaping @MainActor (TeXpressoSession) async -> Void) {
        let previous = lane
        lane = Task {
            await previous?.value
            await action(self)
        }
    }

    private func request(_ command: String, _ args: [String: String], generation current: Int) async {
        do {
            var arguments: [String: Any] = args
            arguments["id"] = id
            let status = try await call(command, arguments)
            guard generation == current, !closed else { return }
            if command != "texpresso_status" { failure = nil }
            receive(status)
        } catch {
            guard generation == current, !closed else { return }
            fail(error)
        }
    }

    private func receive(_ status: TeXpressoStatus) {
        self.status = status
        if let error = status.error, error != lastReportedError {
            lastReportedError = error
            onFailure()
        } else if status.error == nil {
            lastReportedError = nil
        }
        if status.running {
            phase = .running
        } else {
            if status.error == nil, phase == .starting {
                failure = "TeXpresso did not start. Check the executable and the session log."
                onFailure()
            }
            ended()
        }
    }

    private func fail(_ error: Error) {
        failure = error.localizedDescription
        if failure != lastReportedError {
            lastReportedError = failure
            onFailure()
        }
    }

    private func ended() {
        phase = .stopped
        debounce?.cancel()
        polling?.cancel()
        pending.removeAll()
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
                    await session.request("texpresso_status", [:], generation: current)
                }
                await lane?.value
            }
        }
    }
}
