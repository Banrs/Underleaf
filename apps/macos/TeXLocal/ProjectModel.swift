import Foundation
import Observation

protocol ProjectViews: AnyObject {
    var hasPDF: Bool { get }
    var zoom: Zoom { get }
    var shownVersion: Int { get }
    func heard(_ event: Event)
    func opened(_ ui: UiState) -> Task<Void, Never>?
    func reveal(_ path: String, line: Int?, column: Int?, length: Int?, atTop: Bool, focus: Bool)
    func apply(_ edits: DocumentEdits, named name: String) -> Bool
    func trashed(_ path: String)
    func beep()
    func perform(_ command: EditorCommand)
    func perform(_ command: MenuCommand)
    func validates(_ command: MenuCommand) -> Bool
    var inspectorShown: Bool { get }
}

@Observable
final class ProjectModel {
    let id: String
    let store: SessionStore
    let session: SessionClient
    private let listedName: String
    var name: String { store.project?.name ?? listedName }
    var settings: ProjectSettings? { store.project?.settings }
    var mainFile: String? {
        get { settings?.mainFile }
        set { if let newValue { setSettings(SettingsPatch(mainFile: newValue)) } }
    }
    var engine: Engine? {
        get { settings?.engine }
        set { if let newValue { setSettings(SettingsPatch(engine: newValue)) } }
    }
    var shellEscape: Bool {
        get { settings?.shellEscape ?? false }
        set { setSettings(SettingsPatch(shellEscape: newValue)) }
    }
    var stopOnFirstError: Bool {
        get { settings?.stopOnFirstError ?? false }
        set { setSettings(SettingsPatch(stopOnFirstError: newValue)) }
    }
    let tree: FileTree
    private(set) var initialLoadComplete = false
    var openPath: String? { store.openFile?.path }
    var openKind: FileKind? { store.openFile?.kind }
    private var analysis: Analysis? { isLaTeX ? store.outline : nil }
    var outline: [Heading] { analysis?.outline ?? [] }
    var outlineTree: [OutlineNode] { analysis?.tree ?? [] }
    var headingStyles: [HeadingStyle] { store.outline?.headingStyles ?? HeadingStyle.standard }
    var words: Int? { analysis?.words }
    private(set) var cursorLine = 1
    private(set) var cursorColumn = 0
    @ObservationIgnored private var topLine = 1
    @ObservationIgnored private(set) var topHeading: Int?
    private(set) var currentHeading: Int?
    @ObservationIgnored private var currentLine = 1
    @ObservationIgnored private var caretMoved = false
    @ObservationIgnored private(set) var caret: (path: String, offset: Int)?
    var trail = Trail()

    private var root: URL? { store.project.map { URL(filePath: $0.root, directoryHint: .isDirectory) } }
    @ObservationIgnored private var composingPath: String?

    var compiling: Bool { store.build?.compiling == true }
    var outdated: Bool { store.build?.outdated == true }
    var result: CompileResult? { store.build?.result }
    var issues: [LogItem] { store.build?.issues ?? [] }
    var listed: [LogItem] { store.build?.listed ?? [] }
    var fixing: Fix?
    var chosenIssue: Int?
    var hasPDF: Bool { views?.hasPDF == true }
    var livePDF: Bool { store.shownPdf?.live == true }
    var buildPDF: URL? { store.shownPdf?.path.map { URL(filePath: $0) } }
    let panel = BuildPanelModel()
    let texpresso: TeXpressoSession

    var openURL: URL? { openPath.flatMap(url) }
    private(set) var conflicts: [Conflict] = []
    private(set) var askingToDiscard: [String]?
    @ObservationIgnored private var discardAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var discarded = false
    private(set) var previewVersion = 0

    var importClash: ImportClash?

    var expandedFolders: Set<String> = [] {
        didSet { if expandedFolders != oldValue { saveUIState(UiPatch(expandedFolders: expandedFolders.sorted())) } }
    }
    var foldedHeadings: Set<String> = [] {
        didSet { if foldedHeadings != oldValue { saveUIState(UiPatch(foldedHeadings: foldedHeadings.sorted())) } }
    }

    let search = ProjectSearch()

    var sourceHasKeyboard = false
    @ObservationIgnored weak var window: WindowModel?
    @ObservationIgnored weak var views: (any ProjectViews)?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    private var closing: Task<Bool, Never>?
    var isOpen: Bool { !closed && closing == nil }
    @ObservationIgnored private var liveLogWatch: Task<Void, Never>?
    @ObservationIgnored var trashed: [UndoableTrash] = []
    @ObservationIgnored var exportFolder: URL?
    var closed: Bool { session.closed }

    init(id: String, window: WindowModel) {
        self.id = id
        let store = SessionStore()
        (self.store, tree, texpresso) = (store, FileTree(store: store), TeXpressoSession(store: store))
        session = SessionClient(core: window.app.core)
        listedName = window.app.projects.first { $0.id == id }?.name ?? id
        self.window = window
        liveLogWatch = track({ [panel] in panel.showsLiveLog }, initial: false) { [weak self] shown in
            guard let self else { return }
            session.send(LiveLog(shown: shown))
            if !shown { texpresso.logClosed() }
        }
        session.heard = { [weak self] in self?.handle($0) }
    }

    isolated deinit { liveLogWatch?.cancel() }

    var isLaTeX: Bool { openKind == .tex }
    var sourceToolsEnabled: Bool { isLaTeX && window?.showSource == true }

    var headingCommand: String { outline.first { $0.file == openPath && $0.line == cursorLine }?.command ?? "" }
    var editsText: Bool { openKind?.isText == true }

    var saveFailure: String? {
        for document in store.documents {
            let name = document.path.fileName
            switch (document.error, document.held) {
            case (let error?, _): return error.text
            case (nil, .changed): return String(localized: "Another app changed “\(name)”.")
            case (nil, .gone): return String(localized: "Another app moved or deleted “\(name)”.")
            case (nil, nil): continue
            }
        }
        return nil
    }

    func notSavedTitle(_ path: String? = nil) -> String { String(localized: "“\((path ?? openPath)?.fileName ?? name)” Wasn’t Saved") }

    var errorCount: Int { issues.count(where: \.isError) }
    var warningCount: Int { issues.count - errorCount }

    var showsLastSuccessfulBuild: Bool { hasPDF && result?.failed == true && result?.pdf == nil }

    @discardableResult
    func alerting<T>(_ title: @autoclosure () -> String, _ work: () async throws -> T) async -> T? {
        await window?.alerting(title(), work) ?? nil
    }

    let notices = ProjectNotices()

    func savePlace() { saveUIState(UiPatch(place: UiPlace(file: openPath, line: cursorLine, zoom: views?.zoom))) }

    func load() async {
        let ui: UiState
        do {
            ui = try await session.call(OpenProject(id: id, autoCompile: window?.app.autoCompile ?? false))
        } catch {
            session.discard()
            window?.report("Couldn’t Open “\(name)”", error)
            if window?.project === self { await window?.close() }
            return
        }
        (expandedFolders, foldedHeadings) = (Set(ui.expandedFolders), Set(ui.foldedHeadings))
        let pdfShown = views?.opened(ui)
        if let openPath { views?.reveal(openPath, line: openPath == ui.file ? ui.line : nil, column: nil, length: nil, atTop: false, focus: true) }
        await pdfShown?.value
        initialLoadComplete = true
    }

    func cursorMoved(to line: Int, column: Int, caret offset: Int, in path: String?) {
        caret = path.map { ($0, offset) }
        guard line != cursorLine || column != cursorColumn else { return }
        (cursorLine, cursorColumn, currentLine) = (line, column, line)
        if !caretMoved {
            caretMoved = true
            Task { [weak self] in self?.caretMoved = false }
        }
        findHeadings()
        liveCaret()
    }

    func scrolled(to line: Int) {
        guard line != topLine else { return }
        topLine = line
        findHeadings()
    }

    func autoCompileChanged() { session.send(SetOptions(autoCompile: window?.app.autoCompile ?? false)) }

    private func saveUIState(_ patch: UiPatch) { if initialLoadComplete { session.send(SetUiState(patch: patch)) } }

    func handle(_ event: Event) {
        switch event {
        case .section(let section): apply(section)
        case .documentReload, .renamed, .livePage, .liveDocument: break
        case .conflict(let asked):
            conflicts.removeAll { $0.path == asked.path }
            conflicts.append(asked)
        case .buildFinished(let finished): buildFinished(finished)
        case .filesChanged(let paths):
            if let openPath, !editsText, paths.contains(openPath) { previewVersion += 1 }
        case .liveAlert:
            texpresso.alerted()
            panel.show(.texpresso)
        }
        views?.heard(event)
    }

    private func apply(_ section: SessionSection) {
        let (before, build, live, problem) = (store.documents, store.build, livePDF, store.project?.problem)
        store.apply(section)
        switch section {
        case .project(let now):
            if let error = now.problem, error != problem { window?.report(String(localized: "Couldn’t Read the Project’s Settings"), error.text) }
        case .tree: break
        case .openFile, .outline: findHeadings()
        case .documents(let documents):
            for document in documents {
                guard let error = document.error, before.first(where: { $0.path == document.path })?.error == nil else { continue }
                window?.report(notSavedTitle(document.path), error.text)
            }
        case .build(let now): buildChanged(now, was: build)
        case .shownPdf(let shown):
            if shown.live, !live, window?.showPDF == false { window?.showPDF = true }
        case .live(let state): texpresso.heard(state)
        }
    }

    func open(_ path: String, line: Int? = nil, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true,
              jump: Bool = false) async {
        window?.showSource = true
        if jump, let from = caretPlace { trail.jumped(from: from) }
        guard let opened = await alerting("Couldn’t Open “\(path.fileName)”", { try await session.call(Open(path: path)) }) ?? nil,
              opened == openPath, editsText else { return }
        views?.reveal(opened, line: line, column: column, length: length, atTop: atTop, focus: focus)
    }

    func composing(_ composing: Bool, in path: String?) {
        guard let path = composing ? path : composingPath else { return }
        composingPath = composing ? path : nil
        session.send(Composing(path: path, composing: composing))
    }

    func url(_ path: String) -> URL? { root.map { $0.appending(path: path) } }

    func projectPath(_ url: URL) -> String? {
        guard let folder = root?.resolvingSymlinksInPath().pathComponents else { return nil }
        let inside = url.resolvingSymlinksInPath().pathComponents
        guard inside.count > folder.count, inside.starts(with: folder) else { return nil }
        return inside.dropFirst(folder.count).joined(separator: "/")
    }

    func copyFigure(_ url: URL) async -> String? {
        let folder = openPath?.parentFolder ?? ""
        let request = ImportFiles(dir: folder, paths: [url.path(percentEncoded: false)], conflict: .keepBoth)
        guard let made = await alerting("Couldn’t Add “\(url.lastPathComponent)”", { try await session.call(request) })
        else { return nil }
        let name = made.existing.first?.keepBoth ?? url.lastPathComponent, path = folder.isEmpty ? name : "\(folder)/\(name)"
        guard tree.node(at: path) != nil else { return nil }
        return includeGraphics(path)
    }

    func includeGraphics(_ path: String) -> String? { Syntax.call(IncludeGraphics(path: path, into: openPath ?? "")) ?? nil }

    @discardableResult
    func save(reporting: Bool = true) async -> Bool {
        do {
            return try await session.call(Save(reporting: reporting))
        } catch let error as CoreError where error.message.id == "no_such_session" {
            return discarded || lostEdits.isEmpty
        } catch {
            if reporting { window?.report(notSavedTitle(), error) }
            return error is CancellationError
        }
    }

    private var lostEdits: [String] { store.documents.filter { $0.error?.id == "stopped_unsaved" }.map(\.path) }

    func saveBeforeLeaving() async -> Bool {
        if await save() { return true }
        let lost = lostEdits
        guard !lost.isEmpty, discardAnswer == nil else { return false }
        window?.controller?.show()
        askingToDiscard = lost
        discarded = await withCheckedContinuation { discardAnswer = $0 }
        return discarded
    }

    func answerDiscard(_ discard: Bool) {
        askingToDiscard = nil
        discardAnswer.take()?.resume(returning: discard)
    }

    private func findHeadings() {
        let atTop = heading(at: topLine)
        if atTop != topHeading {
            topHeading = atTop
            if !caretMoved { currentLine = topLine }
        }
        let current = currentLine == topLine ? atTop : heading(at: currentLine)
        if current != currentHeading { currentHeading = current }
    }

    private func heading(at line: Int) -> Int? {
        guard let openPath else { return nil }
        return outline.lastIndex { $0.line <= line && $0.file.caseInsensitiveCompare(openPath) == .orderedSame }
    }

    func replaceAll() async {
        let asked = search.searched
        let replace = Replace(query: asked.query, replacement: search.replacement, matchCase: asked.matchCase, wholeWord: asked.wholeWords)
        guard let answer = await alerting("Couldn’t Replace “\(asked.query)”", {
            try await editProject(replace, named: String(localized: "Replace"))
        }) else { return }
        let count = (answer.edits?.edits.count ?? 0) + answer.written.reduce(0) { $0 + $1.count }
        let files = answer.written.count + (answer.edits == nil ? 0 : 1)
        notices.note(String(AttributedString(localized: "Replaced ^[\(count) match](inflect: true) in ^[\(files) file](inflect: true)")
            .characters))
        await search.run(in: session)
    }

    func findUsages(in path: String, at offset: Int) async {
        guard let found = await alerting("Couldn’t Find Usages", {
            try await session.call(FindUsages(path: path, offset: offset))
        }) else { return }
        guard let found else {
            views?.beep()
            return
        }
        search.show(found)
        window?.controller?.revealSidebar()
    }

    func quickHelp(in path: String, at offset: Int) async -> QuickHelp? {
        guard let answer = await alerting("Couldn’t Show Quick Help", {
            try await session.call(LookUp(path: path, offset: offset))
        }) else { return nil }
        if answer == nil { views?.beep() }
        return answer
    }

    private var caretPlace: Place? { openPath.map { Place(path: $0, line: editsText ? cursorLine : 1) } }

    func canRetrace(back: Bool) -> Bool { openPath != nil && (back ? trail.back : trail.forward).contains(where: exists) }

    private func exists(_ place: Place) -> Bool { root.map { FileManager.default.fileExists(atPath: $0.appending(path: place.path).path) } ?? false }

    func retrace(back: Bool) async {
        guard let at = caretPlace, let to = trail.step(back: back, from: at, exists: exists) else { return }
        await open(to.path, line: to.line)
    }

    func renameSymbol(_ symbol: Definition, to name: String) async throws {
        try await editProject(RenameSymbol(kind: symbol.kind, from: symbol.name, to: name), named: String(localized: "Rename"))
    }

    func saveVersion(named name: String) async throws {
        if let saved = try await session.call(SaveVersion(name: name)) { notices.note(String(localized: "Saved Version “\(saved.title)”")) }
    }

    func restoreVersion(_ snapshot: Snapshot, paths: [String]?) async throws {
        apply(try await session.call(RestoreVersion(id: snapshot.id, paths: paths)), named: String(localized: "Restore"))
    }

    @discardableResult
    private func editProject<R: SessionRequest>(_ request: R, named name: String) async throws -> ProjectEdits
        where R.Reply == ProjectEdits {
        let answer = try await session.call(request)
        if apply(answer.edits, named: name) { return answer }
        if let snapshot = answer.snapshot, !answer.written.isEmpty {
            try await session.call(RestoreVersion(id: snapshot, paths: answer.written.map(\.file)))
        }
        throw AppFailure(String(localized: "The file shown changed meanwhile, so nothing was changed. Try again."))
    }

    @discardableResult
    private func apply(_ edits: DocumentEdits?, named name: String) -> Bool {
        guard let edits else { return true }
        return views?.apply(edits, named: name) ?? false
    }

    func run(_ fix: Fix) async {
        fixing = fix
        defer { fixing = nil }
        guard let answer = await alerting("Couldn’t \(fix.title.text)", { try await session.call(ApplyFix(id: fix.id)) }) ?? nil else { return }
        apply(answer.edits, named: fix.title.text)
        await compile()
    }

    func answer(_ path: String, _ answer: Resolution) {
        conflicts.removeAll { $0.path == path }
        session.send(Resolve(path: path, answer: answer), else: reporting(notSavedTitle(path)))
    }

    @discardableResult
    func close() -> Task<Bool, Never> {
        if let closing { return closing }
        let task = Task { [self] in
            defer { closing = nil }
            do {
                guard try await session.close() else { return false }
            } catch {
                window?.report(notSavedTitle(), error)
                return false
            }
            let undo = window?.undoManager
            undo?.removeAllActions(withTarget: self)
            for item in trashed { undo?.removeAllActions(withTarget: item) }
            trashed = []
            removeExport()
            notices.cancel()
            return true
        }
        closing = task
        return task
    }

    private func setSettings(_ patch: SettingsPatch) {
        session.send(SetSettings(patch: patch), else: reporting("Couldn’t Change the Project’s Settings"))
    }

    private func reporting(_ title: String) -> (any Error) -> Void { { [weak self] in self?.window?.report(title, $0) } }

    func reveal(_ heading: Heading) {
        guard heading.file != openPath || cursorLine != heading.line || topLine != heading.line else { return }
        session.task { [self] in await open(heading.file, line: heading.line, atTop: true, focus: false, jump: true) }
    }
}
