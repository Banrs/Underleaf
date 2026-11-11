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
    var isMain = false { didSet { if isMain { app.cameForward(self) } } }
    @ObservationIgnored weak var controller: (any AppWindow)?

    var showSource: Bool { didSet { keepLayout() } }
    var showPDF: Bool { didSet { keepLayout() } }
    @ObservationIgnored private let layoutKey: String?

    init(app: AppModel, project id: String? = nil) {
        self.app = app
        let defaults = app.defaults
        layoutKey = id.map { "Layout \($0)" }
        showSource = defaults.bool(forKey: DefaultsKey.showSource) || !defaults.bool(forKey: DefaultsKey.showPDF)
        showPDF = defaults.bool(forKey: DefaultsKey.showPDF)
        if let kept = layoutKey.flatMap({ defaults.string(forKey: $0) }).flatMap(WorkspaceLayout.init) {
            (showSource, showPDF) = (kept != .pdf, kept != .source)
        }
        app.opened(self)
    }

    private func keepLayout() {
        app.defaults.set(showSource, forKey: DefaultsKey.showSource)
        app.defaults.set(showPDF, forKey: DefaultsKey.showPDF)
        if let layoutKey { app.defaults.set(layout.rawValue, forKey: layoutKey) }
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
        if let renamed = await renameProject(project, to: name) { registerRenameUndo(current: renamed, previous: project) }
    }

    private func renameProject(_ project: ProjectInfo, to name: String) async -> ProjectInfo? {
        await alerting("Couldn’t Rename “\(project.name)”") { try await app.rename(project.id, to: name) }
    }

    private func registerRenameUndo(current: ProjectInfo, previous: ProjectInfo) {
        undoManager?.registerAsyncUndo(withTarget: self, actionName: String(localized: "Rename"), reversal: {
            self.registerRenameUndo(current: previous, previous: current)
        }, work: {
            await self.renameProject(current, to: previous.name) != nil
        })
    }

    func duplicate(_ project: ProjectInfo) async -> String? {
        let copy = await alerting("Couldn’t Duplicate “\(project.name)”") {
            try await app.core.call(DuplicateProject(id: project.id, name: String(localized: "\(project.name) copy")))
        }
        return copy?.id
    }

    func delete(_ project: ProjectInfo) async {
        let item = UndoableTrash(undoManager: undoManager, trash: { [weak self] in
            guard let self, let trashed = await alerting("Couldn’t Move “\(project.name)” to the Trash", {
                try await app.core.call(TrashProject(id: project.id))
            }) else { return nil }
            app.recentProjects.removeAll { $0 == project.id }
            return trashed
        }, putBack: { [weak self] trashed in
            guard let self else { return false }
            return await alerting("Couldn’t Put “\(project.name)” Back") {
                try await app.core.call(PutBackProject(id: project.id, trashed: trashed))
            } != nil
        })
        await item.moveToTrash()
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

    func load(name: String? = nil) async -> Bool {
        guard let project else { return false }
        let loading = self.loading ?? Task { [self] in
            app.visited(project.id)
            do {
                try await project.load()
                return true
            } catch {
                controller?.close()
                app.front.report("Couldn’t Open “\(name ?? project.name)”", error)
                return false
            }
        }
        self.loading = loading
        return await loading.value && project.isOpen
    }

    func reopen() async {
        guard let project else { return }
        guard let target = try? await app.core.call(FindRestorationProject(id: project.id)) else {
            await close()
            return
        }
        let moved = target.missing ? await app.follow(project.id, deferRelist: true) : nil
        _ = await load(name: moved?.name ?? target.name)
    }

    @discardableResult
    func close() async -> Bool {
        guard await end() else { return false }
        controller?.close()
        return true
    }

    /// Joins a leave already under way, so a second Close waits for the first's questions instead of cancelling them.
    func end(discarding: Bool = false) async -> Bool {
        if let ending { return await ending.value }
        let task = Task { [self] in
            defer { ending = nil }
            return await leave(discarding: discarding)
        }
        ending = task
        return await task.value
    }

    func windowClosed() { app.closed(self) }

    /// Discarding when Quit has already been told to close without what can't be saved, and otherwise asking here.
    private func leave(discarding: Bool) async -> Bool {
        guard let project else { return true }
        var discarding = discarding
        if project.isOpen {
            if !discarding {
                guard let answer = await project.saveBeforeLeaving(), !Task.isCancelled else { return false }
                discarding = answer
            }
            project.savePlace()
        }
        return await project.close(discarding: discarding).value && !Task.isCancelled
    }
}
