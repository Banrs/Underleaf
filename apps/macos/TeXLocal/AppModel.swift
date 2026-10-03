import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DefaultsKey {
    static let sidebarVisible = "sidebarVisible"
    static let inspectorVisible = "inspectorVisible"
    static let autoCompile = "autoCompile"
    static let showWordCount = "showWordCount"
    static let recentProjects = "recentProjects"
    static let showPDF = "showPDF"
    static let openProject = "openProject"
    static let outlineCollapsed = "OutlineCollapsed"
}

/// An alert: a short, specific title and the detail in the message (HIG, Alerts).
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

/// What Save PDF As… or Export Project as ZIP… writes (`fileExporter`),
/// made only once the panel is done.
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
@Observable
final class AppModel {
    var projects: [ProjectInfo] = []
    var tex: TexStatus?
    private(set) var settingTeX = false
    var project: ProjectModel?
    var alert: AppAlert?

    // Requests from menu commands to the views that own the UI.
    var newProjectTemplate: ProjectTemplate?
    var prompt: Prompt?
    var openingProject = false
    var addingFiles = false
    /// An item Finder or the Dock handed the app, while the window asks
    /// before copying it in.
    var pendingImport: URL?
    var exporting: ExportFile?
    /// Bumped by Find in Project…, to focus the sidebar's search field.
    var searchFocusToken = 0
    /// The token lets the same action be asked for twice in a row.
    var pdfRequest: (action: PDFAction, token: Int)?
    private var pdfToken = 0

    // Stored here rather than as @AppStorage so the menus and models observe them.
    var sidebarVisible: Bool {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: DefaultsKey.sidebarVisible) }
    }
    /// The inspector: the project's settings and facts, the window's trailing column.
    var inspectorVisible: Bool {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: DefaultsKey.inspectorVisible) }
    }
    var autoCompile: Bool {
        didSet { UserDefaults.standard.set(autoCompile, forKey: DefaultsKey.autoCompile) }
    }
    var showWordCount: Bool {
        didSet { UserDefaults.standard.set(showWordCount, forKey: DefaultsKey.showWordCount) }
    }
    /// The PDF column. View › Show PDF and the toolbar keep the choice for later
    /// launches (`togglePDF`); a PDF command or Go to PDF Position shows it for now.
    var showPDF: Bool
    /// The sidebar's File Outline folded to its header.
    var outlineCollapsed: Bool {
        didSet { UserDefaults.standard.set(outlineCollapsed, forKey: DefaultsKey.outlineCollapsed) }
    }
    /// Set by the window: the menus act on the project only while its window
    /// is key, not behind Settings or a sheet.
    var mainWindowIsKey = false
    /// The project the menus act on.
    var commandProject: ProjectModel? { mainWindowIsKey ? project : nil }
    /// Offered by the list with the keyboard (`offersActions`).
    var chosenItem: ItemActions?
    /// Newest first, by id.
    var recentProjects: [String] {
        didSet { UserDefaults.standard.set(recentProjects, forKey: DefaultsKey.recentProjects) }
    }
    /// The recent projects still in the library. Filtered, not pruned on refresh:
    /// a library that lists empty (another TEXLOCAL_DATA, a missing folder) would wipe them.
    var recents: [ProjectInfo] {
        recentProjects.compactMap { id in projects.first { $0.id == id } }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.sidebarVisible: true, DefaultsKey.autoCompile: true,
                                     DefaultsKey.showWordCount: true, DefaultsKey.showPDF: true])
        sidebarVisible = defaults.bool(forKey: DefaultsKey.sidebarVisible)
        inspectorVisible = defaults.bool(forKey: DefaultsKey.inspectorVisible)
        autoCompile = defaults.bool(forKey: DefaultsKey.autoCompile)
        showWordCount = defaults.bool(forKey: DefaultsKey.showWordCount)
        showPDF = defaults.bool(forKey: DefaultsKey.showPDF)
        outlineCollapsed = defaults.bool(forKey: DefaultsKey.outlineCollapsed)
        recentProjects = defaults.stringArray(forKey: DefaultsKey.recentProjects) ?? []
        launchProject = defaults.string(forKey: DefaultsKey.openProject)
    }

    func newProject(_ template: String = "article") {
        newProjectTemplate = ProjectTemplate.all.first { $0.id == template }
    }

    func togglePDF() {
        showPDF.toggle()
        UserDefaults.standard.set(showPDF, forKey: DefaultsKey.showPDF)
    }

    /// Shows the PDF column too, so the action happens now rather than when
    /// the column next appears. The workspace takes each request once.
    func requestPDF(_ action: PDFAction) {
        showPDF = true
        pdfToken += 1
        pdfRequest = (action, pdfToken)
    }

    private let core = Core.shared
    /// The latest TeX status read; a TeX folder choice cancels it.
    @ObservationIgnored private var texCheck: Task<Void, Never>?

    func refresh() async {
        do {
            projects = try await core.call("list_projects", as: [ProjectInfo].self)
        } catch {
            alert = AppAlert("Couldn’t Load Your Projects", error)
        }
        await refreshTeXStatus()
    }

    /// `status` searches the disk for latexmk. Not while a TeX folder is being chosen.
    func refreshTeXStatus() async {
        guard !settingTeX else { return }
        texCheck?.cancel()
        let check = Task {
            let status = try? await core.call("status", as: TexStatus.self)
            if !Task.isCancelled, let status { tex = status }
        }
        texCheck = check
        await check.value
    }

    /// Nil finds TeX automatically. The core refuses a folder without latexmk.
    /// Settings turns its buttons off meanwhile.
    func setTeXFolder(_ path: String?) async throws {
        settingTeX = true
        texCheck?.cancel()
        defer { settingTeX = false }
        do {
            tex = try await core.call("set_tex_dir", ["dir": path ?? NSNull()], as: TexStatus.self)
        } catch {
            // A status read started before this choice was discarded. Refresh
            // after the check ends, even if the chosen folder was refused.
            Task { await refreshTeXStatus() }
            throw error
        }
    }

    func create(name: String, template: String) async throws {
        let info = try await core.call("create_project", ["name": name, "template": template], as: ProjectInfo.self)
        await refresh()
        // Not awaited: the sheet goes as the project opens, not after its first build.
        Task { await open(info.id) }
    }

    static let openableTypes: [UTType] = [.folder, .zip] + [UTType(filenameExtension: "tex")].compactMap(\.self)

    static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var directory: ObjCBool = false
        if url.hasDirectoryPath || (FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &directory)
                                   && directory.boolValue) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return openableTypes.contains { type.conforms(to: $0) }
    }

    /// Copies a folder, .tex file (with its folder) or .zip into the library and opens it, or
    /// with `open` off only lists it. The core removes a project it couldn't finish, so a bad
    /// zip leaves none.
    func importProject(from url: URL, open: Bool = true) async {
        do {
            let info = try await core.call("import_project", ["src": url.path], as: ProjectInfo.self)
            await refresh()
            if open { await self.open(info.id) }
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

    /// Without asking, as in Finder: the Trash gives the item back (HIG, Alerts).
    func delete(_ project: ProjectInfo) async {
        do {
            try await core.perform("delete_project", ["id": project.id])
            recentProjects.removeAll { $0 == project.id }
        } catch {
            alert = AppAlert("Couldn’t Move “\(project.name)” to the Trash", error)
        }
        await refresh()
    }

    func revealProject(_ project: ProjectInfo) {
        Task {
            guard let root = try? await core.call("project_root", ["id": project.id], as: String.self) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
        }
    }

    /// Bumped by each `open` and `close`, so only the latest carries on: the
    /// restored project and an Open With import can overlap at launch.
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var opensUnderWay = 0
    /// True while a project loads, before `project` may name it.
    var isOpening: Bool { opensUnderWay > 0 }

    /// `--args -openProject <id>`: the argument domain holds it for this run only.
    @ObservationIgnored private var launchProject: String?

    func takeLaunchProject() -> String? {
        defer { launchProject = nil }
        return launchProject
    }

    /// Saves and leaves the open project first. `project` goes straight from
    /// one to the next, never nil between, so the window keeps the workspace.
    func open(_ id: String, restoring saved: SavedWorkspace? = nil) async {
        openGeneration += 1
        let generation = openGeneration
        guard project?.id != id else { return }
        opensUnderWay += 1
        defer { opensUnderWay -= 1 }
        guard await leave(generation) else { return }
        dropRequests()
        recentProjects = Array(([id] + recentProjects.filter { $0 != id })
            .prefix(NSDocumentController.shared.maximumRecentDocumentCount))
        let model = ProjectModel(id: id, app: self)
        project = model
        await model.load(restoring: saved?.project == id ? saved : nil)
    }

    /// False, staying, when the save fails: the editor holds the only copy.
    @discardableResult
    func close() async -> Bool {
        openGeneration += 1
        guard project != nil else { return true }
        // False too when an open took over while this saved: its project stays.
        guard await leave(openGeneration) else { return false }
        project = nil
        dropRequests()
        await refresh()
        return true
    }

    /// The project's own requests, which the next project mustn't present.
    private func dropRequests() {
        pdfRequest = nil
        prompt = nil
        addingFiles = false
        exporting = nil
    }

    /// Unless a later open or close took over while this saved; that one leaves it.
    private func leave(_ generation: Int) async -> Bool {
        guard let project else { return true }
        guard await project.flush(), generation == openGeneration else { return false }
        project.close()
        return true
    }
}
