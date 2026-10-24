import SwiftUI
import UniformTypeIdentifiers

/// The keys of the settings the app stores; the raw values are what users' defaults hold.
nonisolated enum DefaultsKey {
    static let sidebarVisible = "sidebarVisible"
    static let inspectorVisible = "inspectorVisible"
    static let autoCompile = "autoCompile"
    static let showWordCount = "showWordCount"
    static let recentProjects = "recentProjects"
    static let folderBookmarks = "folderBookmarks"
    static let showSource = "showSource"
    static let showPDF = "showPDF"
    static let openProject = "openProject"
    static let outlineCollapsed = "OutlineCollapsed"
    static let syncAfterCompile = "syncAfterCompile"
    static let newProjectEngine = "newProjectEngine"
    static let settingsPane = "settingsPane"
    static let editorFontName = "editorFontName"
    static let editorFontSize = "editorFontSize"
    static let editorSyntaxTheme = "editorSyntaxTheme"
    static let editorLineNumbers = "editorLineNumbers"
    static let editorAutoPair = "editorAutoPair"
    static let editorAutoComplete = "editorAutoComplete"
    static let editorSpellCheck = "editorSpellCheck"
    static let pdfPaper = "pdfPaper"
    static let buildPanelHeight = "buildPanelHeight"
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

/// `open_path`'s answer: the project, and the file in it to show.
private nonisolated struct Opening: Decodable {
    let project: ProjectInfo
    let file: String?
}

@Observable
final class AppModel {
    var projects: [ProjectInfo] = []
    private(set) var projectsLoaded = false
    var tex: TexStatus?
    private(set) var settingTeX = false
    /// TinyTeX's install, which takes a minute or more.
    private(set) var installingTeX = false
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
    /// Kept by View › Show Source and View › Show PDF, with the toolbar's PDF; one always shows. Opening a file or a place
    /// in one shows the source for now, as a PDF command shows the PDF.
    var showSource: Bool
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
                                     DefaultsKey.showWordCount: true, DefaultsKey.showSource: true,
                                     DefaultsKey.showPDF: true])
        sidebarVisible = defaults.bool(forKey: DefaultsKey.sidebarVisible)
        inspectorVisible = defaults.bool(forKey: DefaultsKey.inspectorVisible)
        autoCompile = defaults.bool(forKey: DefaultsKey.autoCompile)
        showWordCount = defaults.bool(forKey: DefaultsKey.showWordCount)
        showSource = defaults.bool(forKey: DefaultsKey.showSource)
        showPDF = defaults.bool(forKey: DefaultsKey.showPDF)
        outlineCollapsed = defaults.bool(forKey: DefaultsKey.outlineCollapsed)
        recentProjects = defaults.stringArray(forKey: DefaultsKey.recentProjects) ?? []
        launchProject = defaults.string(forKey: DefaultsKey.openProject)
    }

    /// The sheet opens once the core has named the project.
    func newProject(_ template: ProjectTemplate = .article) {
        guard libraryProblem == nil else { return }
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

    func toggleSource() { showPanes(source: !showSource, pdf: showPDF || showSource) }
    func togglePDF() { showPanes(source: showSource || showPDF, pdf: !showPDF) }

    private func showPanes(source: Bool, pdf: Bool) {
        (showSource, showPDF) = (source, pdf)
        defaults.set(source, forKey: DefaultsKey.showSource)
        defaults.set(pdf, forKey: DefaultsKey.showPDF)
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
            let listed = try await core.call("list_projects", as: [ProjectInfo].self)
            var followed = false
            for project in listed where project.missing { followed = await follow(project) || followed }
            projects = followed ? try await core.call("list_projects", as: [ProjectInfo].self) : listed
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
        try await setTeX(texpresso ? "set_texpresso_dir" : "set_tex_dir", ["dir": path])
    }

    /// TinyTeX into the user's Library, with no password; Install then adds what a document needs.
    func installTeX() async throws {
        installingTeX = true
        defer { installingTeX = false }
        try await setTeX("install_tex")
    }

    /// Commands that change where TeX is, and answer the status.
    private func setTeX(_ command: String, _ args: [String: any Sendable] = [:]) async throws {
        settingTeX = true
        texCheck?.cancel()
        defer { settingTeX = false }
        do {
            tex = try await core.call(command, args, as: TexStatus.self)
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

    private static var recentLimit: Int { NSDocumentController.shared.maximumRecentDocumentCount }

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
    func open(_ urls: [URL]) async {
        for url in urls { await open(url, alone: urls.count == 1) }
    }

    /// A folder, or a .tex file's, opens where it is; a .zip is copied into the library. The core refuses what holds no .tex.
    func open(_ url: URL, alone: Bool = true) async {
        // A second Return while it copies would make a second project.
        guard !importing.contains(url) else { return }
        importing.append(url)
        defer { importing.removeAll { $0 == url } }
        guard let opening = await alerting("Couldn’t Open “\(url.lastPathComponent)”", { try await openPath(url) }) else { return }
        await refresh()
        guard alone else { return }
        // Its own row takes over.
        importing.removeAll { $0 == url }
        let id = opening.project.id
        await open(id)
        if let file = opening.file, let project, project.id == id { await project.open(file) }
    }

    private func openPath(_ url: URL) async throws -> Opening {
        let opening = try await core.call("open_path", ["path": url.path(percentEncoded: false)], as: Opening.self)
        if opening.project.opened {
            bookmarks[opening.project.id] = try? opening.project.folder.bookmarkData()
        }
        return opening
    }


    /// They find an opened folder again after a move.
    private var bookmarks: [String: Data] {
        get { defaults.dictionary(forKey: DefaultsKey.folderBookmarks) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: DefaultsKey.folderBookmarks) }
    }

    /// A missing folder that its bookmark finds, unless in the Trash, opened again at its new path: the core knows it by
    /// its identity and keeps its id.
    private func follow(_ project: ProjectInfo) async -> Bool {
        var stale = false, trashed = FileManager.URLRelationship.other
        guard let bookmark = bookmarks[project.id],
              let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
        else { return false }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        try? FileManager.default.getRelationship(&trashed, of: .trashDirectory, in: .userDomainMask, toItemAt: url)
        guard trashed != .contains else { return false }
        return (try? await openPath(url)) != nil
    }

    /// The folder stays as it is; its settings and build output go.
    func forget(_ project: ProjectInfo) async {
        let forgotten: Void? = await alerting("Couldn’t Remove “\(project.name)” from the List") {
            try await core.call("forget_folder", ["id": project.id])
        }
        if forgotten != nil {
            bookmarks[project.id] = nil
            recentProjects.removeAll { $0 == project.id }
        }
        await refresh()
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

    /// Named as Finder names a copy, numbered on by the core where that's taken; the copy's id once the list has it.
    func duplicate(_ project: ProjectInfo) async -> String? {
        let copy = await alerting("Couldn’t Duplicate “\(project.name)”") {
            try await core.call("duplicate_project", ["id": project.id, "name": String(localized: "\(project.name) copy")],
                                as: ProjectInfo.self)
        }
        await refresh()
        return copy?.id
    }

    var undoManager: UndoManager? { undoSource() }
    @ObservationIgnored var undoSource: () -> UndoManager? = { NSApp.mainWindow?.undoManager }

    func delete(_ project: ProjectInfo) async {
        let failure = "Couldn’t Move “\(project.name)” to the Trash"
        let item = UndoableTrash(
            original: project.folder, name: project.name, undoManager: undoManager,
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
    func open(_ id: String) async {
        // The project shown, opened again, leaves a close under way to go on.
        guard project?.id != id || project?.closed == true else { return }
        openGeneration += 1
        let generation = openGeneration
        opening = id
        defer { if opening == id { opening = nil } }
        guard await leave(generation) else { return }
        dropRequests()
        // Home's renames and moves to the Trash can't be undone under a project, whose folder they could move.
        undoManager?.removeAllActions()
        recentProjects = Array(([id] + recentProjects.filter { $0 != id }).prefix(Self.recentLimit))
        let model = ProjectModel(id: id, app: self)
        project = model
        await model.load()
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

    /// As the app quits: the project saved, its place kept and its session closed, but still the one shown, for the window's
    /// restoration. False, staying, when the save fails.
    func leave() async -> Bool {
        openGeneration += 1
        return await leave(openGeneration)
    }

    private func leave(_ generation: Int) async -> Bool {
        guard let project else { return true }
        if !project.closed {
            guard await project.save(), generation == openGeneration else { return false }
            await project.savePlace()
            project.close()
        }
        await project.waitUntilClosed()
        return generation == openGeneration
    }
}
