import AppKit
import SwiftUI

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

    /// Select the project's folder in Finder: its main file's path, less
    /// the main file's own components.
    func revealProject(_ project: ProjectInfo) {
        Task {
            guard let abs = try? await core.call("raw_path", ["id": project.id, "path": project.mainFile], as: String.self)
            else { return }
            var root = URL(fileURLWithPath: abs)
            for _ in project.mainFile.split(separator: "/") { root.deleteLastPathComponent() }
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

