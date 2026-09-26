import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What went wrong, as the HIG shapes an alert: a short, specific title
/// (at most two lines) and the detail in the message.
struct AppAlert: Sendable {
    let title: String
    let message: String

    init(_ title: String, _ message: String) {
        self.title = title
        self.message = message
    }

    init(_ title: String, _ error: Error) {
        self.init(title, error.localizedDescription)
    }
}

/// The library: projects on disk, TeX availability, and the open project.
@MainActor @Observable
final class AppModel {
    var projects: [ProjectInfo] = []
    var tex: TexStatus?
    var project: ProjectModel?
    var alert: AppAlert?

    // Requests from commands to the views that own the matching UI.
    var showNewProject = false
    /// The template the new-project sheet starts on: the card chosen.
    var newProjectTemplate = "article"
    var prompt: Prompt?
    var searchFocusToken = 0
    var pdfRequest: (action: PDFAction, token: Int)?
    private var pdfToken = 0

    init() {
        // The pane bars' Large size (Settings › General › Toolbar Size) is
        // gone: the bars have the one, standard size.
        UserDefaults.standard.removeObject(forKey: "paneBarSize")
    }

    // Settings the menus and models read, remembered across launches; held
    // here so they are observed. Settings the views alone read are
    // @AppStorage where they are used.
    var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }
    var autoCompile = UserDefaults.standard.object(forKey: "autoCompile") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCompile, forKey: "autoCompile") }
    }
    /// The status bar's word and line counts (View › Show Word Count).
    var showWordCount = UserDefaults.standard.object(forKey: "showWordCount") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showWordCount, forKey: "showWordCount") }
    }
    var showInspector = UserDefaults.standard.bool(forKey: "showInspector") {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }

    /// ⌘N on the home screen, or a template's card.
    func newProject(_ template: String = "article") {
        newProjectTemplate = template
        showNewProject = true
    }

    /// Ask the PDF pane for something, showing the pane so it is done now
    /// rather than whenever the pane next appears. Find floats over the
    /// pages, so it leaves the build panel open.
    func requestPDF(_ action: PDFAction) {
        project?.showPDF = true
        if action != .find { project?.showLogs = false }
        pdfToken += 1
        pdfRequest = (action, pdfToken)
    }

    /// One editor for the app's lifetime, handed from project to project.
    let editor = EditorBridge()

    private let core = Core.shared

    func refresh() async {
        do {
            projects = try await core.call("list_projects", as: [ProjectInfo].self)
                .sorted { $0.mtime > $1.mtime }
        } catch {
            alert = AppAlert("Couldn’t Load Your Projects", error)
        }
        tex = try? await core.call("status", as: TexStatus.self)
    }

    /// While TeX is missing, look again now and then so installing it takes
    /// effect without a restart of this screen.
    func watchForTeX() async {
        while !(tex?.available ?? true), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            tex = try? await core.call("status", as: TexStatus.self)
        }
    }

    func create(name: String, template: String) async {
        do {
            let info = try await core.call("create_project", ["name": name, "template": template], as: ProjectInfo.self)
            await refresh()
            await open(info.id)
        } catch {
            alert = AppAlert("Couldn’t Create “\(name)”", error)
        }
    }

    /// File › Open…: a folder, a .tex file or a .zip from anywhere, made a
    /// project in the library and opened. The original stays where it is.
    func chooseProjectToOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.folder, .zip] + [UTType(filenameExtension: "tex")].compactMap(\.self)
        panel.prompt = "Open"
        panel.message = "Choose a project folder, a .tex file or a .zip. TeXLocal copies it into your projects."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importProject(from: url) }
    }

    func importProject(from url: URL) async {
        let base = url.deletingPathExtension().lastPathComponent
        var made: ProjectInfo?
        var failure: Error?
        // A taken name gets a number, as Finder's copies do.
        for n in 1...50 where made == nil {
            do {
                made = try await core.call("create_project", ["name": n == 1 ? base : "\(base) \(n)", "template": "blank"],
                                           as: ProjectInfo.self)
            } catch {
                failure = error
            }
        }
        guard let info = made else {
            alert = AppAlert("Couldn’t Open “\(url.lastPathComponent)”", failure ?? CoreError(message: "No free name", status: 500))
            return
        }
        do {
            guard let root = await root(of: info) else { throw CoreError(message: "The new project has no folder", status: 500) }
            let (items, cleanup) = try Self.contents(of: url)
            defer { cleanup() }
            let fm = FileManager.default
            let isTeX = { (item: URL) in item.pathExtension.lowercased() == "tex" }
            // The template's main.tex gives way to what came in, if any TeX did.
            if items.contains(where: isTeX) { try? fm.removeItem(at: root.appendingPathComponent("main.tex")) }
            for item in items {
                let dest = root.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: item, to: dest) }
            }
            // The main file: the chosen .tex, else main.tex, else the first
            // that starts a document.
            let names = items.filter(isTeX).map(\.lastPathComponent).sorted()
            let main = isTeX(url) ? url.lastPathComponent
                : names.first { $0.lowercased() == "main.tex" }
                ?? names.first { (try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8))?
                    .contains("\\documentclass") == true }
                ?? names.first
            if let main, main != info.mainFile {
                try await core.perform("set_settings", ["id": info.id, "patch": ["mainFile": main]])
            }
        } catch {
            alert = AppAlert("Couldn’t Copy All of “\(url.lastPathComponent)”", error)
        }
        await refresh()
        await open(info.id)
    }

    /// What a chosen item brings: a folder's visible contents, a zip's
    /// (its one top folder's, if it has one), or the file itself; and how
    /// to tidy up after copying them.
    private static func contents(of url: URL) throws -> ([URL], () -> Void) {
        let fm = FileManager.default
        let visible = { (dir: URL) in
            try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { $0.lastPathComponent != "__MACOSX" }
        }
        if url.hasDirectoryPath { return (try visible(url), {}) }
        guard url.pathExtension.lowercased() == "zip" else { return ([url], {}) }
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup: () -> Void = { try? fm.removeItem(at: temp) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, temp.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            cleanup()
            throw CoreError(message: "The zip couldn’t be opened", status: 500)
        }
        var items = try visible(temp)
        if items.count == 1, items[0].hasDirectoryPath { items = try visible(items[0]) }
        return (items, cleanup)
    }

    /// A project's folder: its main file's path, less the main file's own
    /// components.
    private func root(of project: ProjectInfo) async -> URL? {
        guard let abs = try? await core.call("raw_path", ["id": project.id, "path": project.mainFile], as: String.self)
        else { return nil }
        var root = URL(fileURLWithPath: abs)
        for _ in project.mainFile.split(separator: "/") { root.deleteLastPathComponent() }
        return root
    }

    func rename(_ project: ProjectInfo, to name: String) async {
        do {
            _ = try await core.call("rename_project", ["id": project.id, "name": name], as: ProjectInfo.self)
        } catch {
            alert = AppAlert("Couldn’t Rename “\(project.name)”", error)
        }
        await refresh()
    }

    func delete(_ project: ProjectInfo) async {
        do {
            try await core.perform("delete_project", ["id": project.id])
        } catch {
            alert = AppAlert("Couldn’t Move “\(project.name)” to the Trash", error)
        }
        await refresh()
    }

    /// Select the project's folder in Finder.
    func revealProject(_ project: ProjectInfo) {
        Task {
            guard let root = await root(of: project) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }

    func open(_ id: String) async {
        guard await close() else { return }
        let model = ProjectModel(id: id, editor: editor, app: self)
        project = model
        await model.load()
    }

    /// Save, then leave the project. Returns false — and stays — when the save
    /// fails, rather than dropping the only copy of the edits.
    @discardableResult
    func close() async -> Bool {
        guard let project else { return true }
        guard await project.flush() else { return false }
        project.close()
        self.project = nil
        pdfRequest = nil
        await refresh()
        return true
    }
}

