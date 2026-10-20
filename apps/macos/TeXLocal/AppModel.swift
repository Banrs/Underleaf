import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The keys of the settings the app stores; the raw values are what users' defaults hold.
nonisolated enum DefaultsKey {
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
    static let dismissedTeXTip = "dismissedTeXTip"
    static let editorFontName = "editorFontName"
    static let editorFontSize = "editorFontSize"
    static let editorSyntaxTheme = "editorSyntaxTheme"
    static let editorLineNumbers = "editorLineNumbers"
    static let editorAutoPair = "editorAutoPair"
    static let editorAutoComplete = "editorAutoComplete"
    static let editorSpellCheck = "editorSpellCheck"
    static let pdfPaper = "pdfPaper"
    static let liveViewer = "liveViewer"
}

enum Links {
    static let repository = URL(string: "https://github.com/Banrs/Underleaf")!
    static let issues = repository.appending(path: "issues")
    static let requirements = URL(string: "https://github.com/Banrs/Underleaf#requirements")!
    static let texpressoGuide = repository.appending(path: "blob/main/docs/texpresso.md")
    static let mactex = URL(string: "https://tug.org/mactex/")!
}

struct AppAlert: Sendable {
    let title, message: String

    init(_ title: String, _ message: String) { (self.title, self.message) = (title, message) }

    init(_ title: String, _ error: any Error) { self.init(title, error.localizedDescription) }
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

/// The File Outline: open, folded to its header, or hidden with its header for search results.
nonisolated enum OutlineState { case open, folded, hidden }

/// What the New Project sheet opens with: the template, and a free name.
struct NewProjectDraft: Identifiable {
    var template: ProjectTemplate
    var name: String

    var id: ProjectTemplate { template }
}

private nonisolated struct FreeName: Decodable { let name: String }

@Observable
final class AppModel {
    var projects: [ProjectInfo] = []
    private(set) var projectsLoaded = false
    var tex: TexStatus?
    private(set) var settingTeX = false
    var project: ProjectModel?
    var alert: AppAlert?
    private(set) var libraryProblem: AppAlert? = Core.shared.isOpen ? nil
        : AppAlert("Couldn’t Open the Projects Folder", Core.libraryAdvice)

    var newProjectDraft: NewProjectDraft?
    var prompt: Prompt?
    var newEntry: NewEntry?
    var openingProject = false
    var addingFiles = false
    var exporting: ExportFile?
    var searchFocusToken = 0
    @ObservationIgnored var performPDF: ((PDFAction) -> Void)?
    /// The user's defaults, or a test's own.
    @ObservationIgnored let defaults: UserDefaults
    /// AppKit keeps the window's split positions and toolbar in the standard defaults itself.
    var savesLayout: Bool { defaults === UserDefaults.standard }

    // Not @AppStorage, so the menus and models observe them.
    var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: DefaultsKey.sidebarVisible) } }
    var inspectorVisible: Bool { didSet { defaults.set(inspectorVisible, forKey: DefaultsKey.inspectorVisible) } }
    /// Folded by a window too narrow for them, which brings them back as it widens: neither hidden nor saved.
    var sidebarFolded = false
    var inspectorFolded = false
    /// The side columns as the window has them: the user's choice, unless the window folded one. Showing a folded one unfolds it.
    var sidebarShown: Bool {
        get { sidebarVisible && !sidebarFolded }
        set { (sidebarVisible, sidebarFolded) = (newValue, false) }
    }
    var inspectorShown: Bool {
        get { inspectorVisible && !inspectorFolded }
        set { (inspectorVisible, inspectorFolded) = (newValue, false) }
    }
    var autoCompile: Bool {
        didSet {
            defaults.set(autoCompile, forKey: DefaultsKey.autoCompile)
            project?.autoCompileChanged()
        }
    }
    var showWordCount: Bool { didSet { defaults.set(showWordCount, forKey: DefaultsKey.showWordCount) } }
    /// Kept by View › Show PDF and the toolbar; a PDF command shows it for now.
    var showPDF: Bool
    var outlineCollapsed: Bool { didSet { defaults.set(outlineCollapsed, forKey: DefaultsKey.outlineCollapsed) } }
    /// The menus act on the project only while its window is key.
    var mainWindowIsKey = false
    var commandProject: ProjectModel? { mainWindowIsKey && project?.closed != true ? project : nil }
    var chosenItem: ItemActions?
    var recentProjects: [String] { didSet { defaults.set(recentProjects, forKey: DefaultsKey.recentProjects) } }
    /// Filtered, not pruned: a library that lists empty would wipe them.
    var recents: [ProjectInfo] { recentProjects.compactMap { id in projects.first { $0.id == id } } }

    /// QA's launch arguments come in through the standard defaults' argument domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    /// The sheet opens once the core has named the project.
    func newProject(_ template: ProjectTemplate? = nil) {
        guard libraryProblem == nil else { return }
        let template = template ?? defaults.string(forKey: DefaultsKey.newProjectTemplate)
            .flatMap(ProjectTemplate.init(rawValue:)) ?? .standard
        Task {
            let free = try? await core.call("free_project_name", as: FreeName.self)
            newProjectDraft = NewProjectDraft(template: template, name: free?.name ?? "Untitled")
        }
    }

    /// A file that isn't LaTeX has no outline: its header stays, folded and dim.
    func outlineOpen(of project: ProjectModel?) -> Bool { project?.isLaTeX == true && !outlineCollapsed }

    func outlineState(of project: ProjectModel) -> OutlineState {
        project.search.isSearching ? .hidden : outlineOpen(of: project) ? .open : .folded
    }

    func togglePDF() {
        showPDF.toggle()
        defaults.set(showPDF, forKey: DefaultsKey.showPDF)
    }

    func requestPDF(_ action: PDFAction) {
        showPDF = true
        performPDF?(action)
    }

    nonisolated enum SideColumn { case sidebar, inspector }

    /// Shut by the window, for want of room, a column stays shown, unsaved, and comes back as the window widens; shut by
    /// the user, with its toggle or on its divider, it is hidden, and saved so.
    func sideColumn(_ column: SideColumn, shown: Bool, byWindow: Bool) {
        switch (column, shown || !byWindow) {
        case (.sidebar, true): sidebarShown = shown
        case (.sidebar, false): sidebarFolded = sidebarVisible
        case (.inspector, true): inspectorShown = shown
        case (.inspector, false): inspectorFolded = inspectorVisible
        }
    }

    /// Until the open project has loaded, the one shown, so a switch never passes through Home.
    func workspaceProject(after shown: ProjectModel?) -> ProjectModel? {
        guard let project else { return nil }
        return project.initialLoadComplete ? project : shown
    }

    private let core = Core.shared
    @ObservationIgnored private var texCheck: Task<Void, Never>?

    func retryLibrary() async {
        core.reopen()
        await refresh()
        await refreshTeXStatus()
    }

    /// TeX is read apart, as its probe starts a process.
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

    /// Not while a TeX folder is being chosen.
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
            tex = try await core.call(texpresso ? "set_texpresso_dir" : "set_tex_dir", ["dir": path], as: TexStatus.self)
        } catch {
            // The status read this choice cancelled.
            Task { await refreshTeXStatus() }
            throw error
        }
    }

    func create(name: String, template: ProjectTemplate) async throws {
        let engine = defaults.string(forKey: DefaultsKey.newProjectEngine).flatMap(TeXEngine.init(rawValue:))
        let info = try await core.call("create_project", ["name": name, "template": template.rawValue, "engine": engine?.rawValue],
                                       as: ProjectInfo.self)
        await refresh()
        // The sheet goes as the project opens, not after its first build.
        Task { await open(info.id) }
    }

    static let openableTypes: [UTType] = [.folder, .zip] + [UTType(filenameExtension: "tex")].compactMap(\.self)

    static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var directory: ObjCBool = false
        // Follows a symlinked folder, as the URL's resource values don't.
        if url.hasDirectoryPath || (FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &directory)
                                   && directory.boolValue) { return true }
        return UTType(filenameExtension: url.pathExtension).map { type in openableTypes.contains { type.conforms(to: $0) } } ?? false
    }

    /// One alone opens.
    func importProjects(_ urls: [URL]) async {
        for url in urls { await importProject(from: url, open: urls.count == 1) }
    }

    /// Without asking: the copy goes to the Trash like any project.
    func importProject(from url: URL, open: Bool = true) async {
        if await isInLibrary(url, open: open) { return }
        // A second Return while it copies would make a second project.
        guard !importing.contains(url) else { return }
        importing.append(url)
        defer { importing.removeAll { $0 == url } }
        guard let info = await alerting("Couldn’t Open “\(url.lastPathComponent)”", {
            try await core.call("import_project", ["src": url.path], as: ProjectInfo.self)
        }) else { return }
        await refresh()
        guard open else { return }
        // Its own row takes over from the copy's.
        importing.removeAll { $0 == url }
        await self.open(info.id)
    }

    private func isInLibrary(_ url: URL, open: Bool) async -> Bool {
        guard let located = try? await core.call("locate", ["path": url.path(percentEncoded: false)], as: Located?.self) else { return false }
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
            return renamed
        }
    }

    private func registerRenameUndo(current: (id: String, name: String), previous: (id: String, name: String)) {
        undoManager?.registerAsyncUndo(withTarget: self, actionName: String(localized: "Rename"), reversal: {
            self.registerRenameUndo(current: previous, previous: current)
        }, work: {
            let renamed = await self.renameProject(current.id, shown: current.name, to: previous.name) != nil
            await self.refresh()
            return renamed
        })
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

    /// What `work` answers, or nil once its failure is an alert under `title`, unless `quiet` by then.
    func alerting<T>(_ title: @autoclosure () -> String, unless quiet: () -> Bool = { false },
                     _ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch {
            if !quiet() { report(error, title()) }
            return nil
        }
    }

    /// Once: a failed save's document event may have shown it already.
    func report(_ error: any Error, _ title: String) { if alert?.title != title { alert = AppAlert(title, error) } }

    /// Only the latest open or close carries on: a restored project and an Open With import can overlap.
    @ObservationIgnored private var openGeneration = 0
    /// For Home to show at work.
    private(set) var opening: String?
    private(set) var importing: [URL] = []
    var isOpening: Bool { opening != nil || !importing.isEmpty }
    @ObservationIgnored var launchProject: String?

    /// `project` goes from one to the next, never nil between, so the window keeps the workspace.
    func open(_ id: String, restoring saved: SavedWorkspace? = nil) async {
        openGeneration += 1
        let generation = openGeneration
        guard project?.id != id || project?.closed == true else { return }
        opening = id
        defer { if opening == id { opening = nil } }
        guard await leave(generation) else { return }
        dropRequests()
        // Home's renames and moves to the Trash can't be undone under a project, whose folder they could move.
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
        // False too when an open took over while this saved.
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
        await project.waitUntilClosed()
        return generation == openGeneration
    }
}
