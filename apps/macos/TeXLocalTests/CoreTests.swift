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
            try await Core.shared.call(DuplicateProject(id: "No such project", name: "Copy"))
        } throws: { error in
            (error as? CoreError)?.kind == .notFound
        }
    }

    @Test func aSessionsDocumentIsEditedAndSavedAndItsEventsDecode() async throws {
        let project = try await newProject()
        var events: [Event] = []
        let session = SessionClient { if case .event(let event) = $0 { events.append(event) } }
        let opened = try await session.call(OpenProject(id: project.id, autoCompile: false))
        #expect(opened.settings.mainFile == "main.tex")
        #expect(opened.tree.contains { $0.name == "main.tex" })
        try await session.call(OpenDocument(path: "main.tex"))
        try await waitUntil {
            events.contains { if case .outline = $0 { true } else { false } }
                && events.contains { if case .checks = $0 { true } else { false } }
        }
        let document = try #require(SourceDocument(session: session.id, path: "main.tex"))
        _ = document.edit(NSRange(location: 0, length: 0), with: "% note\n", changing: nil, mirroring: false)
        #expect(try await session.call(Save(reporting: true)))
        let text = try String(contentsOfFile: project.path + "/main.tex", encoding: .utf8)
        #expect(text.hasPrefix("% note\n"))
        #expect(try await session.close())
    }

    @Test func aReplyComesAfterTheEventsBeforeIt() async throws {
        let project = try await newProject(template: .blank)
        var trees = 0
        let session = SessionClient { if case .event(.tree) = $0 { trees += 1 } }
        try await session.call(OpenProject(id: project.id, autoCompile: false))
        try await session.call(CreateEntry(folder: "", name: "new.tex", dir: false))
        #expect(trees > 0)
        #expect(try await session.close())
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
}
