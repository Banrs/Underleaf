import Foundation
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
    private func opened() async throws -> (project: ProjectModel, folder: URL) {
        let (info, folder) = try await project()
        await app.open(info.id)
        return (try #require(app.project), folder)
    }

    private func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path(percentEncoded: false)) }

    /// Two opens that overlap (the project restored at launch and an Open
    /// With import, or quick successive opens) leave the editor on the one
    /// opened last, never on the other's text.
    @Test(.timeLimit(.minutes(1)))
    func theLastOpenHasTheEditor() async throws {
        let first = try await project("first").info, second = try await project("second").info
        // Started in this order on the main actor, each waiting on the core
        // and the editor's page in turn.
        let opens = [Task { await app.open(first.id) }, Task { await app.open(second.id) }]
        for open in opens { await open.value }

        #expect(app.project?.id == second.id)
        let document = await app.project?.editor.document()
        #expect(document?.path == second.mainFile)
        #expect(document?.text == "second")
        await app.close()
    }

    /// A save writes the page's text to the file the page says it belongs to.
    @Test(.timeLimit(.minutes(1)))
    func anEditReachesTheDisk() async throws {
        let (project, folder) = try await opened()
        #expect(await project.editor.command(.bold))
        try await waitUntil { project.hasUnsavedText }
        #expect(await project.save())
        let saved = try String(contentsOf: folder.appending(path: try #require(project.openPath)), encoding: .utf8)
        #expect(saved.contains("\\textbf{}"))
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
        #expect(await project.editor.command(.bold))
        try await waitUntil(timeout: .seconds(5)) { project.missingFile == "notes.tex" }
        // Past the autosave, which would have made the file again.
        try await Task.sleep(for: .seconds(1))
        #expect(!exists(notes))
        project.saveMissingFile()
        try await waitUntil(timeout: .seconds(5)) { exists(notes) }
        #expect(try String(contentsOf: notes, encoding: .utf8).contains("\\textbf{}"))
        await app.close()
    }

    /// A file dropped on the source opens: the project's own in the editor, a
    /// .tex from elsewhere as the Dock opens it, and an image from elsewhere not at all.
    @Test(.timeLimit(.minutes(1)))
    func aDroppedFileOpens() async throws {
        let (project, folder) = try await opened()
        let notes = folder.appending(path: "notes.tex")
        try "notes".write(to: notes, atomically: false, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { project.tree.flattened.contains { $0.path == "notes.tex" } }
        let drop = project.editor.webView.fileDrop

        let openNotes = try #require(drop(notes))
        openNotes()
        try await waitUntil(timeout: .seconds(5)) { project.openPath == "notes.tex" }
        let outside = files.temporaryDirectory.appending(path: "outside.tex")
        let openOutside = try #require(drop(outside))
        openOutside()
        #expect(app.pendingImport == outside)
        app.pendingImport = nil
        #expect(drop(files.temporaryDirectory.appending(path: "figure.png")) == nil)
        await app.close()
    }
}
