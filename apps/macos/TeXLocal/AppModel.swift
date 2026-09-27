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

/// A file Save PDF As… or Export Project as ZIP… writes where the save
/// panel says (`fileExporter`): made once the panel is done, then copied
/// there by the system.
struct ExportFile: Transferable {
    let name: String
    let type: UTType
    let make: @MainActor @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { SentTransferredFile(try await $0.make()) }
            .suggestedFileName(\.name)
        FileRepresentation(exportedContentType: .zip) { SentTransferredFile(try await $0.make()) }
            .suggestedFileName(\.name)
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
    /// The new-project sheet, on the template it starts with.
    var newProjectTemplate: ProjectTemplate?
    var prompt: Prompt?
    /// File › Open…'s panel (the gallery's), Add Files…' (WorkspaceView).
    var openingProject = false
    var addingFiles = false
    /// The app is quitting: the project window's close is no reason to
    /// leave the project.
    @ObservationIgnored var quitting = false
    /// Something Finder's Open With or the Dock icon handed the app, while
    /// the gallery asks before copying it in.
    var pendingImport: URL?
    /// Save PDF As… or Export Project as ZIP…, while its panel shows.
    var exporting: ExportFile?
    var searchFocusToken = 0
    var pdfRequest: (action: PDFAction, token: Int)?
    private var pdfToken = 0

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
    /// File › Open Recent: the projects last opened, newest first, by id.
    var recentProjects = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [] {
        didSet { UserDefaults.standard.set(recentProjects, forKey: "recentProjects") }
    }
    /// How far the project window's rounded corners reach into its detail
    /// (SwiftUI's `containerCornerInsets`), for the views inside the split's
    /// panes, which SwiftUI gives none: each pane is hosted on its own.
    var windowCorners = RectangleCornerInsets()

    /// ⌘N in the gallery, or a template's card.
    func newProject(_ template: String = "article") {
        newProjectTemplate = ProjectTemplate.all.first { $0.id == template }
    }

    /// Ask the PDF pane for something, showing the pane so it is done now
    /// rather than whenever the pane next appears. Find in PDF is a bar
    /// over the pages that leaves the build panel open.
    func requestPDF(_ action: PDFAction) {
        project?.showPDF = true
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

    /// While TeX is missing, look again now and then.
    func watchForTeX() async {
        while !(tex?.available ?? true), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            tex = try? await core.call("status", as: TexStatus.self)
        }
    }

    /// Settings' TeX folder: one the user chose, or nil to find TeX
    /// automatically. The core refuses a folder without latexmk.
    func setTeXFolder(_ path: String?) async throws {
        tex = try await core.call("set_tex_dir", ["dir": path ?? NSNull()], as: TexStatus.self)
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

    /// What File › Open… opens: a folder, a .tex file or a .zip.
    static let openableTypes: [UTType] = [.folder, .zip] + [UTType(filenameExtension: "tex")].compactMap(\.self)

    /// Whether Open… takes an item dropped or handed to the app.
    static func canOpen(_ url: URL) -> Bool {
        url.isFileURL && (url.hasDirectoryPath || ["tex", "zip"].contains(url.pathExtension.lowercased()))
    }

    /// File › Open…: a folder, a .tex file or a .zip from anywhere, made a
    /// project in the library and opened. The original stays where it is.
    /// The core copies it in (off the main actor, as every core call runs)
    /// and removes a project it couldn't finish, so a bad zip leaves none.
    func importProject(from url: URL) async {
        do {
            let info = try await core.call("import_project", ["src": url.path], as: ProjectInfo.self)
            await refresh()
            await open(info.id)
        } catch {
            alert = AppAlert("Couldn’t Open “\(url.lastPathComponent)”", error)
        }
    }

    func rename(_ project: ProjectInfo, to name: String) async {
        do {
            let renamed = try await core.call("rename_project", ["id": project.id, "name": name], as: ProjectInfo.self)
            recentProjects = recentProjects.map { $0 == project.id ? renamed.id : $0 }
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
            guard let root = try? await core.call("project_root", ["id": project.id], as: String.self) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
        }
    }

    /// Bumped by each `open` and `close`, so only the latest carries on: at
    /// launch the restored project and an Open With import can overlap, as
    /// can quick successive opens.
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var opensUnderWay = 0
    /// A project is on its way in, though `project` may not name it yet.
    var isOpening: Bool { opensUnderWay > 0 }

    /// `open TeXLocal.app --args -openProject <id>` opens a project at
    /// launch; launch arguments land in UserDefaults' argument domain for
    /// this run only. Taken once, by whichever window asks first.
    @ObservationIgnored private var launchProject = UserDefaults.standard.string(forKey: "openProject")

    func takeLaunchProject() -> String? {
        defer { launchProject = nil }
        return launchProject
    }

    /// Open a project; reopening at launch, where it was left. The open
    /// project is saved and left first; `project` goes straight from one to
    /// the other, never nil between, so its window stays.
    func open(_ id: String, restoring saved: SavedWorkspace? = nil) async {
        openGeneration += 1
        let generation = openGeneration
        guard project?.id != id else { return }
        opensUnderWay += 1
        defer { opensUnderWay -= 1 }
        guard await leave(generation) else { return }
        recentProjects = [id] + recentProjects.filter { $0 != id }.prefix(9)
        let model = ProjectModel(id: id, editor: editor, app: self)
        project = model
        await model.load(restoring: saved?.project == id ? saved : nil)
    }

    /// Save, then leave the project. Returns false — and stays — when the save
    /// fails, rather than dropping the only copy of the edits.
    @discardableResult
    func close() async -> Bool {
        openGeneration += 1
        guard project != nil else { return true }
        // False too when an open took over while this saved: its project stays.
        guard await leave(openGeneration) else { return false }
        project = nil
        pdfRequest = nil
        await refresh()
        return true
    }

    /// Save the open project and stop it, unless a later open or close has
    /// taken over while it saved: that one leaves it instead.
    private func leave(_ generation: Int) async -> Bool {
        guard let project else { return true }
        guard await project.flush(), generation == openGeneration else { return false }
        project.close()
        return true
    }
}

