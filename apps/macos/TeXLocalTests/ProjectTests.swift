import AppKit
import os
import PDFKit
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

@Suite(.serialized, .timeLimit(.minutes(2)))
final class ProjectFlowTests {
    private let keys = [DefaultsKey.autoCompile, DefaultsKey.recentProjects]
    private let kept: [Any?]
    private var folders: [URL] = []
    private let files = FileManager.default
    let app = AppModel()

    init() throws {
        // Removed rather than trashed, as `CoreTests` explains: only in the test library.
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        kept = keys.map { UserDefaults.standard.object(forKey: $0) }
        app.autoCompile = false
    }

    isolated deinit {
        app.project?.close()
        for (key, value) in zip(keys, kept) { UserDefaults.standard.set(value, forKey: key) }
        for folder in folders { try? files.removeItem(at: folder) }
    }

    private func project(_ text: String = "text") async throws -> (info: ProjectInfo, folder: URL) {
        let info = try await Core.shared.call("create_project", ["name": "Test \(UUID().uuidString.prefix(8))", "template": "blank"],
                                              as: ProjectInfo.self)
        let folder = Core.libraryFolder.appending(path: info.id)
        folders.append(folder)
        try await Core.shared.call("write_file", ["id": info.id, "path": info.mainFile, "text": text])
        return (info, folder)
    }

    private func opened(_ text: String = "text") async throws -> (project: ProjectModel, folder: URL) {
        let (info, folder) = try await project(text)
        await app.open(info.id)
        return (try #require(app.project), folder)
    }

    private func openedWithTeX(_ text: String) async throws -> ProjectModel {
        await app.refreshTeXStatus()
        if app.tex?.available != true { try Test.cancel("No TeX") }
        return try await opened(text).project
    }

    private func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path(percentEncoded: false)) }

    /// The session builds on a thread of its own, and says when it's done.
    private func built(_ project: ProjectModel, auto: Bool = false) async throws {
        let before = project.finishedBuilds
        await project.compile(auto: auto)
        try await waitUntil(timeout: .seconds(60)) { project.finishedBuilds > before && !project.compiling }
    }

    @Test func theMainFileOnDiskStaysOutOfTheTrash() async throws {
        let (project, folder) = try await opened()
        try await Core.shared.call("write_file", ["id": project.id, "path": "second.tex", "text": "x"])
        let settings = folder.appending(path: ".texlocal.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        json["mainFile"] = "second.tex"
        try JSONSerialization.data(withJSONObject: json).write(to: settings)
        await project.deleteEntry("second.tex")
        #expect(files.fileExists(atPath: folder.appending(path: "second.tex").path))
        #expect(project.settings?.mainFile == "second.tex")
    }

    @Test func theLastOpenHasTheEditor() async throws {
        let first = try await project("first").info, second = try await project("second").info
        // Started in this order on the main actor, each waiting on the core in turn.
        let opens = [Task { await app.open(first.id) }, Task { await app.open(second.id) }]
        for open in opens { await open.value }

        #expect(app.project?.id == second.id)
        let document = app.project?.editor.document
        #expect(document?.path == second.mainFile)
        #expect(document?.text == "second")
        await app.close()
    }

    /// Overlapping requests settle at the new path; the scheduler chooses their core interleaving.
    @Test func overlappingRenameAndSaveRequestsKeepEditsAtTheNewPath() async throws {
        let (project, folder) = try await opened("original")
        for to in ["chapter.tex", "references.bib", "main.tex"] {
            let from = try #require(project.openPath)
            let rename = Task { await project.renameEntry(from, to: to) }
            await Task.yield()
            #expect(project.editor.perform(.bold))
            let expected = project.editor.textView.string
            let save = Task { await project.save() }
            await rename.value
            #expect(await save.value)

            #expect(project.openPath == to && project.editor.document?.path == to)
            #expect(project.editor.document?.text == expected)
            #expect(try String(contentsOf: folder.appending(path: to), encoding: .utf8) == expected)
            #expect(!exists(folder.appending(path: from)))
            #expect(project.diskConflict == nil && project.missingFile == nil)
        }
        #expect(app.alert == nil)
        await app.close()
    }

    @Test func aFileRenameCanBeUndoneAndRedone() async throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoSource = { undo }
        let (project, folder) = try await opened()
        #expect(project.settings?.mainFile == "main.tex")

        undo.beginUndoGrouping()
        await project.renameEntry("main.tex", to: "thesis.tex")
        undo.endUndoGrouping()
        #expect(exists(folder.appending(path: "thesis.tex")) && project.settings?.mainFile == "thesis.tex")
        #expect(undo.undoActionName == "Rename")

        undo.undo()
        try await waitUntil { self.exists(folder.appending(path: "main.tex")) && project.settings?.mainFile == "main.tex" }
        #expect(!exists(folder.appending(path: "thesis.tex")) && undo.canRedo)

        undo.redo()
        try await waitUntil { self.exists(folder.appending(path: "thesis.tex")) && project.settings?.mainFile == "thesis.tex" }
        #expect(app.alert == nil)
        await app.close()
    }

    @Test func theExportedZipHasTheUnsavedEdits() async throws {
        let (project, _) = try await opened("original")
        #expect(project.editor.perform(.bold))
        let expected = project.editor.textView.string
        let zip = try await project.exportZip()
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-p", zip.path(percentEncoded: false), try #require(project.openPath)]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == expected)
        // The archive is the save panel's to copy: the next export removes it, and closing the last.
        let next = try await project.exportZip()
        #expect(!exists(zip) && exists(next))
        await app.close()
        #expect(!exists(next.deletingLastPathComponent()))
    }

    /// CI has no TeX.
    @Test func onlyCompileMovesThePanel() async throws {
        let project = try await openedWithTeX("\\documentclass{article}\\begin{document}\\undefinedmacro x\\end{document}")
        try await built(project, auto: true)
        #expect(project.result?.failed == true && project.result?.pdf != nil && !project.panel.shown)
        try await built(project)
        #expect(project.panel.shown && project.panel.tab == .issues)
        let text = project.editor.textView
        text.insertText("", replacementRange: (text.string as NSString).range(of: "\\undefinedmacro"))
        try await built(project, auto: true)
        #expect(project.result?.ok == true && project.panel.shown)
        try await built(project)
        #expect(project.result?.ok == true && !project.panel.shown)
        await app.close()
    }

    @Test func aSyncTeXMissIsNoAlert() async throws {
        let (project, _) = try await opened()
        await project.forwardSync()
        #expect(project.notices.current == "No compiled PDF yet" && app.alert == nil)
        await app.close()
    }

    @Test func aNoticeGoesByItself() async throws {
        let notices = ProjectNotices(lasting: .milliseconds(100))
        notices.note("One")
        notices.note("Two")
        #expect(notices.current == "Two")
        try await waitUntil { notices.current == nil }
    }

    @Test func aProjectThatCannotLoadStaysClosed() async throws {
        await app.open("No Such Project \(UUID().uuidString.prefix(8))")
        #expect(app.project == nil && app.alert != nil && !app.isOpening)
    }

    @Test func aProjectOpensOnItsBuiltPDF() async throws {
        let (info, folder) = try await project()
        try files.createDirectory(at: folder.appending(path: "build"), withIntermediateDirectories: true)
        #expect(try textPDF(["one", "two", "three"]).write(to: folder.appending(path: "build/main.pdf")))
        let saved = SavedWorkspace(project: info.id, file: nil, line: 1, buildPanel: true, pdfPage: 2, pdfZoom: nil)
        await app.open(info.id, restoring: saved)
        let project = try #require(app.project)
        #expect(project.initialLoadComplete && project.openPath == info.mainFile && project.panel.shown)
        #expect(project.hasPDF && project.pdf.view.document?.pageCount == 3)
        await app.close()
    }

    @Test func aRefusalOnHomeIsAnAlertThatNamesIt() async throws {
        let missing = files.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        await app.importProject(from: missing)
        #expect(app.alert?.title == "Couldn’t Open “\(missing.lastPathComponent)”" && app.project == nil && !app.isOpening)
        let recents = app.recentProjects
        let gone = ProjectInfo(id: "No Such Project \(UUID().uuidString.prefix(8))", name: "Gone", mtime: 0, mainFile: "main.tex")
        await app.rename(gone, to: "Elsewhere")
        #expect(app.alert?.title == "Couldn’t Rename “Gone”" && app.recentProjects == recents)
    }

    @Test func aLibraryFileOpensItsOwnProject() async throws {
        let (info, folder) = try await project()
        try "notes".write(to: folder.appending(path: "notes.tex"), atomically: false, encoding: .utf8)
        await app.refresh()
        let count = app.projects.count
        await app.importProject(from: folder.appending(path: "notes.tex"))
        #expect(app.project?.id == info.id && app.project?.openPath == "notes.tex")
        #expect(app.projects.count == count && app.alert == nil)
        await app.close()
    }

    /// A TeXpresso stand-in that writes a one-page PDF where it's asked to, as Underleaf's patched build does, and reads edits until it's stopped.
    private func liveTeXpresso() throws -> URL {
        let folder = files.temporaryDirectory.appending(path: "texpresso-\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        page.string = "live"
        let pdf = folder.appending(path: "live.pdf")
        try page.dataWithPDF(inside: page.bounds).write(to: pdf)
        let script = folder.appending(path: "texpresso")
        try """
        #!/bin/sh
        cp '\(pdf.path)' "$TEXPRESSO_PDF_OUTPUT"
        printf '["pdf","%s",1]\\n' "$TEXPRESSO_PDF_OUTPUT"
        exec cat > /dev/null
        """.write(to: script, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func livePagesAreNeverTakenForABuilds() async throws {
        setenv("TEXLOCAL_TEXPRESSO", try liveTeXpresso().path, 1)
        defer { unsetenv("TEXLOCAL_TEXPRESSO") }
        let project = try await opened("\\documentclass{article}\\begin{document}x\\end{document}").project
        project.startTeXpresso()
        try await waitUntil(timeout: .seconds(10)) { project.livePDF && project.pdf.pageCount == 1 } state: {
            "phase \(project.texpresso.phase), log \(project.texpresso.log)"
        }
        #expect(project.editor.textView.forwardSync(false) != nil)
        await project.forwardSync()
        #expect(project.notices.current?.contains("TeXpresso") == true, "Notice: \(String(describing: project.notices.current))")
        project.stopTeXpresso()
        try await waitUntil(timeout: .seconds(10)) { !project.livePDF }
        #expect(!project.hasPDF && project.pdf.view.document == nil && project.pdf.pageCount == 0)
        await app.close()
    }

    @Test func aNoOpBuildKeepsThePDFDocumentAndThePanel() async throws {
        let project = try await openedWithTeX("\\documentclass{article}\\begin{document}x\\end{document}")
        (project.panel.shown, project.panel.tab) = (true, .log)
        try await built(project)
        #expect(project.result?.ok == true && project.result?.pdfChanged == true && project.panel.shown)
        let shown = project.pdf.shownVersion
        project.panel.tab = .issues
        try await built(project)
        #expect(project.result?.ok == true && project.result?.pdfChanged == false)
        #expect(project.pdf.shownVersion == shown)
        #expect(project.panel.shown)
        await app.close()
    }

    @Test func aCleanBuildClosesOnlyThePanelAFailureOpened() {
        let panel = BuildPanelModel()
        panel.openForFailedBuild()
        #expect(panel.shown && panel.tab == .issues)
        panel.tab = .log
        panel.closeAfterCleanBuild()
        #expect(panel.shown)
        panel.tab = .issues
        panel.closeAfterCleanBuild()
        #expect(!panel.shown)
        panel.show(.log)
        panel.openForFailedBuild()
        panel.closeAfterCleanBuild()
        #expect(panel.shown && panel.tab == .issues)
        panel.shown = false
        panel.openForFailedBuild()
        panel.shown = false
        panel.show(.texpresso)
        #expect(panel.showsLiveLog)
        panel.tab = .issues
        #expect(!panel.showsLiveLog)
        panel.closeAfterCleanBuild()
        #expect(panel.shown)
        panel.tab = .texpresso
        panel.shown = false
        #expect(!panel.showsLiveLog)
    }

    @Test func theOutlineFollowsTheTopHeadingOnly() async throws {
        let project = try await opened("\\section{A}\n1\n2\n\\section{B}\n3").project
        try await waitUntil { project.outline.count == 2 }
        let scrolled = { (line: Int) in
            project.editor.onScroll(line)
            await project.findingHeadings?.value
        }
        await scrolled(2)
        let told = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = project.currentHeading } onChange: { told.withLock { $0 = true } }
        await scrolled(3)
        #expect(!told.withLock { $0 } && project.topLine == 3)
        await scrolled(4)
        #expect(told.withLock { $0 } && project.currentHeading == project.outline[1].id && project.topHeading == project.outline[1].id)
        await app.close()
    }

    @Test func theOutlineReadsTheInputs() async throws {
        let (info, folder) = try await project("\\section{Intro}\nOne two\n\\include{chapters/a}")
        try files.createDirectory(at: folder.appending(path: "chapters"), withIntermediateDirectories: false)
        try "\\section{A}\nthree".write(to: folder.appending(path: "chapters/a.tex"), atomically: false, encoding: .utf8)
        await app.open(info.id)
        let project = try #require(app.project)
        #expect(project.initialLoadComplete)
        #expect(project.outline.count == 2)
        #expect(project.outline.map(\.file) == ["main.tex", "chapters/a.tex"])
        #expect(project.words == 6)
        project.reveal(project.outline[1])
        try await waitUntil { project.openPath == "chapters/a.tex" }
        #expect(project.headingCommand == "section")
        await app.close()
    }

    /// The levels are those of the class the main file names outside comments, at its type size, whichever file shows.
    @Test func theLevelsAreTheMainFilesClasses() async throws {
        let (info, folder) = try await project("% \\documentclass{article}\n\\documentclass[11pt]{report}\n\\include{a}")
        try "\\section{A}\nthree".write(to: folder.appending(path: "a.tex"), atomically: false, encoding: .utf8)
        await app.open(info.id)
        let project = try #require(app.project)
        let reports = { project.headingStyles.contains { $0.command == "chapter" } }
        try await waitUntil(reports)
        project.reveal(project.outline[0])
        try await waitUntil { project.openPath == "a.tex" }
        #expect(reports() && project.headingStyles.first { $0.command == "section" }?.font.scale == 14.4 / 10.95)
        await app.close()
    }

    @Test func anotherAppsFilesComeAndGo() async throws {
        let (project, folder) = try await opened()
        let paths = { Set(project.tree.nodes.flattened.map(\.path)) }

        try "x".write(to: folder.appending(path: "notes.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { paths().contains("notes.tex") }
        try files.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: false)
        try files.moveItem(at: folder.appending(path: "notes.tex"), to: folder.appending(path: "parts/notes.tex"))
        try await waitUntil(timeout: .seconds(5)) { paths().contains("parts/notes.tex") && !paths().contains("notes.tex") }
        // Only the spelling changes, which a volume that ignores case finds under either.
        try files.moveItem(at: folder.appending(path: "parts/notes.tex"), to: folder.appending(path: "parts/Notes.tex"))
        try await waitUntil(timeout: .seconds(5)) { paths().contains("parts/Notes.tex") && !paths().contains("parts/notes.tex") }
        try files.removeItem(at: folder.appending(path: "parts"))
        try await waitUntil(timeout: .seconds(5)) { !paths().contains("parts") }
        await app.close()
    }

    /// The session's watcher, reload and conflict reach the editor; the rules are the core's (session/tests.rs).
    @Test func anotherAppsChangeReachesTheEditor() async throws {
        let (project, folder) = try await opened("original")
        let main = folder.appending(path: "main.tex"), text = project.editor.textView
        let onDisk = { try? String(contentsOf: main, encoding: .utf8) }

        try "theirs".write(to: main, atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { text.string == "theirs" }
        // Shown without an edit, and taken: the next edit is saved over it.
        #expect(project.editor.perform(.bold))
        #expect(await project.save() && onDisk() == text.string)

        try "theirs again".write(to: main, atomically: false, encoding: .utf8)
        #expect(project.editor.perform(.italic))
        try await waitUntil(timeout: .seconds(5)) { project.diskConflict == "main.tex" }
        project.revertToDisk("main.tex")
        try await waitUntil(timeout: .seconds(5)) { text.string == "theirs again" }
        #expect(project.diskConflict == nil && onDisk() == "theirs again" && app.alert == nil)
        await app.close()
    }

    @Test func aClosedProjectsTrashCannotBeUndone() async throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoSource = { undo }
        let (project, folder) = try await opened()
        let notes = folder.appending(path: "notes.tex")
        try "notes".write(to: notes, atomically: false, encoding: .utf8)

        undo.beginUndoGrouping()
        await project.deleteEntry("notes.tex")
        undo.endUndoGrouping()
        #expect(!exists(notes) && undo.undoActionName == "Move to Trash")
        // Back from the Trash, which is left as it was; the Redo is the item's too.
        undo.undo()
        try await waitUntil { self.exists(notes) }
        #expect(undo.canRedo)
        await app.close()
        #expect(!undo.canRedo && !undo.canUndo)
    }

    @Test func aRenameOnHomeCannotBeUndoneUnderAProject() async throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoSource = { undo }
        let info = try await project().info
        let renamed = "Renamed \(UUID().uuidString.prefix(8))"
        folders.append(Core.libraryFolder.appending(path: renamed))

        undo.beginUndoGrouping()
        await app.rename(info, to: renamed)
        undo.endUndoGrouping()
        #expect(undo.canUndo && undo.undoActionName == "Rename")
        await app.open(renamed)
        #expect(app.project?.id == renamed && !undo.canUndo)
        await app.close()
    }

    @Test func aDroppedFileOpens() async throws {
        let (project, folder) = try await opened()
        let notes = folder.appending(path: "notes.tex")
        try "notes".write(to: notes, atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { project.tree.nodes.flattened.contains { $0.path == "notes.tex" } }
        let drop = project.editor.textView.fileDrop

        let plot = folder.appending(path: "plot.png")
        try Data().write(to: plot)
        try await waitUntil(timeout: .seconds(5)) { project.tree.nodes.flattened.contains { $0.path == "plot.png" } }
        guard case .insert("\\includegraphics{plot.png}") = drop(plot) else {
            Issue.record("An image dropped on LaTeX is a figure")
            return
        }
        guard case .open(let openNotes) = drop(notes) else {
            Issue.record("A text file dropped on the source opens")
            return
        }
        openNotes()
        try await waitUntil(timeout: .seconds(5)) { project.openPath == "notes.tex" }
        #expect(drop(files.temporaryDirectory.appending(path: "outside.tex")) == nil)
        #expect(drop(files.temporaryDirectory.appending(path: "figure.png")) == nil)
        await app.close()
    }

    @Test func aSettingShowsAtOnceAndARefusedOneIsPutBack() async throws {
        let (project, _) = try await opened()
        let on = Task.immediate { await project.patchSettings(.shellEscape(true)) }
        #expect(project.settings?.shellEscape == true)
        #expect(await on.value)
        let refused = Task.immediate { await project.patchSettings(.engine("nonsense")) }
        #expect(project.settings?.engine == "nonsense")
        #expect(await refused.value == false)
        #expect(project.settings?.engine == "pdflatex" && project.settings?.shellEscape == true)
        app.alert = nil
    }

    @Test func cleanBuildFolderRemovesTheBuildFolder() async throws {
        let (project, folder) = try await opened()
        try files.createDirectory(at: folder.appending(path: "build"), withIntermediateDirectories: true)
        try "x".write(to: folder.appending(path: "build/main.aux"), atomically: false, encoding: .utf8)
        await project.cleanBuildFolder()
        #expect(!exists(folder.appending(path: "build")) && exists(folder.appending(path: "main.tex")))
        #expect(project.result == nil && !project.hasPDF)
        await app.close()
    }

    @Test func aSearchListsItsHitsByFile() async throws {
        let project = try await opened("needle\nhay\nNeedle").project
        try await Core.shared.call("write_file", ["id": project.id, "path": "appendix.tex", "text": "a needle"])
        project.search.query = "needle"
        await project.search.run()
        #expect(project.search.hitCount == 3 && project.search.failure == nil)
        #expect(project.search.groups?.map(\.file) == ["appendix.tex", "main.tex"] && project.search.groups?.map(\.hits.count) == [1, 2])
        project.search.query = "needles"
        #expect(project.search.searched == "needle")
        await project.search.run()
        #expect(project.search.groups?.isEmpty == true && project.search.searched == "needles")
        project.search.query = " "
        await project.search.run()
        #expect(project.search.groups == nil && project.search.failure == nil && project.search.hitCount == 0)
        await app.close()
    }

    @Test func theTreeTellsOfAChangeOnly() async throws {
        let info = try await project().info, tree = FileTree(id: info.id)
        var changes = 0
        tree.onChange = { changes += 1 }
        try await tree.read()
        #expect(changes == 1 && tree.node(at: info.mainFile)?.isDirectory == false)
        await tree.reload()
        #expect(changes == 1)
        try await Core.shared.call("write_file", ["id": info.id, "path": "notes.tex", "text": "x"])
        await tree.reload()
        #expect(changes == 2 && tree.node(at: "notes.tex") != nil)
        tree.close()
        try await Core.shared.call("write_file", ["id": info.id, "path": "more.tex", "text": "x"])
        await tree.reload()
        #expect(changes == 2 && tree.node(at: "more.tex") == nil)
    }

    @Test func theSidebarsStateIsKeptForTheProject() async throws {
        let project = try await opened().project
        project.expandedFolders = ["chapters", "chapters/appendix"]
        project.foldedHeadings = ["main.tex\t1:Methods#1"]
        await app.close()
        await app.open(project.id)
        let again = try #require(app.project)
        #expect(again !== project && again.expandedFolders == ["chapters", "chapters/appendix"])
        #expect(again.foldedHeadings == ["main.tex\t1:Methods#1"])
        await app.close()
    }

    /// The rename's answer has the state the core moved, written before the rename asked for it.
    @Test func anOpenFolderStaysOpenUnderItsNewName() async throws {
        let project = try await opened().project
        try await Core.shared.call("write_file", ["id": project.id, "path": "ch/a.tex", "text": ""])
        project.expandedFolders = ["ch"]
        await project.renameEntry("ch", to: "chapters")
        #expect(project.expandedFolders == ["chapters"])
        await app.close()
    }

    @Test func aNewProjectOpensItsSheetWithTheTemplateAndAFreeName() async throws {
        app.newProject(.report)
        // Once the core has named it.
        try await waitUntil { app.newProjectDraft != nil }
        #expect(app.newProjectDraft?.template == .report && app.newProjectDraft?.name.isEmpty == false)
        app.newProjectDraft = nil
    }

    @Test func theDockMenuOpensARecentProject() async throws {
        let first = try await project("first").info, second = try await project("second").info
        await app.refresh()
        var shown = 0
        let dock = DockMenu(app: app) { shown += 1 }
        app.recentProjects = []
        #expect(dock.menu.items.map(\.title) == ["New Project…"])
        app.recentProjects = [second.id, "Gone", first.id]
        let menu = dock.menu
        #expect(menu.items.map(\.title) == [second.name, first.name, "", "New Project…"])
        menu.performActionForItem(at: 3)
        // Once the core has named it.
        try await waitUntil { app.newProjectDraft != nil }
        #expect(shown == 1)
        app.newProjectDraft = nil
        menu.performActionForItem(at: 1)
        try await waitUntil(timeout: .seconds(5)) { app.project?.id == first.id && app.project?.initialLoadComplete == true }
        #expect(shown == 2 && app.recentProjects.first == first.id)
        #expect(NSApp.delegate?.responds(to: #selector((any NSApplicationDelegate).applicationDockMenu(_:))) == true)
        await app.close()
    }

    @Test func newItemsTakeTheNextFreeName() async throws {
        let (project, folder) = try await opened()
        try "x".write(to: folder.appending(path: "untitled.tex"), atomically: false, encoding: .utf8)
        #expect(await project.createEntry(in: "", directory: false) == "untitled 2.tex")
        #expect(project.openPath == "untitled 2.tex" && project.editor.document?.text == "")
        #expect(await project.createEntry(in: "", directory: true) == "untitled folder")
        #expect(await project.createEntry(in: "", directory: true) == "untitled folder 2")
        #expect(await project.createEntry(in: "untitled folder", directory: false) == "untitled folder/untitled.tex")
        #expect(project.tree.nodes.flattened.contains { $0.path == "untitled folder/untitled.tex" })
        #expect(exists(folder.appending(path: "untitled folder 2")) && exists(folder.appending(path: "untitled folder/untitled.tex")))
        #expect(app.alert == nil)
        await app.close()
    }

    @Test func treeDropsMoveTheProjectsFiles() async throws {
        let (project, folder) = try await opened()
        try files.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: false)
        try "notes".write(to: folder.appending(path: "notes.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { project.tree.nodes.flattened.contains { $0.path == "notes.tex" } }
        let url = { (path: String) in try #require(project.url(path)) }

        await project.dropFiles([try url("notes.tex")], into: "parts")
        #expect(exists(folder.appending(path: "parts/notes.tex")) && !exists(folder.appending(path: "notes.tex")))
        await project.dropFiles([try url("parts")], into: "parts")
        #expect(exists(folder.appending(path: "parts/notes.tex")))
        await project.dropFiles([try url("parts/notes.tex")], into: "")
        #expect(exists(folder.appending(path: "notes.tex")) && !exists(folder.appending(path: "parts/notes.tex")))

        let outside = files.temporaryDirectory.appending(path: "outside-\(UUID().uuidString.prefix(8)).tex")
        try "x".write(to: outside, atomically: false, encoding: .utf8)
        defer { try? files.removeItem(at: outside) }
        await project.dropFiles([outside], into: "parts")
        #expect(exists(folder.appending(path: "parts/\(outside.lastPathComponent)")) && exists(outside))
        await app.close()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct UndoableTrashTests {
    @Test func undoPutsATrashedItemBackAndRedoTrashesItAgain() async throws {
        let files = FileManager.default
        let url = files.temporaryDirectory.appending(path: "undo-\(UUID().uuidString.prefix(8)).tex")
        try "text".write(to: url, atomically: false, encoding: .utf8)
        let undo = UndoManager()
        undo.groupsByEvent = false
        var listed = 0
        // Not kept here: the undo manager's entries keep it, as in the app.
        var item: UndoableTrash? = UndoableTrash(original: url, name: url.lastPathComponent, undoManager: undo,
                                 trash: { item in (try? item.recycle()) != nil },
                                 changed: { listed += 1 }, failed: { title, _ in Issue.record("\(title)") })
        undo.beginUndoGrouping()
        await item?.moveToTrash()
        undo.endUndoGrouping()
        item = nil
        #expect(!files.fileExists(atPath: url.path) && undo.undoActionName == "Move to Trash")

        undo.undo()
        try await waitUntil { files.fileExists(atPath: url.path) && listed == 1 }
        #expect(try String(contentsOf: url, encoding: .utf8) == "text" && undo.canRedo && listed == 1)

        undo.redo()
        try await waitUntil { !files.fileExists(atPath: url.path) && listed == 2 }
        #expect(undo.canUndo)

        undo.undo()
        try await waitUntil { files.fileExists(atPath: url.path) }
        try files.removeItem(at: url)
    }

    /// An Undo asked while a Redo is still on its way to the Trash waits for it, rather than finding nothing to put back (#36).
    @Test func anUndoDuringARedoWaitsForIt() async throws {
        let files = FileManager.default
        let url = files.temporaryDirectory.appending(path: "undo-\(UUID().uuidString.prefix(8)).tex")
        try "text".write(to: url, atomically: false, encoding: .utf8)
        let undo = UndoManager()
        undo.groupsByEvent = false
        var listed = 0
        // Slow, as the project's lane can be behind a save.
        let item = UndoableTrash(original: url, name: url.lastPathComponent, undoManager: undo,
                                 trash: { item in try? await Task.sleep(for: .milliseconds(200)); return (try? item.recycle()) != nil },
                                 changed: { listed += 1 }, failed: { title, _ in Issue.record("\(title)") })
        undo.beginUndoGrouping()
        await item.moveToTrash()
        undo.endUndoGrouping()
        undo.undo()
        try await waitUntil { files.fileExists(atPath: url.path) && listed == 1 }

        undo.redo()
        undo.undo()
        try await waitUntil { listed == 3 }
        #expect(files.fileExists(atPath: url.path) && undo.canRedo && !undo.canUndo)
        try files.removeItem(at: url)
    }
}
