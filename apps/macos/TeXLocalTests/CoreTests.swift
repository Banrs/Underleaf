import AppKit
import Testing
@testable import TeXLocal

@Suite(.serialized)
struct CoreTests {
    @Test func theLibraryAndStateAreTheTestOnes() throws {
        let data = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        let state = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_STATE"])
        #expect(Core.libraryFolder == URL(filePath: data, directoryHint: .isDirectory))
        #expect(Core.stateFolder == URL(filePath: state, directoryHint: .isDirectory))
        #expect(Core.shared.isOpen)
    }

    @Test func aFailedOpenNamesTheFolderThatCantBeWritten() {
        let missing = URL(filePath: "/nonexistent/state", directoryHint: .isDirectory)
        #expect(Core.advice([Core.libraryFolder, missing]).contains("/nonexistent/state"))
        #expect(Core.advice().contains(Core.libraryPath))
    }

    @Test func aCommandAnswersDecodedValuesAfterTheLibraryItChanged() async throws {
        let project = try await newProject()
        #expect(project.mainFile == "main.tex")
        #expect(Core.shared.library.projects.contains { $0.id == project.id })
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
        try "theirs\n".write(toFile: info.path + "/main.tex", atomically: true, encoding: .utf8)
        try await waitUntil { editor.textView.string == "theirs\n" }
        #expect(editor.textView.undo.undoActionName == "Reload")
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
        text.isEditable = false
        #expect(!views.apply(edits("main.tex", version), named: "Restore"))
        text.isEditable = true
        #expect(views.apply(edits("main.tex", version), named: "Restore"))
        #expect(text.string.hasPrefix("% theirs\n"))
        #expect(await project.close().value)
    }

    @Test func anAcceptedEditSurvivesAnExternalReloadWithItsUndoAndAConflict() async throws {
        let info = try await newProject(template: .blank)
        let defaults = TestDefaults(), window = defaults.window()
        window.app.autoCompile = false
        let project = ProjectModel(id: info.id, window: window), views = WorkspaceViews(project: project)
        try await project.load()
        let text = views.editor.textView, before = text.string, undo = text.undo
        var reload: Event?
        project.session.heard = { event in
            if case .reload = event { reload = event } else { project.handle(event) }
        }
        let range = NSRange(location: 0, length: 0)
        undo.beginUndoGrouping()
        #expect(text.shouldChangeText(in: range, replacementString: "% accepted\n"))
        try "external\n".write(toFile: info.path + "/main.tex", atomically: true, encoding: .utf8)
        try await waitUntil { reload != nil }
        text.textStorage?.replaceCharacters(in: range, with: "% accepted\n")
        text.didChangeText()
        undo.endUndoGrouping()
        project.handle(try #require(reload))
        #expect(text.string == "% accepted\n" + before && text.undo === undo && undo.canUndo)
        #expect(await project.save() == false)
        #expect(try String(contentsOfFile: info.path + "/main.tex", encoding: .utf8) == "external\n")
        #expect(project.conflicts.first?.path == "main.tex")
        undo.undo()
        #expect(text.string == before)
        try await project.session.call(Resolve(path: "main.tex", answer: .save))
        #expect(try String(contentsOfFile: info.path + "/main.tex", encoding: .utf8) == before)
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

    @Test func aCallMadeWhileTheCloseWaitsOnABuildEndsQuietly() async throws {
        let project = try await newProject(template: .blank)
        let latexmk = "#!/bin/sh\n[ \"$1\" = -version ] || { : > started; exec sleep 30; }\n"
        FileManager.default.createFile(atPath: project.path + "/latexmk", contents: Data(latexmk.utf8), attributes: [.posixPermissions: 0o755])
        let session = SessionClient(core: .shared)
        try await session.call(OpenProject(id: project.id, autoCompile: false))
        try await Core.shared.call(SetTexDir(dir: project.path))
        try await session.call(Compile(auto: false))
        try await waitUntil { FileManager.default.fileExists(atPath: project.path + "/started") }
        try await Core.shared.call(SetTexDir(dir: nil))
        let closing = Task.immediate { try await session.close() }
        await #expect(throws: CancellationError.self) { try await session.call(Save(reporting: true)) }
        #expect(try await closing.value && session.closed)
    }

    @Test func theCoreLooksForTeXItselfAndAFolderChosenReachesTheLibraryBeforeItsReply() async throws {
        try await waitUntil { Core.shared.library.tex != nil }
        let project = try await newProject(template: .blank)
        let latexmk = "#!/bin/sh\necho 'Latexmk, John Collins, 4 Jan 2026. Version 4.86'\n"
        FileManager.default.createFile(atPath: project.path + "/latexmk", contents: Data(latexmk.utf8), attributes: [.posixPermissions: 0o755])
        let defaults = TestDefaults()
        let app = defaults.app()
        try await app.setTeXFolder(project.path, texpresso: false)
        #expect(app.tex?.available == true && app.tex?.latexmkVersion == "4.86" && app.tex?.texDir != nil)
        try await app.setTeXFolder(nil, texpresso: false)
        #expect(app.tex?.texDir == nil && !app.settingTeX)
    }

    @Test func anExportIsWrittenWhereItsURLSays() async throws {
        let info = try await newProject(template: .blank)
        let defaults = TestDefaults()
        let window = defaults.window()
        window.app.autoCompile = false
        let project = ProjectModel(id: info.id, window: window)
        try await project.load()
        let zip = try await project.exportZip()
        #expect(FileManager.default.fileExists(atPath: zip.path(percentEncoded: false)))
        #expect(await project.close().value)
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

    @Test func aReplyGoesToItsCallerByItsIdEvenWhenTheAppCantReadItsBody() throws {
        let unreadable = Data(#"{"type":"reply","value":{"id":9,"answer":{"type":"error","value":{"kind":"unheardOf"}}}}"#.utf8)
        guard case .reply(9) = try Core.heard(unreadable), case .said(.event) = try Core.heard(Data(wireSaid[2].utf8)) else {
            Issue.record("misrouted")
            return
        }
        #expect(throws: DecodingError.self) { try Core.heard(Data(#"{"type":"event","value":{"session":1}}"#.utf8)) }
    }

    @Test func theAppReadsEachKindOfThingTheCoreSays() throws {
        let said = try wireSaid.map { try JSONDecoder().decode(Said<String>.self, from: Data($0.utf8)) }
        guard case .reply(let ok) = said[0], case .reply(let refused) = said[1], case .event(let event) = said[2],
              case .event(let stopped) = said[3], case .library = said[4], case .library(.tex(let tex)) = said[5],
              case .log(let log) = said[6] else {
            Issue.record("\(said)")
            return
        }
        #expect(try ok.answer.get() == "main.tex")
        #expect { try refused.answer.get() } throws: { error in
            let error = error as? CoreError
            return error?.kind == .notFound && error?.message.id == .noSuchSession
        }
        #expect(event.event == .liveAlert && log.level == .fault)
        #expect(stopped.event == .section(.lifecycle(.stopped(Stopped(unsaved: ["main.tex"])))))
        #expect(tex.available && tex.latexmkVersion == "4.86" && tex.texDir == nil)
    }
}
