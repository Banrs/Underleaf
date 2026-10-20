import AppKit
import os
import PDFKit
import Testing
@testable import TeXLocal

private extension SourceTextView.FileDrop {
    var inserted: String? { if case .insert(let text) = self { text } else { nil } }
    var opens: (() -> Void)? { if case .open(let open) = self { open } else { nil } }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
final class ProjectFlowTests {
    private let keys = [DefaultsKey.autoCompile, DefaultsKey.recentProjects]
    private let kept: [Any?]
    private var folders: [URL] = []
    let files = FileManager.default
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

    func project(_ text: String = "text") async throws -> (info: ProjectInfo, folder: URL) {
        let info = try await newProject()
        folders.append(info.folder)
        try info.write(text, to: info.mainFile)
        return (info, info.folder)
    }

    /// Opened with its main file's `text` and the `others` written beside it.
    private func opened(_ text: String = "text", with others: [String: String] = [:]) async throws -> (project: ProjectModel, folder: URL) {
        let (info, folder) = try await project(text)
        for (path, other) in others { try info.write(other, to: path) }
        await app.open(info.id)
        return (try #require(app.project), folder)
    }

    private func openedWithTeX(_ text: String) async throws -> ProjectModel {
        await app.refreshTeXStatus()
        if app.tex?.available != true { try Test.cancel("No TeX") }
        return try await opened(text).project
    }

    private func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path(percentEncoded: false)) }

    /// The window's, which groups only where a test says.
    private func windowUndo() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoSource = { undo }
        return undo
    }

    /// The session builds on a thread of its own, and says when it's done.
    private func built(_ project: ProjectModel, auto: Bool = false) async throws {
        let before = project.finishedBuilds
        await project.compile(auto: auto)
        try await waitUntil(timeout: .seconds(60)) { project.finishedBuilds > before && !project.compiling }
    }

    @Test func theMainFileOnDiskStaysOutOfTheTrash() async throws {
        let (project, folder) = try await opened(with: ["second.tex": "x"])
        let settings = folder.appending(path: ".texlocal.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        json["mainFile"] = "second.tex"
        try JSONSerialization.data(withJSONObject: json).write(to: settings)
        await project.deleteEntry("second.tex")
        #expect(exists(folder.appending(path: "second.tex")) && project.settings?.mainFile == "second.tex")
    }

    @Test func theLastOpenHasTheEditor() async throws {
        let first = try await project("first").info, second = try await project("second").info
        // Started in this order on the main actor, each waiting on the core in turn.
        let opens = [Task { await app.open(first.id) }, Task { await app.open(second.id) }]
        for open in opens { await open.value }
        let editor = try #require(app.project?.editor)
        #expect(app.project?.id == second.id && editor.path == second.mainFile && editor.textView.document.text == "second")
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

            #expect(project.openPath == to && project.editor.path == to)
            #expect(project.editor.textView.document.text == expected)
            #expect(try String(contentsOf: folder.appending(path: to), encoding: .utf8) == expected)
            #expect(!exists(folder.appending(path: from)) && project.diskConflict == nil && project.missingFile == nil)
        }
        #expect(app.alert == nil)
        await app.close()
    }

    @Test func aFileRenameCanBeUndoneAndRedoneUntilTheProjectCloses() async throws {
        let undo = windowUndo(), (project, folder) = try await opened()
        await undo.grouping { await project.renameEntry("main.tex", to: "thesis.tex") }
        #expect(exists(folder.appending(path: "thesis.tex")) && project.settings?.mainFile == "thesis.tex")
        #expect(undo.undoActionName == "Rename")

        undo.undo()
        try await waitUntil { self.exists(folder.appending(path: "main.tex")) && project.settings?.mainFile == "main.tex" }
        #expect(!exists(folder.appending(path: "thesis.tex")) && undo.canRedo)

        undo.redo()
        try await waitUntil { self.exists(folder.appending(path: "thesis.tex")) && project.settings?.mainFile == "thesis.tex" }
        #expect(app.alert == nil && undo.canUndo)
        await app.close()
        #expect(!undo.canUndo)
    }

    @Test func theExportedZipHasTheUnsavedEdits() async throws {
        let (project, _) = try await opened("original")
        #expect(project.editor.perform(.bold))
        let expected = project.editor.textView.string
        let zip = try await project.exportZip()
        let unzip = Process(), pipe = Pipe()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-p", zip.path(percentEncoded: false), try #require(project.openPath)]
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
        let pdf = folder.appending(path: "live.pdf")
        try #require(try textPDF(["live"]).dataRepresentation()).write(to: pdf)
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
        #expect(project.result?.ok == true && project.result?.pdfChanged == false && project.pdf.shownVersion == shown && project.panel.shown)
        await app.close()
    }

    @Test func theOutlineFollowsTheTopHeadingOnly() async throws {
        let project = try await opened("\\section{A}\n1\n2\n\\section{B}\n3").project
        try await waitUntil { project.outline.count == 2 }
        // The caret's move as the file opened is a turn behind.
        await settle()
        project.editor.onScroll(2)
        let told = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = project.currentHeading } onChange: { told.withLock { $0 = true } }
        project.editor.onScroll(3)
        #expect(!told.withLock { $0 } && project.topLine == 3)
        project.editor.onScroll(4)
        #expect(told.withLock { $0 } && project.currentHeading == project.outline[1].id && project.topHeading == project.outline[1].id)
        // A scroll the caret's move makes, in the same turn, leaves the caret's heading current.
        project.editor.onCursor(5, 0)
        project.editor.onScroll(1)
        #expect(project.topHeading == project.outline[0].id && project.currentHeading == project.outline[1].id)
        await app.close()
    }

    @Test func theOutlineReadsTheInputs() async throws {
        let project = try await opened("\\section{Intro}\nOne two\n\\include{chapters/a}",
                                       with: ["chapters/a.tex": "\\section{A}\nthree"]).project
        #expect(project.initialLoadComplete && project.outline.map(\.file) == ["main.tex", "chapters/a.tex"])
        project.reveal(project.outline[1])
        try await waitUntil { project.openPath == "chapters/a.tex" }
        #expect(project.headingCommand == "section")
        await app.close()
    }

    /// The session's watcher reaches the sidebar; its rules are the core's.
    @Test func anotherAppsFilesComeAndGo() async throws {
        let (project, folder) = try await opened()
        try "x".write(to: folder.appending(path: "notes.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { project.tree.node(at: "notes.tex") != nil }
        await app.close()
    }

    @Test func theTreeTellsOfAChangeOnly() async throws {
        let info = try await project().info, tree = FileTree(id: info.id)
        var changes = 0
        tree.onChange = { changes += 1 }
        await tree.reload()
        #expect(changes == 1 && tree.node(at: info.mainFile)?.isDirectory == false)
        await tree.reload()
        #expect(changes == 1)
        try info.write("x", to: "notes.tex")
        await tree.reload()
        #expect(changes == 2 && tree.node(at: "notes.tex") != nil)
        tree.close()
        try info.write("x", to: "more.tex")
        await tree.reload()
        #expect(changes == 2 && tree.node(at: "more.tex") == nil)
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
        project.answer("main.tex", "revert")
        try await waitUntil(timeout: .seconds(5)) { text.string == "theirs again" }
        #expect(project.diskConflict == nil && onDisk() == "theirs again" && app.alert == nil)
        await app.close()
    }

    /// A failed autosave is told once in an alert, and Not Saved stays in the status bar until a save succeeds.
    @Test func aFailedAutosaveIsToldOnceAndNotSavedStaysUntilASave() async throws {
        let (project, folder) = try await opened()
        let path = folder.path(percentEncoded: false)
        // The write replaces the file, so its folder refuses it.
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        #expect(project.editor.perform(.bold))
        #expect(await !project.save(reporting: false))
        try await waitUntil { project.saveFailure != nil }
        #expect(app.alert?.title == "“main.tex” Wasn’t Saved")
        app.alert = nil
        #expect(await !project.save(reporting: false))
        await settle()
        #expect(app.alert == nil && project.saveFailure != nil)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        #expect(await project.save())
        try await waitUntil { project.saveFailure == nil }
        #expect(app.alert == nil)
        await app.close()
    }

    /// An answer clears only its own file's alert: another file's question still waits.
    @Test func anAnswerLeavesAnotherFilesQuestion() async throws {
        let project = try await opened().project
        (project.diskConflict, project.missingFile) = ("main.tex", "gone.tex")
        project.answer("main.tex", "cancel", holding: "Held")
        #expect(project.diskConflict == nil && project.missingFile == "gone.tex")
        await app.close()
    }

    @Test func aClosedProjectsTrashCannotBeUndone() async throws {
        let undo = windowUndo(), (project, folder) = try await opened(with: ["notes.tex": "notes"])
        await undo.grouping { await project.deleteEntry("notes.tex") }
        #expect(undo.undoActionName == "Move to Trash")
        // Back from the Trash, which is left as it was; the Redo is the item's too.
        undo.undo()
        try await waitUntil { self.exists(folder.appending(path: "notes.tex")) && undo.canRedo }
        await app.close()
        #expect(!undo.canRedo && !undo.canUndo)
    }

    @Test func aRenameOnHomeCannotBeUndoneUnderAProject() async throws {
        let undo = windowUndo(), info = try await project().info
        let renamed = "Renamed \(UUID().uuidString.prefix(8))"
        folders.append(Core.libraryFolder.appending(path: renamed))

        await undo.grouping { await app.rename(info, to: renamed) }
        #expect(undo.canUndo && undo.undoActionName == "Rename")
        await app.open(renamed)
        #expect(app.project?.id == renamed && !undo.canUndo)
        await app.close()
    }

    @Test func aDroppedFileOpens() async throws {
        let (project, folder) = try await opened(with: ["notes.tex": "notes", "plot.png": ""])
        let drop = project.editor.textView.fileDrop
        #expect(drop(folder.appending(path: "plot.png"))?.inserted == "\\includegraphics{plot.png}", "An image dropped on LaTeX is a figure")
        let openNotes = try #require(drop(folder.appending(path: "notes.tex"))?.opens, "A text file dropped on the source opens")
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
        // Their answers can come back in either order; the settings shown are the last patch's.
        let both = [Task.immediate { await project.patchSettings(.stopOnFirstError(true)) },
                    Task.immediate { await project.patchSettings(.shellEscape(false)) }]
        for patch in both { #expect(await patch.value) }
        #expect(project.settings?.stopOnFirstError == true && project.settings?.shellEscape == false)
        await app.close()
    }

    /// Arrowing down the sidebar's files: each open closes the one before, and one a later open overtook closes its own.
    @Test func onlyTheFileShownStaysOpenInTheSession() async throws {
        let project = try await opened(with: ["a.tex": "a", "b.tex": "b"]).project
        let session = try #require(project.session)
        let paths = ["main.tex", "a.tex", "b.tex"]
        // A few turns apart, so the later open comes at different points in the earlier one's.
        for (round, turns) in [0, 1, 3, 10, 30].enumerated() {
            let first = paths[(2 * round + 1) % 3], last = paths[(2 * round + 2) % 3]
            let opening = Task { await project.open(first) }
            for _ in 0..<turns { await Task.yield() }
            await Task { await project.open(last) }.value
            await opening.value
            // Taken after any close an overtaken open sent: a session takes its commands in the order sent.
            try await Core.shared.call("session_set_options", ["session": session])
            #expect(project.openPath == last && project.editor.path == last)
            #expect(paths.filter { SourceDocument(session: session, path: $0) != nil } == [last], "after \(turns) turns")
        }
        #expect(app.alert == nil)
        await app.close()
    }

    /// Going back to the file shown while an open away from it has closed it, before that open took the answer: the file
    /// is shown with a document of the session's again, so what's typed in it is saved.
    @Test func anOpenOvertakenAfterClosingTheFileShownStillShowsItsOwn() async throws {
        let (project, folder) = try await opened(with: ["a.tex": "a"])
        let session = try #require(project.session)
        let mainClosed = { SourceDocument(session: session, path: "main.tex") == nil }
        let opening = Task { await project.open("a.tex") }
        // Waits holding the main actor, so the open can't take the close's answer before the next open is asked for.
        var held = false
        for _ in 0..<1000 where !held {
            await Task.yield()
            let until = ContinuousClock.now + .milliseconds(20)
            while !held, ContinuousClock.now < until { held = mainClosed() }
        }
        #expect(held && project.openPath == "main.tex")
        let back = Task.immediate { await project.open("main.tex") }
        await opening.value
        await back.value

        #expect(project.editor.path == "main.tex" && !mainClosed() && SourceDocument(session: session, path: "a.tex") == nil)
        #expect(project.editor.perform(.bold))
        #expect(await project.save())
        #expect(try String(contentsOf: folder.appending(path: "main.tex"), encoding: .utf8) == project.editor.textView.string)
        #expect(app.alert == nil)
        await app.close()
    }

    /// Stop and the session's word that Live Preview ended each put the build's PDF back: the pane never empties, and the
    /// build's pages go into the document showing.
    @Test func stoppingLivePreviewGoesBackToTheBuildsPDF() async throws {
        setenv("TEXLOCAL_TEXPRESSO", try liveTeXpresso().path, 1)
        defer { unsetenv("TEXLOCAL_TEXPRESSO") }
        let (info, folder) = try await project("\\documentclass{article}\\begin{document}x\\end{document}")
        try files.createDirectory(at: folder.appending(path: "build"), withIntermediateDirectories: true)
        #expect(try textPDF(["one", "two", "three"]).write(to: folder.appending(path: "build/main.pdf")))
        await app.open(info.id)
        let project = try #require(app.project)
        #expect(project.hasPDF && project.pdf.pageCount == 3)
        project.startTeXpresso()
        try await waitUntil(timeout: .seconds(10)) { project.livePDF && project.pdf.pageCount == 1 } state: {
            "phase \(project.texpresso.phase), log \(project.texpresso.log)"
        }
        let shown = project.pdf.view.document
        let emptied = OSAllocatedUnfairLock(initialState: false)
        let watch = track({ project.hasPDF }) { if !$0 { emptied.withLock { $0 = true } } }
        defer { watch.cancel() }
        project.stopTeXpresso()
        try await waitUntil(timeout: .seconds(10)) { project.texpresso.phase == .stopped && !project.livePDF }
        await settle()
        #expect(!emptied.withLock { $0 } && project.hasPDF && project.pdf.pageCount == 3)
        #expect(project.pdf.view.document === shown)
        await app.close()
    }

    @Test func cleanBuildFolderRemovesTheBuildFolder() async throws {
        let (project, folder) = try await opened(with: ["build/main.aux": "x"])
        await project.cleanBuildFolder()
        #expect(!exists(folder.appending(path: "build")) && exists(folder.appending(path: "main.tex")))
        #expect(project.result == nil && !project.hasPDF)
        await app.close()
    }

    /// Which lines match is the core's rule; a hit keeps its match's place for the editor.
    @Test func aSearchShowsWhatItSearchedAndABlankOneClears() async throws {
        let project = try await opened("a needle").project
        project.search.query = "needle"
        await project.search.run(in: project.session)
        #expect(project.search.groups?.first?.hits.first?.column == 2)
        project.search.query = "needles"
        #expect(project.search.searched == "needle")
        await project.search.run(in: project.session)
        #expect(project.search.groups?.isEmpty == true && project.search.searched == "needles")
        project.search.query = " "
        await project.search.run(in: project.session)
        #expect(project.search.groups == nil && project.search.hitCount == 0)
        await app.close()
    }

    /// A rename's answer has the state the core moved, written before the rename asked for it.
    @Test func theSidebarsStateIsKeptForTheProjectAndFollowsARename() async throws {
        let project = try await opened(with: ["ch/a.tex": ""]).project
        project.expandedFolders = ["ch"]
        project.foldedHeadings = ["main.tex\t1:Methods#1"]
        await project.renameEntry("ch", to: "chapters")
        #expect(project.expandedFolders == ["chapters"])
        await app.close()
        await app.open(project.id)
        let again = try #require(app.project)
        #expect(again !== project && again.expandedFolders == ["chapters"] && again.foldedHeadings == ["main.tex\t1:Methods#1"])
        await app.close()
    }

    /// The free names are the core's.
    @Test func aNewFileOpensInTheTree() async throws {
        let project = try await opened(with: ["untitled.tex": "x"]).project
        #expect(await project.createEntry(in: "", directory: false) == "untitled 2.tex")
        #expect(project.openPath == "untitled 2.tex" && project.editor.textView.document.text == "")
        #expect(await project.createEntry(in: "", directory: true) == "untitled folder" && project.openPath == "untitled 2.tex")
        #expect(project.tree.node(at: "untitled folder")?.isDirectory == true && app.alert == nil)
        await app.close()
    }

    @Test func treeDropsMoveTheProjectsFiles() async throws {
        let (project, folder) = try await opened(with: ["notes.tex": "notes", "parts/a.tex": ""])
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
