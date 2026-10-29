import AppKit
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
        let session = SessionClient { events.append($0) }
        try await session.call(OpenProject(id: project.id, autoCompile: false))
        #expect(try await session.call(Open(path: "main.tex")) == "main.tex")
        try await waitUntil { events.contains { if case .section(.outline(_?)) = $0 { true } else { false } } }
        let document = try #require(SourceDocument(session: session.id, path: "main.tex"))
        let version = try #require(document.version)
        _ = document.edit(NSRange(location: 0, length: 0), with: "% note\n", changing: nil, mirroring: false)
        #expect(document.version == version + 1)
        #expect(try await session.call(Save(reporting: true)))
        let text = try String(contentsOfFile: project.path + "/main.tex", encoding: .utf8)
        #expect(text.hasPrefix("% note\n"))
        #expect(try await session.close())
    }

    @Test func theEditorFollowsTheOpenFileAndItsReloadsAndAClosedDocumentRefusesEdits() async throws {
        let info = try await newProject()
        let defaults = TestDefaults()
        let app = AppModel(defaults: defaults.store)
        app.autoCompile = false
        let project = ProjectModel(id: info.id, app: app)
        await project.load()
        let editor = project.editor
        #expect(project.openPath == "main.tex" && editor.path == "main.tex")
        try await Task.sleep(for: .milliseconds(300))
        try "theirs\n".write(toFile: info.path + "/main.tex", atomically: true, encoding: .utf8)
        try await waitUntil { editor.textView.string == "theirs\n" }
        let main = editor.textView.document
        #expect(main.editable)
        #expect(await project.createEntry(in: "", directory: false) == "untitled.tex")
        #expect(project.openPath == "untitled.tex" && editor.path == "untitled.tex")
        #expect(!main.editable)
        let view = SourceTextView.plainDocument()
        view.load(main)
        view.insertText("late ", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.string == "theirs\n")
        #expect(await project.close().value)
    }

    @Test func theStoreIsFilledBeforeTheOpenReplyAndEachReplyFollowsItsSections() async throws {
        let project = try await newProject(template: .blank)
        let store = SessionStore()
        let session = SessionClient { if case .section(let section) = $0 { store.apply(section) } }
        try await session.call(OpenProject(id: project.id, autoCompile: false))
        #expect(store.project?.name == project.name)
        #expect(store.project?.settings.mainFile == "main.tex")
        #expect(store.tree.contains { $0.name == "main.tex" && $0.main })
        #expect(store.build?.result == nil && store.shownPdf?.path == nil && store.live?.phase == .stopped)
        try await session.call(CreateEntry(folder: "", name: "new.tex", dir: false))
        #expect(store.tree.contains { $0.name == "new.tex" })
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
