import Accessibility
import Foundation
import Observation

@Observable
final class WindowModel {
    let app: AppModel
    var project: ProjectModel?
    var alert: AppAlert?
    var newProjectDraft: NewProjectDraft?
    var prompt: Prompt?
    var newEntry: NewEntry?
    var openingProject = false
    var addingFiles = false
    var exporting: ExportFile?
    var chosenItem: ItemActions?
    var isKey = false { didSet { if isKey { app.cameForward(self) } } }
    @ObservationIgnored weak var controller: (any AppWindow)?

    var showSource: Bool { didSet { app.defaults.set(showSource, forKey: DefaultsKey.showSource) } }
    var showPDF: Bool { didSet { app.defaults.set(showPDF, forKey: DefaultsKey.showPDF) } }
    var outlineCollapsed: Bool { didSet { app.defaults.set(outlineCollapsed, forKey: DefaultsKey.outlineCollapsed) } }

    init(app: AppModel) {
        self.app = app
        let defaults = app.defaults
        showSource = defaults.bool(forKey: DefaultsKey.showSource) || !defaults.bool(forKey: DefaultsKey.showPDF)
        showPDF = defaults.bool(forKey: DefaultsKey.showPDF)
        outlineCollapsed = defaults.bool(forKey: DefaultsKey.outlineCollapsed)
        app.opened(self)
    }

    var shownProject: ProjectModel? { project?.closed == false ? project : nil }

    func newProject(_ template: ProjectTemplate = .article) {
        guard app.libraryProblem == nil else { return }
        Task {
            let free = try? await app.core.call(FreeProjectName())
            newProjectDraft = NewProjectDraft(template: template, name: free ?? "Untitled")
        }
    }

    func create(name: String, template: ProjectTemplate) async throws {
        let info = try await app.core.call(CreateProject(name: name, template: template, engine: app.newProjectEngine))
        Task { await open(info.id) }
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

    private func showPanes(source: Bool, pdf: Bool) { (showSource, showPDF) = (source, pdf) }

    func requestPDF(_ action: PDFAction) {
        showPDF = true
        controller?.performPDF(action)
    }

    var undoManager: UndoManager? { controller?.undoManager }

    func open(_ urls: [URL]) async {
        for url in urls { await open(url, alone: urls.count == 1) }
    }

    func open(_ url: URL, alone: Bool = true) async {
        guard !importing.contains(url) else { return }
        importing.append(url)
        defer { importing.removeAll { $0 == url } }
        guard let opening = await alerting("Couldn’t Open “\(url.lastPathComponent)”", { try await app.openPath(url) }) else { return }
        guard alone else { return }
        importing.removeAll { $0 == url }
        let id = opening.project.id
        await open(id)
        if let file = opening.file, let project = app.window(showing: id)?.project { await project.open(file) }
    }

    func forget(_ project: ProjectInfo) async {
        await alerting("Couldn’t Remove “\(project.name)” from the List") { try await app.forget(project) }
    }

    func rename(_ project: ProjectInfo, to name: String) async {
        if let renamed = await renameProject(project.id, shown: project.name, to: name) {
            registerRenameUndo(current: (renamed.id, renamed.name), previous: (project.id, project.name))
        }
    }

    private func renameProject(_ id: String, shown: String, to name: String) async -> ProjectInfo? {
        await alerting("Couldn’t Rename “\(shown)”") { try await app.rename(id, to: name) }
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
            try await app.core.call(DuplicateProject(id: project.id, name: String(localized: "\(project.name) copy")))
        }
        return copy?.id
    }

    func delete(_ project: ProjectInfo) async {
        let failure = "Couldn’t Move “\(project.name)” to the Trash"
        guard app.canChange(project) else { return report(failure, "Close the project before moving it to the Trash.") }
        let item = UndoableTrash(
            original: project.folder, name: project.name, undoManager: undoManager,
            trash: { [weak self] item in
                do {
                    try item.recycle()
                    self?.app.recentProjects.removeAll { $0 == project.id }
                    return true
                } catch {
                    self?.report(failure, error)
                    return false
                }
            },
            changed: { [weak self] in await self?.app.reloadProjects() },
            failed: { [weak self] title, error in self?.report(title, error) })
        await item.moveToTrash()
        await app.reloadProjects()
    }

    @discardableResult
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

    @ObservationIgnored private var loading: Task<Bool, Never>?
    @ObservationIgnored private var ending: Task<Bool, Never>?
    private(set) var importing: [URL] = []

    func open(_ id: String) async {
        let window = app.window(showing: id) ?? app.openWindow(id)
        guard await window.load() else { return }
        window.controller?.show()
        app.home?.controller?.close()
    }

    func load() async -> Bool {
        guard let project else { return false }
        let loading = self.loading ?? Task { [self] in
            app.visited(project.id)
            do {
                try await project.load()
                return true
            } catch {
                controller?.close()
                app.front.report("Couldn’t Open “\(project.name)”", error)
                return false
            }
        }
        self.loading = loading
        return await loading.value && project.isOpen
    }

    func reopen() async {
        guard let project else { return }
        if app.projects.contains(where: { $0.id == project.id }) { _ = await load() } else { await close() }
    }

    @discardableResult
    func close() async -> Bool {
        guard await end() else { return false }
        controller?.close()
        return true
    }

    func end() async -> Bool { await restart(&ending, leave).value }

    func windowClosed() { app.closed(self) }

    private func leave() async -> Bool {
        guard let project else { return true }
        if project.isOpen {
            guard await project.saveBeforeLeaving(), !Task.isCancelled else { return false }
            project.savePlace()
        }
        return await project.close().value && !Task.isCancelled
    }
}
