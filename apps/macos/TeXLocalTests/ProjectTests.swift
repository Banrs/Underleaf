import AppKit
import os
import PDFKit
import Testing
@testable import TeXLocal

/// The project folder's watcher: a write in place, a save over a file (a new
/// one renamed over it) and a delete then recreate are all told, by path;
/// items coming and going in a subfolder are told as structural.
@MainActor
final class FolderWatcherTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A watcher of the folder, and the changes it has told about `path`.
    private func watch(_ path: String) -> (FolderWatcher, () -> [FolderWatcher.Change]) {
        var told: [FolderWatcher.Change] = []
        let watcher = FolderWatcher(folder: folder) { told += $0 }
        return (watcher, { told.filter { watcher.relativePath($0.path) == path } })
    }

    @Test func changesInPlaceAndByReplacementAreBothTold() async throws {
        let url = folder.appending(path: "main.tex")
        try "one".write(to: url, atomically: false, encoding: .utf8)
        let (watcher, changes) = watch("main.tex")

        try "two".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { !changes().isEmpty }
        let inPlace = changes().count
        try "three".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil { changes().count > inPlace }
        // Still watching the new file at that path.
        let replaced = changes().count
        try "four".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes().count > replaced }
        _ = watcher
    }

    @Test func aFileDeletedThenRecreatedIsStillTold() async throws {
        let url = folder.appending(path: "main.tex")
        try "one".write(to: url, atomically: false, encoding: .utf8)
        let (watcher, changes) = watch("main.tex")

        try FileManager.default.removeItem(at: url)
        try await waitUntil { changes().contains(where: \.structural) }
        // Past the watcher's settle time, so the recreate is an event of its own.
        try await Task.sleep(for: .milliseconds(500))
        let deleted = changes().count
        try "two".write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { changes().count > deleted }
        _ = watcher
    }

    /// What a save leaves is a file at its path, spelt as the disk spells it; a link, a folder,
    /// another spelling or nothing is not.
    @Test func aFileIsARegularFileAtItsOwnSpelling() throws {
        let watcher = FolderWatcher(folder: folder) { _ in }
        try "text".write(to: folder.appending(path: "main.tex"), atomically: false, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appending(path: "chapters"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link.tex"),
                                                   withDestinationURL: folder.appending(path: "main.tex"))
        #expect(watcher.hasFile("main.tex"))
        #expect(!watcher.hasFile("link.tex") && !watcher.hasFile("chapters") && !watcher.hasFile("gone.tex"))
        // A volume that ignores case finds the file by this name too.
        if FileManager.default.fileExists(atPath: folder.appending(path: "MAIN.tex").path(percentEncoded: false)) {
            #expect(!watcher.hasFile("MAIN.tex"))
        }
    }

    @Test func anItemAddedInASubfolderIsStructural() async throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "chapters"), withIntermediateDirectories: true)
        let (watcher, changes) = watch("chapters/one.tex")

        try "text".write(to: folder.appending(path: "chapters/one.tex"), atomically: false, encoding: .utf8)
        try await waitUntil { changes().contains(where: \.structural) }
        _ = watcher
    }
}

/// The Rust core through its C ABI, in the scheme's scratch library
/// (`TEXLOCAL_DATA`). Projects are removed, not trashed: `delete_project`
/// trashes through Finder, which a headless test host can't drive, and the
/// core's own tests cover it.
@MainActor
struct CoreTests {
    init() throws {
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
    }

    @Test func commandsRoundTripThroughTheRustCore() async throws {
        let core = Core.shared
        let name = "Test \(UUID().uuidString.prefix(8))"
        let info = try await core.call("create_project", ["name": name, "template": "blank"], as: ProjectInfo.self)
        defer { try? FileManager.default.removeItem(at: Core.libraryFolder.appending(path: info.id)) }
        #expect(info.mainFile == "main.tex")

        try await core.perform("write_file", ["id": info.id, "path": "a.tex", "text": "hé"])
        let file = try await core.call("read_file", ["id": info.id, "path": "a.tex"], as: FileText.self)
        #expect(file.text == "hé")

        let tree = try await core.call("file_tree", ["id": info.id], as: [TreeNode].self)
        #expect(tree.contains { $0.path == "a.tex" })

        // A path outside the project is refused.
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

    /// Every template the projects screen offers is one the core can make.
    @Test func everyTemplateMakesAProject() async throws {
        for template in ProjectTemplate.allCases {
            let name = "Test \(template.id) \(UUID().uuidString.prefix(8))"
            let info = try await Core.shared.call("create_project", ["name": name, "template": template.rawValue],
                                                  as: ProjectInfo.self)
            try FileManager.default.removeItem(at: Core.libraryFolder.appending(path: info.id))
        }
    }
}

/// Projects as the app opens and edits them, in the test library. Each test
/// puts back the defaults `AppModel` writes and removes its projects.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
final class ProjectFlowTests {
    /// The app's defaults the tests change, put back after.
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

    /// A blank project whose main file holds `text`, and its folder.
    private func project(_ text: String = "text") async throws -> (info: ProjectInfo, folder: URL) {
        let info = try await Core.shared.call("create_project", ["name": "Test \(UUID().uuidString.prefix(8))", "template": "blank"],
                                              as: ProjectInfo.self)
        let folder = Core.libraryFolder.appending(path: info.id)
        folders.append(folder)
        try await Core.shared.perform("write_file", ["id": info.id, "path": info.mainFile, "text": text])
        return (info, folder)
    }

    /// A new project, open.
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

    /// The main file is read from disk before a Move to Trash: another editor may have
    /// changed it since the project opened (#37).
    @Test func theMainFileOnDiskStaysOutOfTheTrash() async throws {
        let (project, folder) = try await opened()
        try await Core.shared.perform("write_file", ["id": project.id, "path": "second.tex", "text": "x"])
        let settings = folder.appending(path: ".texlocal.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        json["mainFile"] = "second.tex"
        try JSONSerialization.data(withJSONObject: json).write(to: settings)
        await project.deleteEntry("second.tex")
        #expect(files.fileExists(atPath: folder.appending(path: "second.tex").path))
        #expect(project.settings?.mainFile == "second.tex")
    }

    /// Two opens that overlap (the project restored at launch and an Open
    /// With import, or quick successive opens) leave the editor on the one
    /// opened last, never on the other's text.
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

    /// Edit › Undo takes a file's rename back, and the main file with it; Redo renames it again.
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

    /// Export Project as ZIP archives the open file as it is on screen, before its autosave (#27).
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

    /// Automatic builds leave the build panel as it is while typing goes on, failed or clean;
    /// Compile opens it on a failure's issues, and closes the panel it opened once the build is
    /// clean. CI has no TeX.
    @Test func onlyCompileMovesThePanel() async throws {
        let project = try await openedWithTeX("\\documentclass{article}\\begin{document}\\undefinedmacro x\\end{document}")
        await project.compile(auto: true)
        #expect(project.result?.failed == true && project.result?.pdf != nil && !project.panel.shown)
        await project.compile()
        #expect(project.panel.shown && project.panel.tab == .issues)
        let text = project.editor.textView
        text.insertText("", replacementRange: (text.string as NSString).range(of: "\\undefinedmacro"))
        await project.compile(auto: true)
        #expect(project.result?.ok == true && project.panel.shown)
        await project.compile()
        #expect(project.result?.ok == true && !project.panel.shown)
        await app.close()
    }

    /// An autosave that fails says so in the status bar, without an alert at each pause in
    /// typing; a save that was asked for explains itself, and the next good one clears both.
    @Test func aFailedAutosaveInterruptsNothing() async throws {
        let (project, folder) = try await opened("original")
        let main = folder.appending(path: try #require(project.openPath))
        func lock(_ locked: Bool) throws {
            try files.setAttributes([.posixPermissions: locked ? 0o444 : 0o644], ofItemAtPath: main.path(percentEncoded: false))
            try files.setAttributes([.posixPermissions: locked ? 0o555 : 0o755], ofItemAtPath: folder.path(percentEncoded: false))
        }
        try lock(true)
        defer { try? lock(false) }
        #expect(project.editor.perform(.bold))
        #expect(await !project.save(reporting: false))
        #expect(project.saveFailure != nil && app.alert == nil && project.dirty)
        #expect(await !project.flush())
        #expect(app.alert != nil)
        app.alert = nil
        try lock(false)
        #expect(await project.save(reporting: false))
        #expect(project.saveFailure == nil && app.alert == nil)
        await app.close()
    }

    /// A search with no PDF to search, like one on a line SyncTeX has no match for, is a line
    /// in the status bar, not an alert.
    @Test func aSyncTeXMissIsNoAlert() async throws {
        let (project, _) = try await opened()
        await project.forwardSync()
        #expect(project.notices.current == "No compiled PDF yet" && app.alert == nil)
        await app.close()
    }

    /// A notice is in the status bar at once, the later of two, and goes by itself.
    @Test func aNoticeGoesByItself() async throws {
        let notices = ProjectNotices(lasting: .milliseconds(100))
        notices.note("One")
        notices.note("Two")
        #expect(notices.current == "Two")
        try await waitUntil { notices.current == nil }
    }

    /// A project that can't be read doesn't open on an empty workspace: the alert says why over Home.
    @Test func aProjectThatCannotLoadStaysClosed() async throws {
        await app.open("No Such Project \(UUID().uuidString.prefix(8))")
        #expect(app.project == nil && app.alert != nil && !app.isOpening)
    }

    /// A project whose PDF is built opens with it shown, and with the build panel as it was left:
    /// the PDF loads as the main file is read, and is there when the workspace appears.
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

    /// An item that can't be copied in and a rename the core refuses are each an alert that names
    /// it: nothing is left opening, and the recents keep what they had.
    @Test func aRefusalOnHomeIsAnAlertThatNamesIt() async throws {
        let missing = files.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        await app.importProject(from: missing)
        #expect(app.alert?.title == "Couldn’t Open “\(missing.lastPathComponent)”" && app.project == nil && !app.isOpening)
        let recents = app.recentProjects
        let gone = ProjectInfo(id: "No Such Project \(UUID().uuidString.prefix(8))", name: "Gone", mtime: 0, mainFile: "main.tex")
        await app.rename(gone, to: "Elsewhere")
        #expect(app.alert?.title == "Couldn’t Rename “Gone”" && app.recentProjects == recents)
    }

    /// A file of a project already in the library opens that project on the file, where it had
    /// been copied into a second project.
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

    /// Go to Next Issue goes round the issues the log places in a file, and the gutter marks
    /// their lines until the file is edited. CI has no TeX.
    @Test func issuesAreSteppedThroughAndMarked() async throws {
        let project = try await openedWithTeX("\\documentclass{article}\n\\begin{document}\n\\undefinedmacro\n\n\\anotherundefined\n\\end{document}\n")
        await project.compile()
        let text = project.editor.textView, issues = project.issues
        let places = issues.indices.filter { issues[$0].file != nil }
        #expect(places.map { issues[$0].line } == [3, 5] && text.issueLines.mapValues(\.isError) == [3: true, 5: true])
        for (next, place) in [(true, 0), (true, 1), (true, 0), (false, 1)] {
            project.goToIssue(next: next)
            #expect(project.chosenIssue == places[place])
            try await waitUntil { project.cursorLine == issues[places[place]].line }
        }
        text.insertText("x", replacementRange: text.selectedRange())
        #expect(text.issueLines.isEmpty)
        await app.close()
    }

    /// A line with several issues is marked for its first, an error's before a warning's, with
    /// what its others say in their order; another file's issues aren't the open file's. A
    /// build's result is put in its place, so without TeX.
    @Test func aLinesIssuesAreItsFirstAndItsOthers() async throws {
        let (project, folder) = try await opened("a\nb\n")
        try await Core.shared.perform("write_file", ["id": project.id, "path": "part.tex", "text": "a\nb\n"])
        func item(_ type: String, _ file: String, _ line: Int, _ message: String) -> LogItem {
            LogItem(type: type, file: file, line: line, message: message)
        }
        let main = try #require(project.openPath)
        project.result = CompileResult(
            ok: false, stopped: false, pdf: nil, pdfChanged: false, durationMs: 0,
            errors: [item("error", "part.tex", 2, "first"), item("error", main, 1, "elsewhere"), item("error", "part.tex", 2, "second")],
            warnings: [item("warning", "part.tex", 2, "third"), item("warning", "part.tex", 1, "alone")], log: "")
        await project.open("part.tex")
        let text = project.editor.textView
        #expect(project.openPath == "part.tex")
        #expect(text.issueLines == [1: .init(isError: false, message: "alone"), 2: .init(isError: true, message: "first", others: ["second", "third"])])
        // Another app's change to the file is an edit of it: the build's lines were the old text's,
        // and stay gone when the file is next shown.
        try "c\nd\n".write(to: folder.appending(path: "part.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { text.string == "c\nd\n" }
        #expect(text.issueLines.isEmpty)
        await project.open(main)
        #expect(text.issueLines.mapValues(\.isError) == [1: true])
        await project.open("part.tex")
        #expect(text.string == "c\nd\n" && text.issueLines.isEmpty)
        await app.close()
    }

    /// A TeXpresso stand-in that writes a one-page PDF where it's asked to, as Underleaf's
    /// patched build does, and reads edits until it's stopped.
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

    /// Live pages aren't a build's: SyncTeX looks them up in TeXpresso's own (which the stand-in
    /// doesn't write, so the core says so rather than answering from a build's), and stopping
    /// without a build's PDF empties the pane rather than leaving them as one.
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

    /// A clean no-op build keeps the PDF's pages, and leaves open a panel the person opened.
    @Test func aNoOpBuildKeepsThePDFDocumentAndThePanel() async throws {
        let project = try await openedWithTeX("\\documentclass{article}\\begin{document}x\\end{document}")
        (project.panel.shown, project.panel.tab) = (true, .log)
        await project.compile()
        #expect(project.result?.ok == true && project.result?.pdfChanged == true && project.panel.shown)
        let shown = project.pdf.shownVersion
        project.panel.tab = .issues
        await project.compile()
        #expect(project.result?.ok == true && project.result?.pdfChanged == false)
        #expect(project.pdf.shownVersion == shown)
        #expect(project.panel.shown)
        await app.close()
    }

    /// A clean build closes the panel only where a failed one opened it and it still shows the
    /// issues: not one the person opened, before the failure or again after closing it. The live
    /// preview's log is followed while the panel shows it, and no longer.
    @Test func aCleanBuildClosesOnlyThePanelAFailureOpened() async throws {
        let project = try await opened().project, panel = project.panel
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
        #expect(project.texpresso.showsLog)
        panel.tab = .issues
        #expect(!project.texpresso.showsLog)
        panel.closeAfterCleanBuild()
        #expect(panel.shown)
        panel.tab = .texpresso
        panel.shown = false
        #expect(!project.texpresso.showsLog)
        await app.close()
    }

    /// Overlapping rename/settings requests leave the build and disk settings in agreement.
    @Test func aRenameAndSettingsChangesKeepTheLatestMainFile() async throws {
        let source = "\\documentclass{article}\\begin{document}x\\end{document}"
        let project = try await openedWithTeX(source), folder = Core.libraryFolder.appending(path: project.id)
        try await Core.shared.perform("write_file", ["id": project.id, "path": "second.tex", "text": source])
        await project.compile()
        #expect(project.result?.ok == true && project.pdfURL?.lastPathComponent == "main.pdf")

        // The build follows the main file only when Compile Automatically is on.
        app.autoCompile = true
        let rename = Task { await project.renameEntry("main.tex", to: "renamed.tex") }
        let flag = Task { _ = await project.patchSettings(.stopOnFirstError(true)) }
        let main = Task { await project.setMainFile("second.tex") }
        for change in [rename, flag, main] { await change.value }
        try await waitUntil(timeout: .seconds(30)) {
            !project.compiling && project.result?.pdf == "build/second.pdf"
                && project.pdfURL?.lastPathComponent == "second.pdf"
        }

        let persisted = try await Core.shared.call("get_settings", ["id": project.id], as: ProjectSettings.self)
        #expect(project.settings?.mainFile == "second.tex" && persisted.mainFile == "second.tex")
        #expect(project.settings?.stopOnFirstError == true && persisted.stopOnFirstError)
        #expect(project.result?.ok == true)
        #expect(exists(folder.appending(path: "renamed.tex")) && !exists(folder.appending(path: "main.tex")))
        #expect(app.alert == nil)
        await app.close()
    }

    /// Set as Main File starts a build only when Compile Automatically is on, as every other
    /// setting that changes the build does. CI has no TeX.
    @Test func aNewMainFileBuildsOnlyWhenCompilingAutomatically() async throws {
        let source = "\\documentclass{article}\\begin{document}x\\end{document}"
        let project = try await openedWithTeX(source)
        try await Core.shared.perform("write_file", ["id": project.id, "path": "second.tex", "text": source])
        await project.setMainFile("second.tex")
        #expect(project.settings?.mainFile == "second.tex" && project.result == nil && !project.compiling)
        app.autoCompile = true
        await project.setMainFile("main.tex")
        #expect(project.result?.pdf == "build/main.pdf")
        await app.close()
    }

    /// The outline hears of a scroll only as another heading reaches the top, not on every line.
    @Test func theOutlineFollowsTheTopHeadingOnly() async throws {
        let project = try await opened("\\section{A}\n1\n2\n\\section{B}\n3").project
        try await waitUntil { project.outline.count == 2 }
        let scrolled = project.editor.onScroll
        scrolled(2)
        let told = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = project.topHeading } onChange: { told.withLock { $0 = true } }
        scrolled(3)
        #expect(!told.withLock { $0 } && project.topLine == 3)
        scrolled(4)
        #expect(told.withLock { $0 } && project.topHeading == project.outline[1].id)
        await app.close()
    }

    /// The outline and word count are the document's, through its \input and \include;
    /// a heading in another file opens that file at it.
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
        #expect(project.headingLevel.title == "Section")
        await app.close()
    }

    /// Aa numbers the levels as the main file's class does, read whichever file is open.
    @Test func theClassIsTheMainFiles() async throws {
        let (info, folder) = try await project("% \\documentclass{book}\n\\documentclass[11pt]{report}\n\\include{a}")
        try "\\section{A}\nthree".write(to: folder.appending(path: "a.tex"), atomically: false, encoding: .utf8)
        await app.open(info.id)
        let project = try #require(app.project)
        try await waitUntil { project.documentClass?.name == "report" }
        project.reveal(project.outline[0])
        try await waitUntil { project.openPath == "a.tex" }
        #expect(project.documentClass == DocumentClass(name: "report", pointSize: 11))
        await app.close()
    }

    /// Files another app adds, moves or deletes show in the sidebar's tree.
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

    /// Deleted by another app, the open file closes; with unsaved edits it asks
    /// first, saving nothing meanwhile, and Save Again makes it again.
    @Test func anOpenFileDeletedElsewhere() async throws {
        let (project, folder) = try await opened()
        let notes = folder.appending(path: "notes.tex")
        try "notes".write(to: notes, atomically: false, encoding: .utf8)

        await project.open("notes.tex")
        try files.removeItem(at: notes)
        try await waitUntil(timeout: .seconds(5)) { project.openPath == nil }
        #expect(project.missingFile == nil)

        try "notes".write(to: notes, atomically: false, encoding: .utf8)
        await project.open("notes.tex")
        try files.removeItem(at: notes)
        #expect(project.editor.perform(.bold))
        try await waitUntil(timeout: .seconds(5)) { project.missingFile == "notes.tex" }
        // After the autosave, which would have made the file again.
        await project.saveTask?.value
        #expect(!exists(notes))
        // Cancel leaves the edits unsaved: an autosave doesn't make the file, and a save asks again.
        project.missingFile = nil
        #expect(project.editor.perform(.italic))
        await project.saveTask?.value
        #expect(!exists(notes) && project.missingFile == nil)
        #expect(await !project.saveEdits() && project.missingFile == "notes.tex")
        project.saveMissingFile()
        try await waitUntil(timeout: .seconds(5)) { exists(notes) }
        #expect(try String(contentsOf: notes, encoding: .utf8).contains("\\textbf{\\textit{}}"))
        await app.close()
    }

    /// Changed by another app while it has unsaved edits, the open file asks which version to
    /// keep and saves nothing meanwhile. Cancel leaves the edits unsaved, and a save that is
    /// asked for asks again; Save Anyway writes them, and Revert takes the disk's text.
    @Test func anOpenFileChangedElsewhere() async throws {
        let (project, folder) = try await opened("original")
        let main = folder.appending(path: "main.tex")
        let onDisk = { try? String(contentsOf: main, encoding: .utf8) }

        try "theirs".write(to: main, atomically: false, encoding: .utf8)
        #expect(project.editor.perform(.bold))
        try await waitUntil(timeout: .seconds(5)) { project.diskConflict == "main.tex" }
        // Cancel, then after an autosave, which would have written over the other app's change.
        project.diskConflict = nil
        #expect(project.editor.perform(.italic))
        await project.saveTask?.value
        #expect(onDisk() == "theirs" && project.diskConflict == nil && project.dirty)
        #expect(await !project.saveEdits() && project.diskConflict == "main.tex")
        project.keepEdits()
        try await waitUntil(timeout: .seconds(5)) { onDisk() == project.editor.textView.string }
        #expect(project.diskConflict == nil && onDisk()?.contains("\\textbf{\\textit{}}") == true)
        // Behind that save in the lane, so it has finished with the model before the next change.
        #expect(await project.save() && !project.dirty)

        // Answered, so the next change asks anew.
        try "theirs again".write(to: main, atomically: false, encoding: .utf8)
        #expect(project.editor.perform(.bold))
        try await waitUntil(timeout: .seconds(5)) { project.diskConflict == "main.tex" }
        await project.revertToDisk("main.tex")
        #expect(project.editor.textView.string == "theirs again" && onDisk() == "theirs again")
        #expect(project.diskConflict == nil && !project.dirty && app.alert == nil)
        await app.close()
    }

    /// After a save here, another app's change of the same length, in place, still reaches the
    /// editor: the save's own change is known by the file's stamp, which a later write alters.
    @Test func aChangeOfTheSameLengthAfterASaveIsTaken() async throws {
        let (project, folder) = try await opened("original")
        #expect(project.editor.perform(.bold))
        #expect(await project.save() && !project.dirty)
        let saved = project.editor.textView.string
        // Past the save's own change, which leaves the editor as it is.
        try await Task.sleep(for: .seconds(1))
        #expect(project.editor.textView.string == saved && project.diskConflict == nil)
        let theirs = String(saved.reversed())
        try theirs.write(to: folder.appending(path: "main.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { project.editor.textView.string == theirs }
        await app.close()
    }

    /// A file's Move to Trash can't be undone or redone once its project has closed, as its
    /// renames can't: the window's undo stack outlives the project, and nothing would show the result.
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

    /// A project's rename on Home can't be undone once a project is open: the Undo, reached from
    /// the sidebar, would rename the open project's folder under it.
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

    /// A file dropped on the source opens: the project's own in the editor, but its image goes
    /// into LaTeX as a figure. One from elsewhere is refused: the sidebar copies files in.
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

    /// A change to a setting shows in the model before the core answers, so its control doesn't
    /// snap back, and one the core refuses is put back.
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

    /// Clean Build Folder removes the build folder and what the build left in the window.
    @Test func cleanBuildFolderRemovesTheBuildFolder() async throws {
        let (project, folder) = try await opened()
        try files.createDirectory(at: folder.appending(path: "build"), withIntermediateDirectories: true)
        try "x".write(to: folder.appending(path: "build/main.aux"), atomically: false, encoding: .utf8)
        await project.cleanBuildFolder()
        #expect(!exists(folder.appending(path: "build")) && exists(folder.appending(path: "main.tex")))
        #expect(project.result == nil && project.pdfURL == nil)
    }

    /// Clean Build Folder during a build stops it and waits for it to end, so the stopped build
    /// neither writes into the folder after it goes nor reports after the clean. CI has no TeX.
    @Test func cleanBuildFolderWaitsForTheBuildItStops() async throws {
        let project = try await openedWithTeX("\\documentclass{article}\\begin{document}x\\end{document}")
        let build = Task.immediate { await project.compile() }
        #expect(project.compiling)
        await project.cleanBuildFolder()
        #expect(!project.compiling && project.result == nil && project.pdfURL == nil)
        await build.value
        #expect(project.result == nil && !exists(Core.libraryFolder.appending(path: "\(project.id)/build")))
        await app.close()
    }

    /// Find in Project has a query's hits under their files, in the order of the files' names,
    /// with the query they are for until the next search ends, and none yet, nor a failure, once
    /// the query is cleared.
    @Test func aSearchListsItsHitsByFile() async throws {
        let project = try await opened("needle\nhay\nNeedle").project
        try await Core.shared.perform("write_file", ["id": project.id, "path": "appendix.tex", "text": "a needle"])
        project.search.query = "needle"
        await project.search.run()
        #expect(project.search.hits?.count == 3 && project.search.failure == nil)
        #expect(project.search.groups.map(\.file) == ["appendix.tex", "main.tex"] && project.search.groups.map(\.hits.count) == [1, 2])
        project.search.query = "needles"
        #expect(project.search.searched == "needle")
        await project.search.run()
        #expect(project.search.hits?.isEmpty == true && project.search.searched == "needles")
        project.search.query = " "
        await project.search.run()
        #expect(project.search.hits == nil && project.search.failure == nil && project.search.groups.isEmpty)
        await app.close()
    }

    /// The tree tells its project of a read only when the files have changed, and takes none
    /// once the project has closed.
    @Test func theTreeTellsOfAChangeOnly() async throws {
        let info = try await project().info, tree = FileTree(id: info.id)
        var changes = 0
        tree.onChange = { changes += 1 }
        try await tree.read()
        #expect(changes == 1 && tree.node(at: info.mainFile)?.isDirectory == false)
        await tree.reload()
        #expect(changes == 1)
        try await Core.shared.perform("write_file", ["id": info.id, "path": "notes.tex", "text": "x"])
        await tree.reload()
        #expect(changes == 2 && tree.node(at: "notes.tex") != nil)
        tree.close()
        try await Core.shared.perform("write_file", ["id": info.id, "path": "more.tex", "text": "x"])
        await tree.reload()
        #expect(changes == 2 && tree.node(at: "more.tex") == nil)
    }

    /// A project's open folders and folded headings come back the next time it opens.
    @Test func theSidebarsStateIsKeptForTheProject() {
        let id = "SidebarState \(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults.standard
        defer { for name in ["expandedFolders", "foldedHeadings"] { defaults.removeObject(forKey: "\(name).\(id)") } }
        let first = ProjectModel(id: id, app: app)
        #expect(first.expandedFolders.isEmpty && first.foldedHeadings.isEmpty)
        first.expandedFolders = ["chapters", "chapters/appendix"]
        first.foldedHeadings = ["main.tex\t1:Methods#1"]
        let second = ProjectModel(id: id, app: app)
        #expect(second.expandedFolders == ["chapters", "chapters/appendix"] && second.foldedHeadings == ["main.tex\t1:Methods#1"])
    }

    /// A renamed project keeps its open folders and folded headings, which go with its id; a
    /// deleted one's are forgotten.
    @Test func theSidebarsStateFollowsARenameAndGoesWithTheProject() async throws {
        let info = try await project().info
        let defaults = UserDefaults.standard
        let renamed = "Renamed \(UUID().uuidString.prefix(8))"
        defer { ProjectModel.forgetSidebarState(of: info.id); ProjectModel.forgetSidebarState(of: renamed) }
        defaults.set(["chapters"], forKey: "expandedFolders.\(info.id)")
        defaults.set(["main.tex\t1:Intro#1"], forKey: "foldedHeadings.\(info.id)")
        await app.rename(info, to: renamed)
        folders.append(Core.libraryFolder.appending(path: renamed))
        #expect(defaults.stringArray(forKey: "expandedFolders.\(renamed)") == ["chapters"])
        #expect(defaults.stringArray(forKey: "foldedHeadings.\(renamed)") == ["main.tex\t1:Intro#1"])
        #expect(defaults.object(forKey: "expandedFolders.\(info.id)") == nil && defaults.object(forKey: "foldedHeadings.\(info.id)") == nil)
        ProjectModel.forgetSidebarState(of: renamed)
        #expect(defaults.object(forKey: "expandedFolders.\(renamed)") == nil && defaults.object(forKey: "foldedHeadings.\(renamed)") == nil)
    }

    /// The Dock icon's menu lists the recent projects still in the library, newest first,
    /// as Pages and Xcode list their recent documents; one opens as from Home, its window
    /// brought forward, and offers New Project…, which opens its sheet.
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
        #expect(shown == 1 && app.newProjectTemplate != nil)
        app.newProjectTemplate = nil
        menu.performActionForItem(at: 1)
        try await waitUntil(timeout: .seconds(5)) { app.project?.id == first.id && app.project?.initialLoadComplete == true }
        #expect(shown == 2 && app.recentProjects.first == first.id)
        #expect(NSApp.delegate?.responds(to: #selector((any NSApplicationDelegate).applicationDockMenu(_:))) == true)
        await app.close()
    }

    /// New items are "untitled.tex" and "untitled folder", numbered past the names taken
    /// where they go as Finder numbers them, another app's too before the tree has them.
    /// A new file opens, without the keyboard, which goes to its name.
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
        #expect(".latexmkrc".numbered(2) == ".latexmkrc 2")
        #expect(app.alert == nil)
        await app.close()
    }

    /// Dropped on the tree, the project's own files move, as in Finder, but a
    /// folder not into itself; a file from elsewhere is copied in.
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

private extension ProjectModel {
    /// The file the PDF pane shows, a build's or live preview's: the app itself asks only which kind it is.
    var pdfURL: URL? {
        switch shown {
        case .none: nil
        case .build(let url), .live(let url): url
        }
    }
}

/// Move to Trash that Edit › Undo takes back, as Finder's does.
@Suite(.timeLimit(.minutes(1)))
@MainActor
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

        // Leave the Trash as it was.
        undo.undo()
        try await waitUntil { files.fileExists(atPath: url.path) }
        try files.removeItem(at: url)
    }

    /// An Undo asked while a Redo is still on its way to the Trash waits for it, then puts
    /// the item back, rather than finding nothing to put back (#36).
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
