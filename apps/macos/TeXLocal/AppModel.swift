import Accessibility
import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated enum DefaultsKey {
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
    static let texpressoGuide = URL(string: "https://github.com/Banrs/Underleaf#live-preview")!
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

protocol AppWindow: AnyObject {
    var undoManager: UndoManager? { get }
    func attach(_ project: ProjectModel)
    func performPDF(_ action: PDFAction)
    func revealSidebar()
    func focusSearch()
}

nonisolated enum WorkspaceLayout { case source, split, pdf }

nonisolated enum OutlineState { case open, folded, hidden }

struct NewProjectDraft: Identifiable {
    var template: ProjectTemplate
    var name: String

    var id: ProjectTemplate { template }
}

@Observable
final class AppModel {
    let core: Core
    var projects: [ProjectInfo] { core.library.projects }
    private(set) var projectsLoaded = false
    var tex: TexStatus?
    private(set) var settingTeX = false
    private(set) var installingTeX = false
    var project: ProjectModel?
    var alert: AppAlert?
    private(set) var libraryProblem: AppAlert?

    var newProjectDraft: NewProjectDraft?
    var prompt: Prompt?
    var newEntry: NewEntry?
    var openingProject = false
    var addingFiles = false
    var exporting: ExportFile?
    @ObservationIgnored weak var window: (any AppWindow)?
    @ObservationIgnored var recentLimit: () -> Int = { 10 }
    @ObservationIgnored let defaults: UserDefaults
    var savesLayout: Bool { defaults === UserDefaults.standard }

    var autoCompile: Bool {
        didSet {
            defaults.set(autoCompile, forKey: DefaultsKey.autoCompile)
            project?.autoCompileChanged()
        }
    }
    var showWordCount: Bool { didSet { defaults.set(showWordCount, forKey: DefaultsKey.showWordCount) } }
    var showSource: Bool
    var showPDF: Bool
    var outlineCollapsed: Bool { didSet { defaults.set(outlineCollapsed, forKey: DefaultsKey.outlineCollapsed) } }
    var mainWindowIsKey = false
    var commandProject: ProjectModel? { mainWindowIsKey && project?.closed != true ? project : nil }
    var chosenItem: ItemActions?
    var recentProjects: [String] { didSet { defaults.set(recentProjects, forKey: DefaultsKey.recentProjects) } }
    var recents: [ProjectInfo] { recentProjects.compactMap { id in projects.first { $0.id == id } } }

    static let fontSizes = 10...28
    var fontName: String { didSet { defaults.set(fontName, forKey: DefaultsKey.editorFontName) } }
    var fontSize: Int { didSet { defaults.set(fontSize, forKey: DefaultsKey.editorFontSize) } }
    var syntaxTheme: SyntaxTheme { didSet { defaults.set(syntaxTheme.rawValue, forKey: DefaultsKey.editorSyntaxTheme) } }
    var lineNumbers: Bool { didSet { defaults.set(lineNumbers, forKey: DefaultsKey.editorLineNumbers) } }
    var autoPair: Bool { didSet { defaults.set(autoPair, forKey: DefaultsKey.editorAutoPair) } }
    var autoComplete: Bool { didSet { defaults.set(autoComplete, forKey: DefaultsKey.editorAutoComplete) } }
    var spellCheck: Bool { didSet { defaults.set(spellCheck, forKey: DefaultsKey.editorSpellCheck) } }
    var syncAfterCompile: Bool { didSet { defaults.set(syncAfterCompile, forKey: DefaultsKey.syncAfterCompile) } }
    var newProjectEngine: Engine { didSet { defaults.set(newProjectEngine.rawValue, forKey: DefaultsKey.newProjectEngine) } }
    var paper: PDFPaper { didSet { defaults.set(paper.rawValue, forKey: DefaultsKey.pdfPaper) } }
    var settingsPane: SettingsPane { didSet { defaults.set(settingsPane.rawValue, forKey: DefaultsKey.settingsPane) } }
    @ObservationIgnored var buildPanelHeight: Double { didSet { defaults.set(buildPanelHeight, forKey: DefaultsKey.buildPanelHeight) } }

    init(core: Core, defaults: UserDefaults = .standard) {
        self.core = core
        self.defaults = defaults
        if !core.isOpen { libraryProblem = AppAlert("Couldn’t Open the Projects Folder", Core.libraryAdvice) }
        defaults.register(defaults: [DefaultsKey.autoCompile: true, DefaultsKey.showWordCount: true, DefaultsKey.showSource: true,
                                     DefaultsKey.showPDF: true, DefaultsKey.editorFontSize: 13, DefaultsKey.editorLineNumbers: true,
                                     DefaultsKey.editorAutoPair: true, DefaultsKey.editorAutoComplete: true,
                                     DefaultsKey.editorSpellCheck: true])
        func choice<T: RawRepresentable<String>>(_ key: String, _ fallback: T) -> T {
            defaults.string(forKey: key).flatMap { T(rawValue: $0) } ?? fallback
        }
        autoCompile = defaults.bool(forKey: DefaultsKey.autoCompile)
        showWordCount = defaults.bool(forKey: DefaultsKey.showWordCount)
        showSource = defaults.bool(forKey: DefaultsKey.showSource) || !defaults.bool(forKey: DefaultsKey.showPDF)
        showPDF = defaults.bool(forKey: DefaultsKey.showPDF)
        outlineCollapsed = defaults.bool(forKey: DefaultsKey.outlineCollapsed)
        recentProjects = defaults.stringArray(forKey: DefaultsKey.recentProjects) ?? []
        launchProject = defaults.string(forKey: DefaultsKey.openProject)
        fontName = defaults.string(forKey: DefaultsKey.editorFontName) ?? ""
        fontSize = defaults.integer(forKey: DefaultsKey.editorFontSize)
        syntaxTheme = choice(DefaultsKey.editorSyntaxTheme, .system)
        lineNumbers = defaults.bool(forKey: DefaultsKey.editorLineNumbers)
        autoPair = defaults.bool(forKey: DefaultsKey.editorAutoPair)
        autoComplete = defaults.bool(forKey: DefaultsKey.editorAutoComplete)
        spellCheck = defaults.bool(forKey: DefaultsKey.editorSpellCheck)
        syncAfterCompile = defaults.bool(forKey: DefaultsKey.syncAfterCompile)
        newProjectEngine = choice(DefaultsKey.newProjectEngine, .pdflatex)
        paper = choice(DefaultsKey.pdfPaper, .white)
        settingsPane = choice(DefaultsKey.settingsPane, .general)
        buildPanelHeight = defaults.double(forKey: DefaultsKey.buildPanelHeight)
    }

    func newProject(_ template: ProjectTemplate = .article) {
        guard libraryProblem == nil else { return }
        Task {
            let free = try? await core.call(FreeProjectName())
            newProjectDraft = NewProjectDraft(template: template, name: free ?? "Untitled")
        }
    }

    func outlineOpen(of project: ProjectModel?) -> Bool { project?.isLaTeX == true && !outlineCollapsed }

    func outlineState(of project: ProjectModel) -> OutlineState {
        project.search.isSearching ? .hidden : outlineOpen(of: project) ? .open : .folded
    }

    var layout: WorkspaceLayout {
        get { showSource ? (showPDF ? .split : .source) : .pdf }
        set { showPanes(source: newValue != .pdf, pdf: newValue != .source) }
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
        window?.performPDF(action)
    }

    func workspaceProject(after shown: ProjectModel?) -> ProjectModel? {
        guard let project else { return nil }
        return project.initialLoadComplete ? project : shown
    }

    @ObservationIgnored private var texCheck: Task<Void, Never>?

    func retryLibrary() async {
        core.reopen()
        await reloadProjects()
        await refreshTeXStatus()
    }

    func reloadProjects() async {
        guard core.isOpen else { return }
        do {
            try await core.call(ReloadProjects())
            for project in projects where project.missing { await follow(project) }
            libraryProblem = nil
        } catch {
            libraryProblem = AppAlert("Couldn’t Load Projects", error)
        }
        projectsLoaded = true
    }

    func refreshTeXStatus() async {
        guard !settingTeX else { return }
        await restart(&texCheck) { [self] in
            let status = try? await core.call(CheckTex())
            if !Task.isCancelled, let status { tex = status }
        }.value
    }

    func setTeXFolder(_ path: String?, texpresso: Bool) async throws {
        if texpresso { try await setTeX(SetTexpressoDir(dir: path)) } else { try await setTeX(SetTexDir(dir: path)) }
    }

    func installTeX() async throws {
        installingTeX = true
        defer { installingTeX = false }
        try await setTeX(InstallTex())
    }

    private func setTeX<R: LibraryRequest>(_ request: R) async throws where R.Reply == TexStatus {
        settingTeX = true
        texCheck?.cancel()
        defer { settingTeX = false }
        do {
            tex = try await core.call(request)
        } catch {
            Task { await refreshTeXStatus() }
            throw error
        }
    }

    func create(name: String, template: ProjectTemplate) async throws {
        let info = try await core.call(CreateProject(name: name, template: template, engine: newProjectEngine))
        Task { await open(info.id) }
    }

    static let openableTypes: [UTType] = [.folder, .zip] + [UTType(filenameExtension: "tex")].compactMap(\.self)

    static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var directory: ObjCBool = false
        if url.hasDirectoryPath || (FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &directory)
                                   && directory.boolValue) { return true }
        return UTType(filenameExtension: url.pathExtension).map { type in openableTypes.contains { type.conforms(to: $0) } } ?? false
    }

    func open(_ urls: [URL]) async {
        for url in urls { await open(url, alone: urls.count == 1) }
    }

    func open(_ url: URL, alone: Bool = true) async {
        guard !importing.contains(url) else { return }
        importing.append(url)
        defer { importing.removeAll { $0 == url } }
        guard let opening = await alerting("Couldn’t Open “\(url.lastPathComponent)”", { try await openPath(url) }) else { return }
        guard alone else { return }
        importing.removeAll { $0 == url }
        let id = opening.project.id
        await open(id)
        if let file = opening.file, let project, project.id == id { await project.open(file) }
    }

    private func openPath(_ url: URL) async throws -> Opening {
        let opening = try await core.call(OpenPath(path: url.path(percentEncoded: false)))
        if opening.project.opened {
            bookmarks[opening.project.id] = try? opening.project.folder.bookmarkData()
        }
        return opening
    }

    private var bookmarks: [String: Data] {
        get { defaults.dictionary(forKey: DefaultsKey.folderBookmarks) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: DefaultsKey.folderBookmarks) }
    }

    private func follow(_ project: ProjectInfo) async {
        var stale = false, trashed = FileManager.URLRelationship.other
        guard let bookmark = bookmarks[project.id],
              let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return }
        try? FileManager.default.getRelationship(&trashed, of: .trashDirectory, in: .userDomainMask, toItemAt: url)
        if trashed != .contains { _ = try? await openPath(url) }
    }

    func forget(_ project: ProjectInfo) async {
        let forgotten = await alerting("Couldn’t Remove “\(project.name)” from the List") {
            try await core.call(ForgetFolder(id: project.id))
        }
        if forgotten != nil {
            bookmarks[project.id] = nil
            recentProjects.removeAll { $0 == project.id }
        }
    }

    func rename(_ project: ProjectInfo, to name: String) async {
        if let renamed = await renameProject(project.id, shown: project.name, to: name) {
            registerRenameUndo(current: (renamed.id, renamed.name), previous: (project.id, project.name))
        }
    }

    private func renameProject(_ id: String, shown: String, to name: String) async -> ProjectInfo? {
        await alerting("Couldn’t Rename “\(shown)”") {
            let renamed = try await core.call(RenameProject(id: id, name: name))
            recentProjects = recentProjects.map { $0 == id ? renamed.id : $0 }
            return renamed
        }
    }

    private func registerRenameUndo(current: (id: String, name: String), previous: (id: String, name: String)) {
        undoManager?.registerAsyncUndo(withTarget: self, actionName: String(localized: "Rename"), reversal: {
            self.registerRenameUndo(current: previous, previous: current)
        }, work: {
            await self.renameProject(current.id, shown: current.name, to: previous.name) != nil
        })
    }

    func duplicate(_ project: ProjectInfo) async -> String? {
        let copy = await alerting("Couldn’t Duplicate “\(project.name)”") {
            try await core.call(DuplicateProject(id: project.id, name: String(localized: "\(project.name) copy")))
        }
        return copy?.id
    }

    var undoManager: UndoManager? { window?.undoManager }

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
                    self?.report(failure, error)
                    return false
                }
            },
            changed: { [weak self] in await self?.reloadProjects() },
            failed: { [weak self] title, error in self?.report(title, error) })
        await item.moveToTrash()
        await reloadProjects()
    }

    func alerting<T>(_ title: @autoclosure () -> String, _ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch {
            report(title(), error)
            return nil
        }
    }

    func report(_ title: String, _ message: String) {
        guard alert == nil else { return AccessibilityNotification.Announcement(title).post() }
        alert = AppAlert(title, message)
    }

    func report(_ title: String, _ error: any Error) {
        if !(error is CancellationError) { report(title, error.localizedDescription) }
    }

    @ObservationIgnored private var switching: Task<Bool, Never>?
    private(set) var opening: String?
    private(set) var importing: [URL] = []
    var isOpening: Bool { opening != nil || !importing.isEmpty }
    @ObservationIgnored var launchProject: String?

    func open(_ id: String) async {
        guard project?.id != id || project?.closed == true else { return }
        opening = id
        defer { if opening == id { opening = nil } }
        _ = await restart(&switching) { [self] in
            guard await leave() else { return false }
            dropRequests()
            undoManager?.removeAllActions()
            recentProjects = Array(([id] + recentProjects.filter { $0 != id }).prefix(recentLimit()))
            let model = ProjectModel(id: id, app: self)
            project = model
            window?.attach(model)
            await model.load()
            return true
        }.value
    }

    @discardableResult
    func close() async -> Bool {
        await restart(&switching) { [self] in
            guard project != nil else { return true }
            guard await leave() else { return false }
            project = nil
            dropRequests()
            return true
        }.value
    }

    private func dropRequests() {
        prompt = nil
        newEntry = nil
        addingFiles = false
        exporting = nil
    }

    func quit() async -> Bool {
        guard await restart(&switching, leave).value else { return false }
        _ = try? await core.call(KillAll())
        return true
    }

    private func leave() async -> Bool {
        guard let project else { return true }
        if !project.closed && !project.isClosing {
            guard await project.save(), !Task.isCancelled else { return false }
            project.savePlace()
        }
        return await project.close().value && !Task.isCancelled
    }
}
