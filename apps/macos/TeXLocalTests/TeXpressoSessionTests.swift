import Foundation
import Testing
@testable import TeXLocal

@MainActor
struct TeXpressoSessionTests {
    private func status(running: Bool = true, error: String? = nil) -> TeXpressoStatus {
        TeXpressoStatus(available: true, running: running, executable: "/tmp/texpresso",
                       log: "", output: "", error: error, revision: 0)
    }

    private func until(_ ready: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if ready() { return }
            await Task.yield()
        }
        throw NSError(domain: "TeXpressoSessionTests", code: 1)
    }

    @Test func editsDuringStartKeepEachIncludedFileAndRescanOrder() async throws {
        var commands: [String] = []
        var updates: [String: String] = [:]
        var start: CheckedContinuation<TeXpressoStatus, Never>?
        let session = TeXpressoSession(id: "project") { command, arguments in
            commands.append(command)
            #expect(arguments["id"] as? String == "project")
            if command == "texpresso_start" {
                return await withCheckedContinuation { start = $0 }
            }
            if command == "texpresso_update", let path = arguments["path"] as? String {
                updates[path] = arguments["text"] as? String
            }
            return status(running: command != "texpresso_stop")
        }
        session.start(files: [])
        try await until { start != nil }
        session.update(TeXpressoFile(path: "main.tex", text: "old"))
        session.update(TeXpressoFile(path: "main.tex", text: "é🦆"))
        session.update(TeXpressoFile(path: "parts/a.tex", text: "include"))
        session.rescan(files: [TeXpressoFile(path: "parts/a.tex", text: "current")])
        #expect(commands == ["texpresso_start"])
        start?.resume(returning: status())
        await session.waitForPendingCalls()
        #expect(commands == ["texpresso_start", "texpresso_update", "texpresso_update", "texpresso_rescan", "texpresso_update"])
        #expect(updates == ["main.tex": "é🦆", "parts/a.tex": "current"])
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func closeWaitsForAnInFlightStartThenStopsIt() async throws {
        var commands: [String] = []
        var start: CheckedContinuation<TeXpressoStatus, Never>?
        var ended = 0
        let session = TeXpressoSession(id: "project") { command, _ in
            commands.append(command)
            if command == "texpresso_start" {
                return await withCheckedContinuation { start = $0 }
            }
            return status(running: false)
        }
        session.onEnded = { ended += 1 }
        session.start(files: [])
        try await until { start != nil }
        session.update(TeXpressoFile(path: "main.tex", text: "pending"))
        session.close()
        #expect(session.phase == .stopping && !session.canStart)
        start?.resume(returning: status())
        await session.waitForPendingCalls()
        #expect(commands == ["texpresso_start", "texpresso_stop"])
        #expect(session.phase == .stopped && ended == 0)
    }

    @Test func failedStartShowsItsLogAndCanBeRetried() async {
        var starts = 0, failures = 0, ended = 0
        let session = TeXpressoSession(id: "project") { command, _ in
            if command == "texpresso_start" { starts += 1 }
            return starts == 1 ? status(running: false, error: "Executable unavailable")
                : status(running: command != "texpresso_stop")
        }
        session.onFailure = { failures += 1 }
        session.onEnded = { ended += 1 }
        session.start(files: [])
        await session.waitForPendingCalls()
        #expect(session.canStart && session.log == "Executable unavailable")
        #expect(failures == 1 && ended == 1)
        session.start(files: [])
        await session.waitForPendingCalls()
        #expect(session.active && session.log.isEmpty)
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func typingDebouncesToTheLatestSnapshot() async throws {
        var texts: [String] = []
        let session = TeXpressoSession(id: "project") { command, arguments in
            if command == "texpresso_update", let text = arguments["text"] as? String { texts.append(text) }
            return status(running: command != "texpresso_stop")
        }
        session.start(files: [])
        await session.waitForPendingCalls()
        for text in ["a", "ab", "abc"] { session.update(TeXpressoFile(path: "main.tex", text: text)) }
        #expect(texts.isEmpty)
        try await Task.sleep(for: .milliseconds(180))
        await session.waitForPendingCalls()
        #expect(texts == ["abc"])
        session.stop()
        await session.waitForPendingCalls()
    }
}
