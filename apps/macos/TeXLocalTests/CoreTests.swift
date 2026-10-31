import AppKit
import Testing
@testable import TeXLocal

@Suite(.serialized)
struct CoreTests {
    @Test func theLibraryIsTheTestOne() throws {
        let data = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        #expect(Core.libraryFolder == URL(filePath: data, directoryHint: .isDirectory))
        #expect(Core.shared.isOpen)
    }

    @Test func aCommandAnswersDecodedValuesAfterTheLibraryItChanged() async throws {
        let project = try await newProject()
        #expect(project.mainFile == "main.tex")
        #expect(Core.shared.library.projects.contains { $0.id == project.id })
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
        let session = SessionClient(core: .shared) { events.append($0) }
        try await session.call(OpenProject(id: project.id, autoCompile: false))
        #expect(try await session.call(Open(path: "main.tex")) == "main.tex")
        try await waitUntil { events.contains { if case .section(.outline(_?)) = $0 { true } else { false } } }
        let document = try #require(SourceDocument(session: session, path: "main.tex"))
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
        let window = defaults.window()
        window.app.autoCompile = false
        let project = ProjectModel(id: info.id, window: window)
        let views = WorkspaceViews(project: project), editor = views.editor
        try await project.load()
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
        let undo = editor.textView.undo
        await project.renameEntry("main.tex", to: "thesis.tex")
        await project.renameEntry("untitled.tex", to: "notes.tex")
        #expect(editor.path == "notes.tex" && editor.textView.undo === undo && Array(editor.kept.keys) == ["thesis.tex"])
        #expect(await project.close().value)
        try await waitUntil { !views.editor.textView.isEditable }
    }

    @Test func theEditorAppliesEditsOnlyToTheVersionOfTheFileItShows() async throws {
        let info = try await newProject(template: .blank)
        let defaults = TestDefaults()
        let window = defaults.window()
        window.app.autoCompile = false
        let project = ProjectModel(id: info.id, window: window)
        let views = WorkspaceViews(project: project), text = views.editor.textView
        try await project.load()
        let stale = try #require(text.document.version)
        text.insertText("% mine\n", replacementRange: NSRange(location: 0, length: 0))
        let (shown, version) = (text.string, try #require(text.document.version))
        let edits = { (path: String, version: UInt64) in
            DocumentEdits(path: path, version: version, edits: [TextEdit(start: 0, length: 7, text: "% theirs\n")])
        }
        #expect(version != stale && !views.apply(edits("main.tex", stale), named: "Restore"))
        #expect(!views.apply(edits("other.tex", version), named: "Restore"))
        #expect(text.string == shown && text.document.version == version)
        #expect(views.apply(edits("main.tex", version), named: "Restore"))
        #expect(text.string.hasPrefix("% theirs\n"))
        #expect(await project.close().value)
    }

    @Test func settingsArePlainWritesAndACorruptSettingsFileIsReportedAtOpen() async throws {
        let info = try await newProject(template: .blank)
        let defaults = TestDefaults()
        let window = defaults.window()
        window.app.autoCompile = false
        let project = ProjectModel(id: info.id, window: window)
        try await project.load()
        project.engine = .xelatex
        try await waitUntil { project.engine == .xelatex }
        #expect(await project.close().value)
        #expect(window.alert == nil)
        let settings = info.path + "/.texlocal.json"
        try "{ not json".write(toFile: settings, atomically: true, encoding: .utf8)
        let corrupt = ProjectModel(id: info.id, window: window)
        try await corrupt.load()
        #expect(window.alert?.title == "Couldn’t Read the Project’s Settings")
        #expect(corrupt.engine == .pdflatex)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == "{ not json")
        #expect(await corrupt.close().value)
    }

    @Test func theStoreIsFilledBeforeTheOpenReplyAndEachReplyFollowsItsSections() async throws {
        let project = try await newProject(template: .blank)
        let store = SessionStore()
        let session = SessionClient(core: .shared) { if case .section(let section) = $0 { store.apply(section) } }
        try await session.call(OpenProject(id: project.id, autoCompile: false))
        #expect(store.project?.name == project.name)
        #expect(store.project?.settings.mainFile == "main.tex")
        #expect(store.tree.contains { $0.name == "main.tex" && $0.main })
        #expect(store.build?.result == nil && store.shownPdf?.path == nil && store.live?.phase == .stopped)
        try await session.call(CreateEntry(folder: "", name: "new.tex", dir: false))
        #expect(store.tree.contains { $0.name == "new.tex" })
        #expect(try await session.close())
    }

    @Test func aClosedSessionRefusesCallsDropsALateReplyAndCancelsItsTasks() async throws {
        let project = try await newProject(template: .blank)
        let session = SessionClient(core: .shared)
        try await session.call(OpenProject(id: project.id, autoCompile: false))
        var cancelled = false
        session.task {
            try? await Task.sleep(for: .seconds(10))
            cancelled = Task.isCancelled
        }
        let late = Task.immediate { try await session.call(Save(reporting: true)) }
        session.discard()
        await #expect(throws: CancellationError.self) { try await late.value }
        await #expect(throws: CancellationError.self) { try await session.call(Save(reporting: true)) }
        try await waitUntil { cancelled }
        #expect(session.closed && session.source("main.tex") == nil)
        #expect(try await session.close())
    }

    @Test func aSessionTheCoreNeverOpenedClosesAtOnce() async throws {
        let session = SessionClient(core: .shared)
        #expect(try await session.close() && session.closed)
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
