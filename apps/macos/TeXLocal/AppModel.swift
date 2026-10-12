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
    static let syncAfterCompile = "syncAfterCompile"
    static let newProjectTemplate = "newProjectTemplate"
    static let newProjectEngine = "newProjectEngine"
    static let settingsPane = "settingsPane"
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

/// What Export as PDF… or Export Project as ZIP… writes (`fileExporter`),
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
    /// The first list has come: Home says there are no projects only after it.
    private(set) var projectsLoaded = false
    var tex: TexStatus?
    private(set) var settingTeX = false
    var project: ProjectModel?
    var alert: AppAlert?
    /// Why the library can't be listed, for Home to say in place of its list: no alert as the app starts.
    private(set) var libraryProblem: AppAlert? = Core.shared.isOpen ? nil
        : AppAlert("Couldn’t Open the Projects Folder", Core.libraryAdvice)

    // Requests from menu commands to the views that own the UI.
    var newProjectTemplate: ProjectTemplate?
    var prompt: Prompt?
    var newEntry: NewEntry?
    var openingProject = false
    var addingFiles = false
    var exporting: ExportFile?
    /// Bumped by Find in Project…, to focus the sidebar's search field.
    var searchFocusToken = 0
    /// The workspace's, which shows the PDF column and then acts on it.
    @ObservationIgnored var performPDF: ((PDFAction) -> Void)?

    // Stored here rather than as @AppStorage so the menus and models observe them.
    var sidebarVisible: Bool {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: DefaultsKey.sidebarVisible) }
    }
    /// The inspector: the project's settings and facts, the window's trailing column.
    var inspectorVisible: Bool {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: DefaultsKey.inspectorVisible) }
    }
    /// Folded by a window too narrow for them, which brings them back as it widens: not hidden,
    /// and not saved (`sidebarShown`, `inspectorShown`).
    var sidebarFolded = false
    var inspectorFolded = false
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
    var commandProject: ProjectModel? { mainWindowIsKey && project?.closed != true ? project : nil }
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

    /// Without a template, the one Settings names for new projects.
    func newProject(_ template: String? = nil) {
        guard libraryProblem == nil else { return }
        let template = template ?? UserDefaults.standard.string(forKey: DefaultsKey.newProjectTemplate)
        newProjectTemplate = ProjectTemplate.all.first { $0.id == template } ?? ProjectTemplate.all.first { $0.id == "article" }
    }

    func togglePDF() {
        showPDF.toggle()
        UserDefaults.standard.set(showPDF, forKey: DefaultsKey.showPDF)
    }

    /// Shows the PDF column too, so the action happens now rather than when
    /// the column next appears.
    func requestPDF(_ action: PDFAction) {
        showPDF = true
        performPDF?(action)
    }

    private let core = Core.shared
    /// The latest TeX status read; a TeX folder choice cancels it.
    @ObservationIgnored private var texCheck: Task<Void, Never>?

    /// Home's Try Again: opens the library folder again if need be, then lists it.
    func retryLibrary() async {
        core.reopen()
        if core.isOpen { libraryProblem = nil }
        await refresh()
    }

    func refresh() async {
        guard core.isOpen else { return }
        do {
            projects = try await core.call("list_projects", as: [ProjectInfo].self)
            libraryProblem = nil
        } catch {
            libraryProblem = AppAlert("Couldn’t Load Projects", error)
        }
        projectsLoaded = true
        await refreshTeXStatus()
    }

    /// `status` searches the disk for latexmk. Not while a TeX folder is being chosen.
    func refreshTeXStatus() async {
        guard !settingTeX else { return }
        await restart(&texCheck) { [self] in
            let status = try? await core.call("status", as: TexStatus.self)
            if !Task.isCancelled, let status { tex = status }
        }.value
    }

    /// Nil finds TeX, or TeXpresso, automatically. The core refuses a folder without
    /// latexmk, or texpresso. Settings turns its buttons off meanwhile.
    func setTeXFolder(_ path: String?, texpresso: Bool) async throws {
        settingTeX = true
        texCheck?.cancel()
        defer { settingTeX = false }
        do {
            tex = try await core.call(texpresso ? "set_texpresso_dir" : "set_tex_dir", ["dir": path ?? NSNull()],
                                      as: TexStatus.self)
        } catch {
            // A status read started before this choice was discarded. Refresh
            // after the check ends, even if the chosen folder was refused.
            Task { await refreshTeXStatus() }
            throw error
        }
    }

    func create(name: String, template: String) async throws {
        let info = try await core.call("create_project", ["name": name, "template": template], as: ProjectInfo.self)
        // Settings' engine for new projects; the core's own is pdfLaTeX. The project stands if this fails,
        // and opens under the alert that says so.
        if let engine = UserDefaults.standard.string(forKey: DefaultsKey.newProjectEngine), engine != "pdflatex" {
            _ = await alerting("Couldn’t Set the Engine for “\(info.name)”") {
                try await core.call("set_settings", ["id": info.id, "patch": ["engine": engine]], as: ProjectSettings.self)
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

    /// Copies a folder, .tex file (with its folder) or .zip into the library and opens it, or
    /// with `open` off only lists it; without asking, as the copy goes to the Trash like any
    /// project. An item already in the library is its project's own, which opens instead. The
    /// core removes a project it couldn't finish, so a bad zip leaves none.
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

    /// A project's folder in the library, or a file in one, opens that project, on the file. A
    /// project's id is its folder's name.
    private func isInLibrary(_ url: URL, open: Bool) async -> Bool {
        let library = FolderWatcher.realPath(Core.libraryFolder) + "/", path = FolderWatcher.realPath(url)
        guard path.hasPrefix(library) else { return false }
        let parts = path.dropFirst(library.count).split(separator: "/", maxSplits: 1).map(String.init)
        guard let id = parts.first else { return false }
        if !projects.contains(where: { $0.id == id }) { await refresh() }
        guard projects.contains(where: { $0.id == id }) else { return false }
        guard open else { return true }
        await self.open(id)
        if parts.count > 1, let project, project.id == id, project.tree.node(at: parts[1])?.isDirectory == false {
            await project.open(parts[1])
        }
        return true
    }

    func rename(_ project: ProjectInfo, to name: String) async {
        if let renamed = await renameProject(project.id, shown: project.name, to: name) {
            registerRenameUndo(current: (renamed.id, renamed.name), previous: (project.id, project.name))
        }
        await refresh()
    }

    /// The project as renamed, or nil once an alert has said why not. Its id is its folder's
    /// name, so the recents follow it.
    private func renameProject(_ id: String, shown: String, to name: String) async -> ProjectInfo? {
        await alerting("Couldn’t Rename “\(shown)”") {
            let renamed = try await core.call("rename_project", ["id": id, "name": name], as: ProjectInfo.self)
            recentProjects = recentProjects.map { $0 == id ? renamed.id : $0 }
            ProjectModel.moveSidebarState(from: id, to: renamed.id)
            return renamed
        }
    }

    /// Undo renames `current` back to `previous`'s name, and the Redo is registered as the
    /// Undo starts, as `UndoableTrash`'s are (a project's id is its name's folder, so it is
    /// known); one that fails takes it away. The closures hold the model, as the manager doesn't.
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

    /// The main window's, which Edit › Undo reaches while the list has the keyboard.
    var undoManager: UndoManager? { undoSource() }
    @ObservationIgnored var undoSource: () -> UndoManager? = { NSApp.mainWindow?.undoManager }

    /// Without asking, as in Finder: Edit › Undo and the Trash give the item back (HIG, Alerts).
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

    /// The project's folder, or nil once an alert titled `title` has said why it can't be had.
    private func folder(of project: ProjectInfo, orAlert title: String) async -> URL? {
        await alerting(title) { URL(fileURLWithPath: try await core.call("project_root", ["id": project.id], as: String.self)) }
    }

    /// `work`'s answer, or nil once an alert titled `title` has said why there is none.
    private func alerting<T>(_ title: String, _ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch {
            alert = AppAlert(title, error)
            return nil
        }
    }

    /// Bumped by each `open` and `close`, so only the latest carries on: the
    /// restored project and an Open With import can overlap at launch.
    @ObservationIgnored private var openGeneration = 0
    /// What is opening, for Home to show at work: a project's id while it loads, before
    /// `project` may name it, or the name of an item being copied in.
    private(set) var opening: [String] = []
    var isOpening: Bool { !opening.isEmpty }
    @ObservationIgnored private var importing = Set<URL>()

    private func stopOpening(_ name: String) {
        if let place = opening.firstIndex(of: name) { opening.remove(at: place) }
    }

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
        guard project?.id != id || project?.closed == true else { return }
        opening.append(id)
        defer { stopOpening(id) }
        guard await leave(generation) else { return }
        dropRequests()
        // Home's renames and moves to the Trash can't be undone under a project, as a project's own
        // can't once it has closed (`ProjectModel.close`): nothing would show the result, and Undo
        // from the sidebar could rename the open project's folder under it.
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

    /// The project's own requests, which the next project mustn't present.
    private func dropRequests() {
        prompt = nil
        newEntry = nil
        addingFiles = false
        exporting = nil
    }

    /// Unless a later open or close took over while this saved; that one leaves it.
    private func leave(_ generation: Int) async -> Bool {
        guard let project else { return true }
        if !project.closed {
            guard await project.flush(), generation == openGeneration else { return false }
            project.close()
        }
        // Finish a late live start's Stop before another model can start the
        // same project's session through the core's concurrent call queue.
        await project.texpresso.waitForPendingCalls()
        return generation == openGeneration
    }
}
