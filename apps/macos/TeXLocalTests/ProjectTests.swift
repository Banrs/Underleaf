import AppKit
import os
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
    }

    /// Every template the projects screen offers is one the core can make.
    @Test func everyTemplateMakesAProject() async throws {
        for template in ProjectTemplate.all {
            let name = "Test \(template.id) \(UUID().uuidString.prefix(8))"
            let info = try await Core.shared.call("create_project", ["name": name, "template": template.id],
                                                  as: ProjectInfo.self)
            try FileManager.default.removeItem(at: Core.libraryFolder.appending(path: info.id))
        }
    }
}

/// Projects as the app opens and edits them, in the test library. Each test
/// puts back the defaults `AppModel` writes and removes its projects.
@MainActor
@Suite(.serialized)
final class ProjectFlowTests {
    /// The app's defaults the tests change, its window's frame and dividers among them, put back after.
    private let keys = [DefaultsKey.autoCompile, DefaultsKey.recentProjects, DefaultsKey.outlineCollapsed, DefaultsKey.sidebarVisible,
                        "NSWindow Frame Main Window"] + ["Workspace", "Sidebar", "Columns", "Area"].map { "NSSplitView Subview Frames \($0)" }
    private let kept: [Any?]
    private var folders: [URL] = []
    private let files = FileManager.default
    private var windowController: MainWindowController?
    let app = AppModel()

    init() throws {
        // Removed rather than trashed, as `CoreTests` explains: only in the test library.
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        kept = keys.map { UserDefaults.standard.object(forKey: $0) }
        app.autoCompile = false
    }

    isolated deinit {
        windowController?.workspace?.close()
        windowController?.window?.close()
        windowController?.window?.contentViewController = nil
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
        await app.refresh()
        if app.tex?.available != true { try Test.cancel("No TeX") }
        return try await opened(text).project
    }

    private func windowFixture() async throws -> (ProjectModel, MainWindowController) {
        let info = try await project("\\section{Introduction}\nText Text").info
        app.outlineCollapsed = false
        app.sidebarVisible = true
        let model = ProjectModel(id: info.id, app: app)
        app.project = model
        let controller = MainWindowController(app: app)
        windowController = controller
        return (model, controller)
    }

    private func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path(percentEncoded: false)) }

    /// Two opens that overlap (the project restored at launch and an Open
    /// With import, or quick successive opens) leave the editor on the one
    /// opened last, never on the other's text.
    @Test(.timeLimit(.minutes(1)))
    func theLastOpenHasTheEditor() async throws {
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

    /// Loading readiness and real outline rows; entrance animation needs native UI verification.
    @Test func theFirstWorkspaceIncludesTheOutline() async throws {
        let (project, controller) = try await windowFixture()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.workspace == nil)

        await project.load()
        try await waitUntil { controller.workspace != nil }
        let workspace = try #require(controller.workspace)
        func lists(_ view: NSView) -> [NSOutlineView] {
            [view as? NSOutlineView].compactMap(\.self) + view.subviews.flatMap(lists)
        }
        // The heading, under the File Outline's header at the files' foot.
        try await waitUntil {
            workspace.view.layoutSubtreeIfNeeded()
            return lists(workspace.outlineItem.viewController.view).first?.numberOfRows == 1
        }
        #expect(!workspace.outlineItem.isCollapsed)
        #expect(workspace.outlineItem.viewController.view.frame.height > 0)
    }

    /// Edit › Find's items reach the source's own find bar: from the text through the
    /// responder chain, and through the window while the keyboard is elsewhere.
    @Test func findAndReplaceAreTheTextViewsFindBar() async throws {
        let (project, controller) = try await windowFixture()
        await project.load()
        try await waitUntil { controller.workspace != nil }
        let window = try #require(controller.window)
        let editor = project.editor, text = editor.textView
        func item(_ action: NSTextFinder.Action) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
            item.tag = action.rawValue
            return item
        }
        func textFields(in view: NSView?) -> [NSTextField] {
            guard let view else { return [] }
            return [view as? NSTextField].compactMap(\.self) + view.subviews.flatMap { textFields(in: $0) }
        }

        window.makeFirstResponder(nil)
        #expect(controller.validateMenuItem(item(.showFindInterface)))
        controller.performFindPanelAction(item(.showFindInterface))
        try await waitUntil { editor.scrollView.isFindBarVisible }

        // Use Selection for Find, then Find Next, from the text.
        let source = text.string as NSString
        text.setSelectedRange(source.range(of: "Text"))
        window.makeFirstResponder(text)
        #expect(window.firstResponder?.tryToPerform(#selector(NSTextView.performFindPanelAction(_:)), with: item(.setSearchString)) == true)
        #expect(text.validateUserInterfaceItem(item(.nextMatch)))
        text.performFindPanelAction(item(.nextMatch))
        #expect(text.selectedRange() == source.range(of: "Text", options: .backwards))

        // Find and Replace adds the stock replace field; Replace All uses it, as one undo step.
        #expect(text.validateUserInterfaceItem(item(.showReplaceInterface)))
        text.performFindPanelAction(item(.showReplaceInterface))
        try await waitUntil { textFields(in: editor.scrollView.findBarView).count == 2 }
        let replace = try #require(textFields(in: editor.scrollView.findBarView).last)
        replace.stringValue = "Word"
        replace.sendAction(replace.action, to: replace.target)
        text.performFindPanelAction(item(.replaceAll))
        try await waitUntil { text.string.hasSuffix("Word Word") }
        text.undoManager?.undo()
        #expect(text.string.hasSuffix("Text Text"))
    }

    /// Overlapping requests settle at the new path; the scheduler chooses their core interleaving.
    @Test(.timeLimit(.minutes(1)))
    func overlappingRenameAndSaveRequestsKeepEditsAtTheNewPath() async throws {
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
    @Test(.timeLimit(.minutes(1)))
    func aFileRenameCanBeUndoneAndRedone() async throws {
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
    @Test(.timeLimit(.minutes(1)))
    func theExportedZipHasTheUnsavedEdits() async throws {
        let (project, _) = try await opened("original")
        #expect(project.editor.perform(.bold))
        let expected = project.editor.textView.string
        let zip = try await project.exportZip()
        defer { try? files.removeItem(at: zip.deletingLastPathComponent()) }
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/unzip")
        unzip.arguments = ["-p", zip.path(percentEncoded: false), try #require(project.openPath)]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == expected)
        await app.close()
    }

    /// A failed automatic build that still wrote a PDF leaves the build panel
    /// shut while typing goes on; Compile opens it on the issues. CI has no TeX.
    @Test(.timeLimit(.minutes(1)))
    func onlyCompileOpensThePanelOverAPDF() async throws {
        let project = try await openedWithTeX("\\documentclass{article}\\begin{document}\\undefinedmacro x\\end{document}")
        await project.compile(auto: true)
        #expect(project.result?.failed == true && project.result?.pdf != nil && !project.showLogs)
        await project.compile()
        #expect(project.showLogs && project.panelTab == .issues)
        await app.close()
    }

    /// A clean no-op build keeps PDFKit's document and closes an empty Issues
    /// panel, while a Log panel stays open.
    @Test(.timeLimit(.minutes(1)))
    func aNoOpBuildKeepsThePDFDocumentAndClosesEmptyIssues() async throws {
        let project = try await openedWithTeX("\\documentclass{article}\\begin{document}x\\end{document}")
        (project.showLogs, project.panelTab) = (true, .log)
        await project.compile()
        #expect(project.result?.ok == true && project.result?.pdfChanged == true && project.showLogs)
        let firstDocument = try #require(project.pdf.view.document)
        project.panelTab = .issues
        await project.compile()
        #expect(project.result?.ok == true && project.result?.pdfChanged == false)
        #expect(project.pdf.view.document === firstDocument)
        #expect(!project.showLogs)
        await app.close()
    }

    /// Overlapping rename/settings requests leave the build and disk settings in agreement.
    @Test(.timeLimit(.minutes(2)))
    func aRenameAndSettingsChangesKeepTheLatestMainFile() async throws {
        await app.refresh()
        if app.tex?.available != true { try Test.cancel("No TeX") }
        let source = "\\documentclass{article}\\begin{document}x\\end{document}"
        let (info, folder) = try await project(source)
        try await Core.shared.perform("write_file", ["id": info.id, "path": "second.tex", "text": source])
        await app.open(info.id)
        let project = try #require(app.project)
        await project.compile()
        #expect(project.result?.ok == true && project.pdfURL?.lastPathComponent == "main.pdf")

        let rename = Task { await project.renameEntry("main.tex", to: "renamed.tex") }
        let flag = Task { _ = await project.patchSettings(["stopOnFirstError": true]) }
        let main = Task { await project.setMainFile("second.tex") }
        for change in [rename, flag, main] { await change.value }
        try await waitUntil(timeout: .seconds(30)) {
            !project.compiling && project.result?.pdf == "build/second.pdf"
                && project.pdfURL?.lastPathComponent == "second.pdf"
        }

        let persisted = try await Core.shared.call("get_settings", ["id": info.id], as: ProjectSettings.self)
        #expect(project.settings?.mainFile == "second.tex" && persisted.mainFile == "second.tex")
        #expect(project.settings?.stopOnFirstError == true && persisted.stopOnFirstError)
        #expect(project.result?.ok == true)
        #expect(exists(folder.appending(path: "renamed.tex")) && !exists(folder.appending(path: "main.tex")))
        #expect(app.alert == nil)
        await app.close()
    }

    /// The outline hears of a scroll only as another heading reaches the top, not on every line.
    @Test(.timeLimit(.minutes(1)))
    func theOutlineFollowsTheTopHeadingOnly() async throws {
        let info = try await project("\\section{A}\n1\n2\n\\section{B}\n3").info
        await app.open(info.id)
        let project = try #require(app.project)
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
    @Test(.timeLimit(.minutes(1)))
    func theOutlineReadsTheInputs() async throws {
        let (info, folder) = try await project("\\section{Intro}\nOne two\n\\include{chapters/a}")
        try files.createDirectory(at: folder.appending(path: "chapters"), withIntermediateDirectories: false)
        try "\\section{A}\nthree".write(to: folder.appending(path: "chapters/a.tex"), atomically: false, encoding: .utf8)
        await app.open(info.id)
        let project = try #require(app.project)
        #expect(project.initialLoadComplete)
        #expect(project.outline.count == 2)
        #expect(project.outline.map(\.file) == ["main.tex", "chapters/a.tex"])
        #expect(project.counts?.words == 6)
        project.reveal(project.outline[1])
        try await waitUntil { project.openPath == "chapters/a.tex" }
        #expect(project.headingLevel.title == "Section")
        await app.close()
    }

    /// Aa numbers the levels as the main file's class does, read whichever file is open.
    @Test(.timeLimit(.minutes(1)))
    func theClassIsTheMainFiles() async throws {
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

    /// After a jump that moves both the caret and the top line into new sections,
    /// the File Outline selects the caret's.
    @Test(.timeLimit(.minutes(1)))
    func theOutlineFollowsTheCaretAfterAJump() async throws {
        let text = ["A", "B", "C"].map { "\\section{\($0)}\n" + String(repeating: "x\n", count: 100) }.joined()
        let project = try await opened(text).project
        app.outlineCollapsed = false
        app.sidebarVisible = true
        let workspace = WorkspaceController(app: app, project: project, size: NSSize(width: 900, height: 600))
        let window = NSWindow(contentViewController: workspace)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        defer { workspace.close(); window.close() }
        func lists(_ view: NSView) -> [NSOutlineView] { [view as? NSOutlineView].compactMap(\.self) + view.subviews.flatMap(lists) }
        try await waitUntil { lists(workspace.view).last?.selectedRow == 0 }
        let outline = try #require(lists(workspace.view).last)

        // Centred two lines under C, the top line is in B at any font or window size.
        await project.open(try #require(project.openPath), line: 205)
        #expect(project.topHeading == project.outline[1].id)
        try await waitUntil { outline.selectedRow == 2 } state: { "row \(outline.selectedRow), top line \(project.topLine)" }
        await app.close()
    }

    /// Files another app adds, moves or deletes show in the sidebar's tree.
    @Test(.timeLimit(.minutes(1)))
    func anotherAppsFilesComeAndGo() async throws {
        let (project, folder) = try await opened()
        let paths = { Set(project.tree.flattened.map(\.path)) }

        try "x".write(to: folder.appending(path: "notes.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { paths().contains("notes.tex") }
        try files.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: false)
        try files.moveItem(at: folder.appending(path: "notes.tex"), to: folder.appending(path: "parts/notes.tex"))
        try await waitUntil(timeout: .seconds(5)) { paths().contains("parts/notes.tex") && !paths().contains("notes.tex") }
        try files.removeItem(at: folder.appending(path: "parts"))
        try await waitUntil(timeout: .seconds(5)) { !paths().contains("parts") }
        await app.close()
    }

    /// Deleted by another app, the open file closes; with unsaved edits it asks
    /// first, saving nothing meanwhile, and Save Again makes it again.
    @Test(.timeLimit(.minutes(1)))
    func anOpenFileDeletedElsewhere() async throws {
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
        // Past the autosave, which would have made the file again.
        try await Task.sleep(for: .seconds(1))
        #expect(!exists(notes))
        project.saveMissingFile()
        try await waitUntil(timeout: .seconds(5)) { exists(notes) }
        #expect(try String(contentsOf: notes, encoding: .utf8).contains("\\textbf{}"))
        await app.close()
    }

    /// A file dropped on the source opens: the project's own in the editor. One
    /// from elsewhere is refused: the sidebar copies files in.
    @Test(.timeLimit(.minutes(1)))
    func aDroppedFileOpens() async throws {
        let (project, folder) = try await opened()
        let notes = folder.appending(path: "notes.tex")
        try "notes".write(to: notes, atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { project.tree.flattened.contains { $0.path == "notes.tex" } }
        let drop = project.editor.textView.fileDrop

        let openNotes = try #require(drop(notes))
        openNotes()
        try await waitUntil(timeout: .seconds(5)) { project.openPath == "notes.tex" }
        #expect(drop(files.temporaryDirectory.appending(path: "outside.tex")) == nil)
        #expect(drop(files.temporaryDirectory.appending(path: "figure.png")) == nil)
        await app.close()
    }

    /// The Dock icon's menu lists the recent projects still in the library, newest first,
    /// as Pages and Xcode list their recent documents; one opens as from Home, its window
    /// brought forward. With none, the Dock shows only its own items.
    @Test(.timeLimit(.minutes(1)))
    func theDockMenuOpensARecentProject() async throws {
        let first = try await project("first").info, second = try await project("second").info
        await app.refresh()
        var shown = 0
        let dock = DockMenu(app: app) { shown += 1 }
        app.recentProjects = []
        #expect(dock.menu == nil)
        app.recentProjects = [second.id, "Gone", first.id]
        let menu = try #require(dock.menu)
        #expect(menu.items.map(\.title) == [second.name, first.name])
        menu.performActionForItem(at: 1)
        try await waitUntil(timeout: .seconds(5)) { app.project?.id == first.id && app.project?.initialLoadComplete == true }
        #expect(shown == 1 && app.recentProjects.first == first.id)
        #expect(NSApp.delegate?.responds(to: #selector(NSApplicationDelegate.applicationDockMenu(_:))) == true)
        await app.close()
    }

    /// New items are "untitled.tex" and "untitled folder", numbered past the names taken
    /// where they go as Finder numbers them, another app's too before the tree has them.
    /// A new file opens, without the keyboard, which goes to its name.
    @Test(.timeLimit(.minutes(1)))
    func newItemsTakeTheNextFreeName() async throws {
        let (project, folder) = try await opened()
        try "x".write(to: folder.appending(path: "untitled.tex"), atomically: false, encoding: .utf8)
        #expect(await project.createEntry(in: "", directory: false) == "untitled 2.tex")
        #expect(project.openPath == "untitled 2.tex" && project.editor.document?.text == "")
        #expect(await project.createEntry(in: "", directory: true) == "untitled folder")
        #expect(await project.createEntry(in: "", directory: true) == "untitled folder 2")
        #expect(await project.createEntry(in: "untitled folder", directory: false) == "untitled folder/untitled.tex")
        #expect(project.tree.flattened.contains { $0.path == "untitled folder/untitled.tex" })
        #expect(exists(folder.appending(path: "untitled folder 2")) && exists(folder.appending(path: "untitled folder/untitled.tex")))
        #expect(".latexmkrc".numbered(2) == ".latexmkrc 2")
        #expect(app.alert == nil)
        await app.close()
    }

    /// File › New File and New Folder make the item in the chosen folder, or the chosen
    /// file's, choose it and put its name in a field with the base name selected, as
    /// Finder's New Folder does: Return names it, Escape keeps it. The field stays through
    /// another app's change, and comes with the sidebar over a search.
    @Test(.timeLimit(.minutes(1)))
    func newItemsAreNamedInPlace() async throws {
        let (project, folder) = try await opened()
        app.sidebarVisible = true
        let workspace = WorkspaceController(app: app, project: project, size: NSSize(width: 1200, height: 760))
        let window = NSWindow(contentViewController: workspace)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        defer { workspace.close(); window.close() }
        let sidebar = workspace.sidebarItem.viewController.view
        func lists(_ view: NSView) -> [NSOutlineView] { [view as? NSOutlineView].compactMap(\.self) + view.subviews.flatMap(lists) }
        func files() throws -> NSOutlineView { try #require(lists(sidebar).first) }
        /// The name field's editor while it has the keyboard.
        func field() -> NSTextView? {
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  (editor.delegate as? NSTextField)?.isDescendant(of: sidebar) == true else { return nil }
            return editor
        }
        func key(_ characters: String, _ code: UInt16) throws {
            window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                           isARepeat: false, keyCode: code)))
        }
        /// The chosen row's item, from the tree as the list shows it.
        func chosen() throws -> String? {
            let list = try files()
            var paths: [String] = []
            func walk(_ nodes: [TreeNode]) {
                for node in nodes {
                    paths.append(node.path)
                    if let kids = node.children, list.isItemExpanded(list.item(atRow: paths.count)) { walk(kids) }
                }
            }
            walk(project.tree)
            return paths.indices.contains(list.selectedRow - 1) ? paths[list.selectedRow - 1] : nil
        }
        let state = { "keyboard \(String(describing: window.firstResponder)), open \(project.openPath ?? "-"), tree \(project.tree.flattened.map(\.path))" }
        try await waitUntil { (try? files().numberOfRows) == 2 }

        // The open file's folder, the top level; the file opens, the keyboard in its name.
        app.perform(.fileNew, on: project)
        try await waitUntil { field()?.string == "untitled.tex" } state: { state() }
        // The field's own selection, all of it, gives way to the base name's as it takes the keyboard.
        try await waitUntil { field()?.selectedRange() == NSRange(location: 0, length: 8) } state: { state() }
        #expect(project.openPath == "untitled.tex" && exists(folder.appending(path: "untitled.tex")))
        #expect(try chosen() == "untitled.tex")

        // Another app's file comes, and the field stays.
        try "x".write(to: folder.appending(path: "notes.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { project.tree.flattened.contains { $0.path == "notes.tex" } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(field()?.string == "untitled.tex")

        // Return names it; the list has the keyboard back, with it chosen.
        field()?.insertText("chapter", replacementRange: NSRange(location: NSNotFound, length: 0))
        try key("\r", 36)
        try await waitUntil(timeout: .seconds(5)) { project.openPath == "chapter.tex" && window.firstResponder === (try? files()) } state: { state() }
        #expect(exists(folder.appending(path: "chapter.tex")) && !exists(folder.appending(path: "untitled.tex")))
        try await waitUntil { (try? chosen()) == "chapter.tex" } state: { (try? chosen()) ?? "-" }

        // A folder, whose name is selected whole; Escape keeps it, chosen.
        app.perform(.fileNewFolder, on: project)
        try await waitUntil { field()?.string == "untitled folder" } state: { state() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(field()?.selectedRange() == NSRange(location: 0, length: 15))
        try key("\u{1b}", 53)
        try await waitUntil { field() == nil && window.firstResponder === (try? files()) } state: { state() }
        #expect(exists(folder.appending(path: "untitled folder")) && project.openPath == "chapter.tex")
        #expect(try chosen() == "untitled folder")

        // In the chosen folder, then in the chosen file's.
        app.perform(.fileNew, on: project)
        try await waitUntil { field()?.string == "untitled.tex" && project.openPath == "untitled folder/untitled.tex" } state: { state() }
        try key("\u{1b}", 53)
        try await waitUntil { field() == nil } state: { state() }
        app.perform(.fileNewFolder, on: project)
        try await waitUntil { field()?.string == "untitled folder" } state: { state() }
        #expect(exists(folder.appending(path: "untitled folder/untitled folder")))
        try key("\u{1b}", 53)
        try await waitUntil { field() == nil } state: { state() }

        // From a hidden sidebar over search results: the files show, with the field.
        app.sidebarVisible = false
        project.searchQuery = "chapter"
        try await waitUntil { workspace.sidebarItem.isCollapsed }
        app.perform(.fileNew, on: project)
        try await waitUntil { field()?.string == "untitled.tex" } state: { state() }
        #expect(app.sidebarVisible && project.searchQuery.isEmpty)
        #expect(project.openPath == "untitled folder/untitled folder/untitled.tex")
        #expect(app.alert == nil)
        await app.close()
    }

    /// A new item below the rows in sight scrolls into view to be named: the list
    /// makes only the rows it shows.
    @Test(.timeLimit(.minutes(1)))
    func aNewItemOutOfSightComesIntoView() async throws {
        let (project, folder) = try await opened()
        for number in 1...40 { try "".write(to: folder.appending(path: "a\(number).tex"), atomically: false, encoding: .utf8) }
        await project.reloadTree()
        app.sidebarVisible = true
        let workspace = WorkspaceController(app: app, project: project, size: NSSize(width: 1200, height: 760))
        let window = NSWindow(contentViewController: workspace)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        defer { workspace.close(); window.close() }
        func lists(_ view: NSView) -> [NSOutlineView] { [view as? NSOutlineView].compactMap(\.self) + view.subviews.flatMap(lists) }
        try await waitUntil { (lists(workspace.view).first?.numberOfRows ?? 0) == 42 }
        let files = try #require(lists(workspace.view).first)
        files.scrollRowToVisible(0)
        #expect(!files.rows(in: files.visibleRect).contains(41))

        app.perform(.fileNew, on: project)
        try await waitUntil {
            ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.isDescendant(of: files) == true
        } state: { "keyboard \(String(describing: window.firstResponder)), rows \(files.rows(in: files.visibleRect))" }
        let field = try #require((window.firstResponder as? NSTextView)?.delegate as? NSTextField)
        #expect(files.visibleRect.contains(field.convert(field.bounds, to: files)))
        await app.close()
    }

    /// Dropped on the tree, the project's own files move, as in Finder, but a
    /// folder not into itself; a file from elsewhere is copied in.
    @Test(.timeLimit(.minutes(1)))
    func treeDropsMoveTheProjectsFiles() async throws {
        let (project, folder) = try await opened()
        try files.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: false)
        try "notes".write(to: folder.appending(path: "notes.tex"), atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { project.tree.flattened.contains { $0.path == "notes.tex" } }
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

/// Move to Trash that Edit › Undo takes back, as Finder's does.
@MainActor
struct UndoableTrashTests {
    @Test(.timeLimit(.minutes(1)))
    func undoPutsATrashedItemBackAndRedoTrashesItAgain() async throws {
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
    @Test(.timeLimit(.minutes(1)))
    func anUndoDuringARedoWaitsForIt() async throws {
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
