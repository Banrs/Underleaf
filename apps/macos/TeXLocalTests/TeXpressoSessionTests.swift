import Foundation
import Observation
import os
import Testing
@testable import TeXLocal

@MainActor
struct TeXpressoSessionTests {
    private func status(running: Bool = true, error: String? = nil) -> TeXpressoStatus {
        TeXpressoStatus(running: running, log: "", output: "", error: error, session: running ? "owner" : nil)
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
            #expect(command == "texpresso_start" || arguments["session"] as? String == "owner")
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
        session.update(TeXpressoFile(path: "parts/a.tex", text: "typed after rescan"))
        start?.resume(returning: status())
        await session.waitForPendingCalls()
        #expect(commands == ["texpresso_start", "texpresso_update", "texpresso_update", "texpresso_rescan"])
        #expect(updates == ["main.tex": "é🦆", "parts/a.tex": "typed after rescan"])
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func closeWaitsForAnInFlightStartThenStopsIt() async throws {
        var commands: [String] = []
        var start: CheckedContinuation<TeXpressoStatus, Never>?
        var ended = 0
        let session = TeXpressoSession(id: "project") { command, arguments in
            commands.append(command)
            if command == "texpresso_start" {
                return await withCheckedContinuation { start = $0 }
            }
            #expect(arguments["session"] as? String == "owner")
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

    @Test(arguments: [0, 400, 500])
    func slowUpdatesCoalesceAndFailedWritesKeepTheNewestSnapshot(failureStatus: Int) async throws {
        var texts: [String] = []
        var first: CheckedContinuation<TeXpressoStatus, Error>?
        let session = TeXpressoSession(id: "project") { command, arguments in
            if command == "texpresso_update", let text = arguments["text"] as? String {
                texts.append(text)
                if texts.count == 1 { return try await withCheckedThrowingContinuation { first = $0 } }
            }
            return status(running: command != "texpresso_stop")
        }
        session.start(files: [])
        await session.waitForPendingCalls()
        session.update(TeXpressoFile(path: "main.tex", text: "first"))
        session.flushEdits()
        try await until { first != nil }
        for index in 0..<100 {
            session.update(TeXpressoFile(path: "main.tex", text: "edit \(index)"))
            session.flushEdits()
        }
        session.update(TeXpressoFile(path: "part.tex", text: "included $"))
        session.flushEdits()
        if failureStatus != 0 {
            first?.resume(throwing: CoreError(message: "Update failed", status: failureStatus))
            if failureStatus != 400 {
                await session.waitForPendingCalls()
                #expect(texts == ["first"] && session.failure != nil && session.active)
                session.flushEdits()
            }
        } else {
            first?.resume(returning: status())
        }
        await session.waitForPendingCalls()
        #expect(texts == ["first", "edit 99", "included $"] && session.failure == nil)
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func unchangedStatusDoesNotInvalidateTheLogView() async {
        let error = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        let session = TeXpressoSession(id: "project") { command, _ in
            status(running: command != "texpresso_stop", error: error.withLock { $0 })
        }
        session.start(files: [])
        await session.waitForPendingCalls()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = session.status } onChange: { changed.withLock { $0 = true } }
        session.rescan(files: [])
        await session.waitForPendingCalls()
        #expect(!changed.withLock { $0 })
        error.withLock { $0 = "Missing $" }
        session.rescan(files: [])
        await session.waitForPendingCalls()
        #expect(changed.withLock { $0 } && session.log == "Missing $")
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func pollingRecoversAnUnsentEditWithoutMoreTyping() async throws {
        var attempts = 0
        let session = TeXpressoSession(id: "project") { command, arguments in
            if command == "texpresso_update" {
                #expect(arguments["text"] as? String == "unsent $")
                attempts += 1
                if attempts == 1 { throw NSError(domain: "transport", code: 1) }
            }
            return status(running: command != "texpresso_stop")
        }
        session.start(files: [])
        await session.waitForPendingCalls()
        session.update(TeXpressoFile(path: "main.tex", text: "unsent $"))
        session.flushEdits()
        await session.waitForPendingCalls()
        #expect(attempts == 1 && session.failure != nil)
        try await Task.sleep(for: .milliseconds(850))
        await session.waitForPendingCalls()
        #expect(attempts == 2 && session.failure == nil && session.active)
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func rejectedBufferDoesNotRetryOnPollOrBlockOtherFiles() async throws {
        var updates: [String] = [], failures = 0
        let session = TeXpressoSession(id: "project") { command, arguments in
            if command == "texpresso_update", let path = arguments["path"] as? String {
                updates.append(path)
                if path != "z.tex", arguments["text"] as? String != "fixed" {
                    throw CoreError(message: "Live buffer exceeds 8 MB.", status: 400)
                }
            }
            return status(running: command != "texpresso_stop")
        }
        session.onFailure = { failures += 1 }
        session.start(files: [])
        await session.waitForPendingCalls()
        let invalid = TeXpressoFile(path: "a.tex", text: "rejected")
        session.update(invalid)
        session.update(TeXpressoFile(path: "z.tex", text: "valid"))
        session.flushEdits()
        await session.waitForPendingCalls()
        #expect(updates == ["a.tex", "z.tex"])
        #expect(failures == 1)
        try await Task.sleep(for: .milliseconds(850))
        await session.waitForPendingCalls()
        #expect(updates == ["a.tex", "z.tex"])
        #expect(failures == 1 && session.failure != nil)
        session.rescan(files: [invalid])
        await session.waitForPendingCalls()
        #expect(updates == ["a.tex", "z.tex", "a.tex"] && failures == 1 && session.failure != nil)
        session.update(TeXpressoFile(path: "b.tex", text: "rejected too"))
        session.flushEdits()
        await session.waitForPendingCalls()
        #expect(failures == 2)
        session.update(TeXpressoFile(path: "a.tex", text: "fixed"))
        session.flushEdits()
        await session.waitForPendingCalls()
        #expect(session.failure == "b.tex: Live buffer exceeds 8 MB." && failures == 2)
        session.update(TeXpressoFile(path: "b.tex", text: "fixed"))
        session.flushEdits()
        await session.waitForPendingCalls()
        #expect(session.failure == nil && session.active && failures == 2)
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test(arguments: ["texpresso_update", "texpresso_start"])
    func replacedOwnershipStopsLocalWorkWithoutStoppingTheReplacement(command failedCommand: String) async {
        var commands: [String] = []
        var ownershipLosses = 0, ended = 0
        let session = TeXpressoSession(id: "project") { command, arguments in
            commands.append(command)
            if commands.count > 1 {
                #expect(arguments["session"] as? String == "owner")
                throw CoreError(message: "Another window started TeXpresso for this project. Start TeXpresso again to preview here.", status: 409)
            }
            return status()
        }
        session.onOwnershipLost = { ownershipLosses += 1 }
        session.onEnded = { ended += 1 }
        session.start(files: [])
        await session.waitForPendingCalls()
        if failedCommand == "texpresso_start" {
            session.restart(files: [])
        } else {
            session.update(TeXpressoFile(path: "main.tex", text: "old owner"))
            session.flushEdits()
        }
        await session.waitForPendingCalls()
        #expect(!session.active && session.failure != nil && ownershipLosses == 1 && ended == 1)
        session.restart(files: [])
        session.close()
        await session.waitForPendingCalls()
        #expect(commands == ["texpresso_start", failedCommand])
    }

    @Test(arguments: [true, false])
    func restartDuringStartOnlyUsesAcquiredOwnership(started: Bool) async throws {
        var owners: [String?] = []
        var first: CheckedContinuation<TeXpressoStatus, Never>?
        let session = TeXpressoSession(id: "project") { command, arguments in
            if command == "texpresso_start" {
                owners.append(arguments["session"] as? String)
                if owners.count == 1 { return await withCheckedContinuation { first = $0 } }
            }
            return status(running: command != "texpresso_stop")
        }
        session.start(files: [])
        try await until { first != nil }
        session.restart(files: [TeXpressoFile(path: "main.tex", text: "changed main")])
        first?.resume(returning: status(running: started))
        await session.waitForPendingCalls()
        #expect(owners == (started ? [nil, "owner"] : [nil]))
        #expect(session.active == started)
        session.stop()
        await session.waitForPendingCalls()
    }

    @Test func restartCoalescesIntoAnUndispatchedExplicitStart() async {
        var starts = 0
        let session = TeXpressoSession(id: "project") { command, arguments in
            if command == "texpresso_start" {
                starts += 1
                #expect(arguments["session"] == nil)
                #expect(arguments["files"] as? [[String: String]] == [["path": "main.tex", "text": "latest"]])
            }
            return status(running: command != "texpresso_stop")
        }
        session.start(files: [TeXpressoFile(path: "old.tex", text: "old")])
        session.restart(files: [TeXpressoFile(path: "main.tex", text: "latest")])
        await session.waitForPendingCalls()
        #expect(starts == 1 && session.active)
        session.stop()
        await session.waitForPendingCalls()
    }
}
