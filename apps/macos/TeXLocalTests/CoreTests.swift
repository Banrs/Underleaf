import Foundation
import Testing
@testable import TeXLocal

/// Projects are removed, not trashed: `delete_project` trashes through Finder, which a headless test host can't drive.
struct CoreTests {
    init() throws {
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
    }

    @Test func aCoreErrorIsDecodedAndAMisshapenAnswerIsSaidInTheAppsWords() async throws {
        let core = Core.shared, info = try await newProject()
        defer { try? FileManager.default.removeItem(at: info.folder) }
        let error = await #expect(throws: CoreError.self) {
            _ = try await core.call("create_entry", ["id": info.id, "path": "../../x"], as: FileText.self)
        }
        #expect(error?.message == "Path escapes project")
        let fault = await #expect(throws: CoreError.self) {
            _ = try await core.call("file_tree", ["id": info.id], as: FileText.self)
        }
        #expect(fault?.message.hasPrefix("Something went wrong inside TeXLocal.") == true && fault?.status == nil)
        // Arguments JSON can't hold are the same fault, not an exception.
        let unsent = await #expect(throws: CoreError.self) { try await core.call("file_tree", ["id": info.id, "n": Double.nan]) }
        #expect(unsent?.message == fault?.message)
    }

    @Test func aSessionsEventsReachTheObserverOfItsNumber() async throws {
        let core = Core.shared, info = try await newProject()
        defer { try? FileManager.default.removeItem(at: info.folder) }
        var events: [SessionEvent] = []
        let session = core.observe { events.append($0) }
        defer { core.forget(session) }
        let opened = try await core.call("session_open", ["id": info.id, "session": session], as: SessionOpened.self)
        #expect(opened.settings.mainFile == info.mainFile)
        try await core.call("session_open_document", ["session": session, "path": info.mainFile])
        _ = try await core.call("session_close_document", ["session": session, "path": info.mainFile], as: Closed.self)
        try await waitUntil {
            events.contains { if case .closed(let closed) = $0 { closed.path == info.mainFile && closed.reason == "closed" } else { false } }
        }
        try await core.call("session_close", ["session": session])
    }
}

private nonisolated struct FileText: Decodable { let text: String }
