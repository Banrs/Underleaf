import Foundation
import Testing
@testable import TeXLocal

/// Projects are removed, not trashed: `delete_project` trashes through Finder, which a headless test host can't drive.
struct CoreTests {
    init() throws {
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
    }

    @Test func aCoreErrorIsDecodedAndAMisshapenAnswerIsSaidInTheAppsWords() async throws {
        let core = Core.shared
        let info = try await core.call("create_project", ["name": "Test \(UUID().uuidString.prefix(8))", "template": "blank"], as: ProjectInfo.self)
        defer { try? FileManager.default.removeItem(at: Core.libraryFolder.appending(path: info.id)) }
        let error = await #expect(throws: CoreError.self) {
            _ = try await core.call("read_file", ["id": info.id, "path": "../../x"], as: FileText.self)
        }
        #expect(error?.message == "Path escapes project")
        // An answer in another shape than was asked for is said in the app's words, without the command's name.
        let fault = await #expect(throws: CoreError.self) {
            _ = try await core.call("file_tree", ["id": info.id], as: FileText.self)
        }
        #expect(fault?.message.hasPrefix("Something went wrong inside TeXLocal.") == true && fault?.status == nil)
    }

    /// The app numbers its sessions, and their events reach the observer of the number, decoded.
    @Test func aSessionsEventsReachTheObserverOfItsNumber() async throws {
        let core = Core.shared
        let info = try await core.call("create_project", ["name": "Test \(UUID().uuidString.prefix(8))", "template": "blank"], as: ProjectInfo.self)
        defer { try? FileManager.default.removeItem(at: Core.libraryFolder.appending(path: info.id)) }
        var events: [SessionEvent] = []
        let session = core.observe { events.append($0) }
        defer { core.forget(session) }
        let opened = try await core.call("session_open", ["id": info.id, "session": session], as: SessionOpened.self)
        #expect(opened.settings.mainFile == info.mainFile && opened.pdf == nil)
        let taken = await #expect(throws: CoreError.self) {
            _ = try await core.call("session_open", ["id": info.id, "session": session], as: SessionOpened.self)
        }
        #expect(taken?.status == 409)
        try await core.call("session_open_document", ["session": session, "path": info.mainFile])
        _ = try await core.call("session_close_document", ["session": session, "path": info.mainFile], as: Closed.self)
        try await waitUntil {
            events.contains { if case .closed(let closed) = $0 { closed.path == info.mainFile && closed.reason == "closed" } else { false } }
        }
        try await core.call("session_close", ["session": session])
    }
}
