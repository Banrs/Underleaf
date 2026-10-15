import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DefaultsKey {
    static let autoCompile = "autoCompile"
    static let showWordCount = "showWordCount"
    static let recentProjects = "recentProjects"
    static let showPDF = "showPDF"
    static let openProject = "openProject"
    static let outlineCollapsed = "OutlineCollapsed"
    static let syncAfterCompile = "syncAfterCompile"
    static let newProjectTemplate = "newProjectTemplate"
    static let newProjectEngine = "newProjectEngine"
    static let settingsPane = "settingsPane"
}

enum SideColumn { case sidebar, inspector }

struct AppAlert: Sendable {
    let title: String
    let message: String

    init(_ title: String, _ message: String) {
        self.title = title
        self.message = message
    }

    init(_ title: String, _ error: any Error) {
        self.init(title, error.localizedDescription)
    }
}

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

@Observable
final class AppModel {
    var projects: [ProjectInfo] = []
    private(set) var projectsLoaded = false
    var tex: TexStatus? {
        didSet { project?.optionsChanged() }
    }
    private(set) var settingTeX = false
    var project: ProjectModel?
    var alert: AppAlert?
    private(set) var libraryProblem: AppAlert? = Core.shared.isOpen ? nil
        : AppAlert("Couldn’t Open the Projects Folder", Core.libraryAdvice)

    var newProjectTemplate: ProjectTemplate?
    var prompt: Prompt?
    var newEntry: NewEntry?
    var openingProject = false
    var addingFiles = false
    var exporting: ExportFile?
    var searchFocusToken = 0
    @ObservationIgnored var performPDF: ((PDFAction) -> Void)?

    /// The side columns as the workspace's split has them, which keeps them across launches
    /// (`WorkspaceController`): for the menus' Show and Hide.
    var sidebarShown = true
    var inspectorShown = false
    /// The workspace's, which opens or shuts a side column.
    @ObservationIgnored var showSideColumn: ((SideColumn, Bool) -> Void)?

    // Stored here rather than as @AppStorage so the menus and models observe them.
    var autoCompile: Bool {
        didSet {
            UserDefaults.standard.set(autoCompile, forKey: DefaultsKey.autoCompile)
            project?.optionsChanged()
        }
    }
    var showWordCount: Bool {
        didSet { UserDefaults.standard.set(showWordCount, forKey: DefaultsKey.showWordCount) }
    }
    /// View › Show PDF and the toolbar keep the choice for later launches; a PDF command or Go to PDF Position shows it for now.
    var showPDF: Bool
    var outlineCollapsed: Bool {
        didSet { UserDefaults.standard.set(outlineCollapsed, forKey: DefaultsKey.outlineCollapsed) }
    }
    /// The menus act on the project only while its window is key, not behind Settings or a sheet.
    var mainWindowIsKey = false
    var commandProject: ProjectModel? { mainWindowIsKey && project?.closed != true ? project : nil }
    var chosenItem: ItemActions?
    var recentProjects: [String] {
        didSet { UserDefaults.standard.set(recentProjects, forKey: DefaultsKey.recentProjects) }
    }
    /// Filtered, not pruned on refresh: a library that lists empty (another TEXLOCAL_DATA, a missing folder) would wipe them.
    var recents: [ProjectInfo] {
        recentProjects.compactMap { id in projects.first { $0.id == id } }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.autoCompile: true, DefaultsKey.showWordCount: true, DefaultsKey.showPDF: true])
        autoCompile = defaults.bool(forKey: DefaultsKey.autoCompile)
        showWordCount = defaults.bool(forKey: DefaultsKey.showWordCount)
        showPDF = defaults.bool(forKey: DefaultsKey.showPDF)
        outlineCollapsed = defaults.bool(forKey: DefaultsKey.outlineCollapsed)
        recentProjects = defaults.stringArray(forKey: DefaultsKey.recentProjects) ?? []
        launchProject = defaults.string(forKey: DefaultsKey.openProject)
    }

    func newProject(_ template: ProjectTemplate? = nil) {
        guard libraryProblem == nil else { return }
        newProjectTemplate = template ?? UserDefaults.standard.string(forKey: DefaultsKey.newProjectTemplate)
            .flatMap(ProjectTemplate.init(rawValue:)) ?? .standard
    }

    func togglePDF() {
        showPDF.toggle()
        UserDefaults.standard.set(showPDF, forKey: DefaultsKey.showPDF)
    }

    func requestPDF(_ action: PDFAction) {
        showPDF = true
        performPDF?(action)
    }

    private let core = Core.shared
    @ObservationIgnored private var texCheck: Task<Void, Never>?

    func retryLibrary() async {
        core.reopen()
        if core.isOpen { libraryProblem = nil }
        await refresh()
        await refreshTeXStatus()
    }

    /// TeX is read apart (`refreshTeXStatus`), as the probe starts a process.
    func refresh() async {
        guard core.isOpen else { return }
        do {
            projects = try await core.call("list_projects", as: [ProjectInfo].self)
            libraryProblem = nil
        } catch {
            libraryProblem = AppAlert("Couldn’t Load Projects", error)
        }
        projectsLoaded = true
    }

    /// `status` searches the disk for latexmk, so not while a TeX folder is being chosen.
    func refreshTeXStatus() async {
        guard !settingTeX else { return }
        await restart(&texCheck) { [self] in
            let status = try? await core.call("status", as: TexStatus.self)
            if !Task.isCancelled, let status { tex = status }
        }.value
    }

    func setTeXFolder(_ path: String?, texpresso: Bool) async throws {
        settingTeX = true
        texCheck?.cancel()
        defer { settingTeX = false }
        do {
            tex = try await core.call(texpresso ? "set_texpresso_dir" : "set_tex_dir", ["dir": path ?? NSNull()],
                                      as: TexStatus.self)
        } catch {
            // A status read started before this choice was discarded: refresh after the check ends, even if the chosen folder was refused.
            Task { await refreshTeXStatus() }
            throw error
        }
    }

    func create(name: String, template: ProjectTemplate) async throws {
        let info = try await core.call("create_project", ["name": name, "template": template.rawValue], as: ProjectInfo.self)
        // The project stands if this fails, and opens under the alert that says so.
        if let engine = UserDefaults.standard.string(forKey: DefaultsKey.newProjectEngine).flatMap(TeXEngine.init(rawValue:)),
           engine != .pdflatex {
            _ = await alerting("Couldn’t Set the Engine for “\(info.name)”") {
                try await core.call("set_settings", ["id": info.id, "patch": ["engine": engine.rawValue]], as: ProjectSettings.self)
            }
        }
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

    /// Without asking, as the copy goes to the Trash like any project. The core removes a project it couldn't finish, so a bad zip leaves none.
    func importProject(from url: URL, open: Bool = true) async {
        if await isInLibrary(url, open: open) { return }
        // A second Return while it copies would make a second project.
        let name = url.lastPathComponent
        guard importing.insert(url).inserted else { return }
        opening.append(name)
        defer {
            importing.remove(url)
            stopOpening(name)
        }
        guard let info = await alerting("Couldn’t Open “\(name)”", {
            try await core.call("import_project", ["src": url.path], as: ProjectInfo.self)
        }) else { return }
        await refresh()
        if open { await self.open(info.id) }
    }

    private func isInLibrary(_ url: URL, open: Bool) async -> Bool {
        guard let located = try? await core.answer("locate", ["path": url.path(percentEncoded: false)], as: Located.self) else { return false }
        let id = located.id
        if !projects.contains(where: { $0.id == id }) { await refresh() }
        guard projects.contains(where: { $0.id == id }) else { return false }
        guard open else { return true }
        await self.open(id)
        if !located.path.isEmpty, let project, project.id == id, project.tree.node(at: located.path)?.isDirectory == false {
            await project.open(located.path)
        }
        return true
    }

    func rename(_ project: ProjectInfo, to name: String) async {
        if let renamed = await renameProject(project.id, shown: project.name, to: name) {
            registerRenameUndo(current: (renamed.id, renamed.name), previous: (project.id, project.name))
        }
        await refresh()
    }

    private func renameProject(_ id: String, shown: String, to name: String) async -> ProjectInfo? {
        await alerting("Couldn’t Rename “\(shown)”") {
            let renamed = try await core.call("rename_project", ["id": id, "name": name], as: ProjectInfo.self)
            recentProjects = recentProjects.map { $0 == id ? renamed.id : $0 }
            ProjectModel.moveSidebarState(from: id, to: renamed.id)
            return renamed
        }
    }

    /// The Redo is registered as the Undo starts, as `UndoableTrash`'s are; one that fails takes it away. The closures hold the model, as the manager doesn't.
    private func registerRenameUndo(current: (id: String, name: String), previous: (id: String, name: String)) {
        guard let undo = undoManager else { return }
        undo.registerUndo(withTarget: self) { _ in
            self.registerRenameUndo(current: previous, previous: current)
            Task {
                if await self.renameProject(current.id, shown: current.name, to: previous.name) == nil {
                    self.undoManager?.removeAllActions(withTarget: self)
                }
                await self.refresh()
            }
        }
        undo.setActionName(String(localized: "Rename"))
    }

    var undoManager: UndoManager? { undoSource() }
    @ObservationIgnored var undoSource: () -> UndoManager? = { NSApp.mainWindow?.undoManager }

    func delete(_ project: ProjectInfo) async {
        let failure = "Couldn’t Move “\(project.name)” to the Trash"
        guard let root = await folder(of: project, orAlert: failure) else { return }
        let item = UndoableTrash(
            original: root, name: project.name, undoManager: undoManager,
            trash: { [weak self] item in
                do {
                    try item.recycle()
                    self?.recentProjects.removeAll { $0 == project.id }
                    ProjectModel.forgetSidebarState(of: project.id)
                    return true
                } catch {
                    self?.alert = AppAlert(failure, error)
                    return false
                }
            },
            changed: { [weak self] in await self?.refresh() },
            failed: { [weak self] title, error in self?.alert = AppAlert(title, error) })
        await item.moveToTrash()
        await refresh()
    }

    func revealProject(_ project: ProjectInfo) {
        Task {
            guard let root = await folder(of: project, orAlert: "Couldn’t Show “\(project.name)” in Finder") else { return }
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }

    private func folder(of project: ProjectInfo, orAlert title: String) async -> URL? {
        await alerting(title) { URL(fileURLWithPath: try await core.call("project_root", ["id": project.id], as: String.self)) }
    }

    private func alerting<T>(_ title: String, _ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch {
            alert = AppAlert(title, error)
            return nil
        }
    }

    /// Only the latest carries on: the restored project and an Open With import can overlap at launch.
    @ObservationIgnored private var openGeneration = 0
    private(set) var opening: [String] = []
    var isOpening: Bool { !opening.isEmpty }
    @ObservationIgnored private var importing = Set<URL>()

    private func stopOpening(_ name: String) {
        if let place = opening.firstIndex(of: name) { opening.remove(at: place) }
    }

    @ObservationIgnored private var launchProject: String?

    func takeLaunchProject() -> String? {
        defer { launchProject = nil }
        return launchProject
    }

    /// `project` goes straight from one to the next, never nil between, so the window keeps the workspace.
    func open(_ id: String, restoring saved: SavedWorkspace? = nil) async {
        openGeneration += 1
        let generation = openGeneration
        guard project?.id != id || project?.closed == true else { return }
        opening.append(id)
        defer { stopOpening(id) }
        guard await leave(generation) else { return }
        dropRequests()
        // Home's renames and moves to the Trash can't be undone under a project: Undo from the sidebar could rename the open project's folder under it.
        undoManager?.removeAllActions()
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

    private func dropRequests() {
        prompt = nil
        newEntry = nil
        addingFiles = false
        exporting = nil
    }

    private func leave(_ generation: Int) async -> Bool {
        guard let project else { return true }
        if !project.closed {
            guard await project.save(), generation == openGeneration else { return false }
            project.close()
        }
        // Its session's Live Preview stopped before another model can start the project's.
        await project.waitUntilClosed()
        return generation == openGeneration
    }
}
