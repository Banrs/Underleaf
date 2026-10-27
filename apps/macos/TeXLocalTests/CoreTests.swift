import Foundation
import Testing
@testable import TeXLocal

@Suite(.serialized)
struct CoreTests {
    @Test func theLibraryIsTheTestOne() {
        #expect(Core.libraryFolder.path(percentEncoded: false).hasPrefix("/tmp/texlocal-xctest"))
        #expect(Core.shared.isOpen)
    }

    @Test func aCommandAnswersDecodedValues() async throws {
        let project = try await newProject()
        let listed = try await Core.shared.call(ListProjects())
        #expect(listed.contains { $0.id == project.id && $0.mainFile == "main.tex" })
    }

    @Test func aRefusalCarriesItsKind() async {
        await #expect {
            try await Core.shared.call(ReadTree(id: "No such project"))
        } throws: { error in
            (error as? CoreError)?.kind == .notFound
        }
        await #expect {
            try await Core.shared.call("no_such_command", [:])
        } throws: { error in
            (error as? CoreError)?.kind == .notFound
        }
    }

    @Test func aSessionsAnswerAndEventsDecode() async throws {
        let project = try await newProject()
        var events: [SessionEvent] = []
        let session = Core.shared.observe { events.append($0) }
        defer { Core.shared.forget(session) }
        let opened = try await Core.shared.call("session_open", ["id": project.id, "session": session], as: SessionOpened.self)
        #expect(opened.settings.mainFile == "main.tex")
        #expect(opened.tree.contains { $0.name == "main.tex" })
        try await Core.shared.call("session_open_document", ["session": session, "path": "main.tex"])
        try await waitUntil {
            events.contains { if case .outline = $0 { true } else { false } }
                && events.contains { if case .checks = $0 { true } else { false } }
        }
        let saved = try await Core.shared.call("session_close", ["session": session], as: Saved.self)
        #expect(saved.saved)
    }

    @Test func aSessionDocumentIsEditedAndSaved() async throws {
        let project = try await newProject(template: .blank)
        let session = Core.shared.observe { _ in }
        defer { Core.shared.forget(session) }
        try await Core.shared.call("session_open", ["id": project.id, "session": session])
        try await Core.shared.call("session_open_document", ["session": session, "path": "main.tex"])
        let document = try #require(SourceDocument(session: session, path: "main.tex"))
        _ = document.edit(NSRange(location: 0, length: 0), with: "% note\n", changing: nil, mirroring: false)
        let saved = try await Core.shared.call("session_save", ["session": session], as: Saved.self)
        #expect(saved.saved)
        let text = try String(contentsOfFile: project.path + "/main.tex", encoding: .utf8)
        #expect(text.hasPrefix("% note\n"))
        try await Core.shared.call("session_close", ["session": session])
    }

    @Test func aReplyComesAfterTheEventsBeforeIt() async throws {
        let project = try await newProject(template: .blank)
        var trees = 0
        let session = Core.shared.observe { if case .tree = $0 { trees += 1 } }
        defer { Core.shared.forget(session) }
        try await Core.shared.call("session_open", ["id": project.id, "session": session])
        try await Core.shared.call("session_create_entry", ["session": session, "name": "new.tex"])
        #expect(trees > 0)
        try await Core.shared.call("session_close", ["session": session])
    }

    @Test func theWireFixturesRoundTripAndItsRejectsAreRefused() throws {
        let object = { (data: Data) in try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? NSObject }
        for (type, json) in wireSamples {
            let sent = try JSONEncoder().encode(try JSONDecoder().decode(type, from: Data(json.utf8)))
            #expect(try object(sent) == object(Data(json.utf8)), "\(json)")
        }
        for (type, json) in wireRejects {
            #expect(throws: DecodingError.self, "\(json)") { try JSONDecoder().decode(type, from: Data(json.utf8)) }
        }
        #expect(FixtureUnit.highContrast.title == "High Contrast")
    }

    @Test func anEventOfAnUnknownTypeIsLeftOut() throws {
        let known = try JSONDecoder().decode(EventRead.self, from: Data(#"{"type":"files_changed","session":3,"paths":["a.png"]}"#.utf8))
        #expect(known.session == 3)
        guard case .filesChanged(let changed) = known.event else { Issue.record("not decoded"); return }
        #expect(changed.paths == ["a.png"])
        let unknown = try JSONDecoder().decode(EventRead.self, from: Data(#"{"type":"something_new","session":3}"#.utf8))
        #expect(unknown.event == nil)
    }
}
