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
    static let navigators = "navigators"
    static let syncAfterCompile = "syncAfterCompile"
    static let newProjectEngine = "newProjectEngine"
    static let settingsPane = "settingsPane"
    static let editorFontName = "editorFontName"
    static let editorFontSize = "editorFontSize"
    static let editorLineNumbers = "editorLineNumbers"
    static let editorAutoPair = "editorAutoPair"
    static let editorAutoComplete = "editorAutoComplete"
    static let editorSpellCheck = "editorSpellCheck"
    static let pdfPaper = "pdfPaper"
    static let buildPanelHeight = "buildPanelHeight"
    static let recentSymbols = "recentSymbols"
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
    func performPDF(_ action: PDFAction)
    func revealSidebar()
    func focusSearch()
    func show()
    func close()
}

nonisolated enum WorkspaceLayout { case source, split, pdf }

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
    var tex: TexStatus? { core.library.tex }
    private(set) var settingTeX = false
    private(set) var installingTeX = false
    private(set) var libraryProblem: AppAlert?
    private(set) var windows: [WindowModel] = []
    var main: WindowModel? { windows.first(where: \.isKey) }
    var home: WindowModel? { windows.first { $0.project == nil } }
    @ObservationIgnored var newWindow: ((String?) -> WindowModel)?
    @ObservationIgnored var recentLimit: () -> Int = { 10 }
    var pdfAppName: String?
    @ObservationIgnored let defaults: UserDefaults
    var savesLayout: Bool { defaults === UserDefaults.standard }

    var autoCompile: Bool {
        didSet {
            defaults.set(autoCompile, forKey: DefaultsKey.autoCompile)
            for window in windows { window.project?.autoCompileChanged() }
        }
    }
    var showWordCount: Bool { didSet { defaults.set(showWordCount, forKey: DefaultsKey.showWordCount) } }
    var recentProjects: [String] { didSet { defaults.set(recentProjects, forKey: DefaultsKey.recentProjects) } }
    var recents: [ProjectInfo] { recentProjects.compactMap { id in projects.first { $0.id == id } } }
    var recentSymbols: [String] { didSet { defaults.set(recentSymbols, forKey: DefaultsKey.recentSymbols) } }

    static let fontSizes = 10...28
    var fontName: String { didSet { defaults.set(fontName, forKey: DefaultsKey.editorFontName) } }
    var fontSize: Int { didSet { defaults.set(fontSize, forKey: DefaultsKey.editorFontSize) } }
    var lineNumbers: Bool { didSet { defaults.set(lineNumbers, forKey: DefaultsKey.editorLineNumbers) } }
    var autoPair: Bool { didSet { defaults.set(autoPair, forKey: DefaultsKey.editorAutoPair) } }
    var autoComplete: Bool { didSet { defaults.set(autoComplete, forKey: DefaultsKey.editorAutoComplete) } }
    var spellCheck: Bool { didSet { defaults.set(spellCheck, forKey: DefaultsKey.editorSpellCheck) } }
    var syncAfterCompile: Bool { didSet { defaults.set(syncAfterCompile, forKey: DefaultsKey.syncAfterCompile) } }
    var newProjectEngine: Engine { didSet { defaults.set(newProjectEngine.rawValue, forKey: DefaultsKey.newProjectEngine) } }
    var paper: PDFPaper { didSet { defaults.set(paper.rawValue, forKey: DefaultsKey.pdfPaper) } }
    var settingsPane: SettingsPane { didSet { defaults.set(settingsPane.rawValue, forKey: DefaultsKey.settingsPane) } }
    @ObservationIgnored var buildPanelHeight: Double { didSet { defaults.set(buildPanelHeight, forKey: DefaultsKey.buildPanelHeight) } }
    @ObservationIgnored var launchProject: String?

    init(core: Core, defaults: UserDefaults = .standard) {
        self.core = core
        self.defaults = defaults
        if !core.isOpen { libraryProblem = AppAlert("Couldn’t Open TeXLocal’s Folders", Core.advice()) }
        defaults.register(defaults: [DefaultsKey.autoCompile: true, DefaultsKey.showWordCount: true, DefaultsKey.showSource: true,
                                     DefaultsKey.showPDF: true, DefaultsKey.editorFontSize: 13, DefaultsKey.editorLineNumbers: true,
                                     DefaultsKey.editorAutoPair: true, DefaultsKey.editorAutoComplete: true,
                                     DefaultsKey.editorSpellCheck: true])
        defaults.removeObject(forKey: "editorSyntaxTheme") // the Overleaf, TeXstudio or System choice, now always System
        func choice<T: RawRepresentable<String>>(_ key: String, _ fallback: T) -> T {
            defaults.string(forKey: key).flatMap { T(rawValue: $0) } ?? fallback
        }
        autoCompile = defaults.bool(forKey: DefaultsKey.autoCompile)
        showWordCount = defaults.bool(forKey: DefaultsKey.showWordCount)
        recentProjects = defaults.stringArray(forKey: DefaultsKey.recentProjects) ?? []
        recentSymbols = defaults.stringArray(forKey: DefaultsKey.recentSymbols) ?? []
        launchProject = defaults.string(forKey: DefaultsKey.openProject)
        fontName = defaults.string(forKey: DefaultsKey.editorFontName) ?? ""
        fontSize = defaults.integer(forKey: DefaultsKey.editorFontSize)
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

    func opened(_ window: WindowModel) { windows.append(window) }

    func closed(_ window: WindowModel) {
        windows.removeAll { $0 === window }
        if window.project != nil, !windows.contains(where: { $0.project != nil }) { showHome() }
    }

    func cameForward(_ window: WindowModel) {
        guard windows.first !== window, let at = windows.firstIndex(where: { $0 === window }) else { return }
        windows.insert(windows.remove(at: at), at: 0)
    }

    var front: WindowModel { main ?? windows.first ?? showHome() }

    @discardableResult
    func showHome() -> WindowModel {
        let home = home ?? openWindow(nil)
        home.controller?.show()
        return home
    }

    func openWindow(_ id: String?) -> WindowModel {
        if let newWindow { return newWindow(id) }
        let window = WindowModel(app: self)
        window.project = id.map { ProjectModel(id: $0, window: window) }
        return window
    }

    func window(showing id: String) -> WindowModel? { windows.first { $0.shownProject?.id == id } }

    func canChange(_ project: ProjectInfo) -> Bool { !project.opened && window(showing: project.id) == nil }

    func visited(_ id: String) {
        recentProjects = Array(([id] + recentProjects.filter { $0 != id }).prefix(recentLimit()))
    }

    func retryLibrary() async {
        core.reopen()
        await reloadProjects()
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

    func refreshTeXStatus() async { _ = try? await core.call(CheckTex()) }

    func setTeXFolder(_ path: String?, texpresso: Bool) async throws {
        if texpresso { try await setTeX(SetTexpressoDir(dir: path)) } else { try await setTeX(SetTexDir(dir: path)) }
    }

    func installTeX() async throws {
        installingTeX = true
        defer { installingTeX = false }
        try await setTeX(InstallTex())
    }

    private func setTeX<R: LibraryRequest>(_ request: R) async throws {
        settingTeX = true
        defer { settingTeX = false }
        try await core.call(request)
    }

    static let openableTypes: [UTType] = [.folder, .zip] + [UTType(filenameExtension: "tex")].compactMap(\.self)

    static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard let type = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentTypeKey]).contentType else { return true }
        return openableTypes.contains { type.conforms(to: $0) }
    }

    func openPath(_ url: URL) async throws -> Opening {
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

    func forget(_ project: ProjectInfo) async throws {
        try await core.call(ForgetFolder(id: project.id))
        bookmarks[project.id] = nil
        recentProjects.removeAll { $0 == project.id }
    }

    func rename(_ id: String, to name: String) async throws -> ProjectInfo {
        let renamed = try await core.call(RenameProject(id: id, name: name))
        recentProjects = recentProjects.map { $0 == id ? renamed.id : $0 }
        return renamed
    }

    func quit() async -> Bool {
        for window in windows where window.project?.isOpen == true {
            guard await window.project?.saveBeforeLeaving() != false else {
                window.controller?.show()
                return false
            }
        }
        for window in windows {
            guard await window.end() else {
                for ended in windows where ended.project?.closed == true { ended.controller?.close() }
                window.controller?.show()
                return false
            }
        }
        _ = try? await core.call(KillAll())
        return true
    }
}
