import AppKit
import Observation
import UniformTypeIdentifiers

@Observable
final class ProjectModel {
    let id: String
    private(set) var name: String
    var settings: ProjectSettings?
    let tree: FileTree
    private(set) var initialLoadComplete = false
    var openPath: String? { didSet { if openPath != oldValue { openKindChanged() } } }
    private(set) var openKind: FileKind?
    private(set) var outline: [OutlineItem] = []
    private(set) var outlineTree: [OutlineNode] = []
    private(set) var headingStyles = HeadingStyle.standard
    var words: Int?
    var cursorLine = 1
    var cursorColumn = 0
    @ObservationIgnored var topLine = 1
    @ObservationIgnored private(set) var topHeading: Int?
    private(set) var currentHeading: Int?
    @ObservationIgnored private var currentLine = 1
    @ObservationIgnored private var caretMoved = false
    var trail = Trail()

    @ObservationIgnored private(set) var session: UInt64?
    @ObservationIgnored private var root: URL?
    private var documents: [String: OpenDocument] = [:]
    private struct OpenDocument {
        var state: DocumentState?
        var heldReason: String?
        var lineIssues: [Int: IssuesEvent.Line] = [:], liveIssues: [Int: IssuesEvent.Line] = [:]
    }
    @ObservationIgnored private var composingPath: String?
    @ObservationIgnored private var treeChanged = false

    var compiling = false
    var outdated = false
    var fixing: LogItem.Fix?
    var result: CompileResult?
    var checks: [LogItem] = []
    var chosenIssue: Int?
    nonisolated enum ShownPDF: Equatable { case none, build(URL), live }
    var shown = ShownPDF.none
    var hasPDF: Bool { shown != .none }
    var livePDF: Bool { shown == .live }
    var buildPDF: URL?
    let pdf = PDFController()
    let panel = BuildPanelModel()
    let texpresso = TeXpressoSession()

    var issues: [LogItem] { (result?.errors ?? []) + (result?.warnings ?? []) + checks }
    var listed: [LogItem] { issues + (result?.badBoxes ?? []) }

    var openURL: URL? { openPath.flatMap(url) }
    var diskConflict: String?
    var missingFile: String?
    private(set) var previewVersion = 0

    var importClash: ImportClash?

    var expandedFolders: Set<String> = [] {
        didSet { if expandedFolders != oldValue { saveUIState(["expandedFolders": expandedFolders.sorted()]) } }
    }
    var foldedHeadings: Set<String> = [] {
        didSet { if foldedHeadings != oldValue { saveUIState(["foldedHeadings": foldedHeadings.sorted()]) } }
    }
    @ObservationIgnored private var showingUIState = false
    @ObservationIgnored var uiStateWrites: Task<Void, Never>?

    let search = ProjectSearch()

    let editor = SourceEditor()
    private(set) var sourceHasKeyboard = false
    @ObservationIgnored weak var app: AppModel?
    let core = Core.shared
    @ObservationIgnored private var analysis: Analysis?
    @ObservationIgnored private var opens: Task<Void, Never>?
    @ObservationIgnored private var openRequests = 0
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var pdfLoad: Task<Bool, Never>?
    @ObservationIgnored private var buildLane: Task<Void, Never>?
    private var closing: Task<Bool, Never>?
    var isClosing: Bool { closing != nil }
    @ObservationIgnored private var liveLogWatch: Task<Void, Never>?
    @ObservationIgnored var trashed: [UndoableTrash] = []
    @ObservationIgnored var exportFolder: URL?
    private(set) var closed = false

    init(id: String, app: AppModel) {
        self.id = id
        name = app.projects.first { $0.id == id }?.name ?? id
        self.app = app
        tree = FileTree(id: id)
        liveLogWatch = track({ [panel] in panel.showsLiveLog }, initial: false) { [weak self] shown in
            guard let self else { return }
            if let session { core.send("session_live_log", ["session": session, "shown": shown]) }
            if !shown { texpresso.logClosed() }
        }
        tree.onChange = { [weak self] in self?.openKindChanged() }
        pdf.onVisiblePages = { [weak self] in self?.liveView($0) }
    }

    var isLaTeX: Bool { openKind == .tex }
    var sourceToolsEnabled: Bool { isLaTeX && app?.showSource == true }

    var headingCommand: String { outline.first { $0.file == openPath && $0.line == cursorLine }?.command ?? "" }
    var editsText: Bool { openKind?.isText == true }

    private func openKindChanged() {
        defer { showOutline() }
        guard let openPath else { return openKind = nil }
        if let kind = tree.node(at: openPath)?.kind, kind != openKind { openKind = kind }
    }

    func isText(_ path: String) -> Bool { tree.node(at: path)?.kind?.isText == true }

    var saveFailure: String? {
        for (path, document) in documents.sorted(by: { $0.key < $1.key }) {
            if let error = document.state?.error { return error }
            if document.state?.held == true { return document.heldReason ?? String(localized: "“\(path.fileName)” wasn’t saved.") }
        }
        return nil
    }

    func notSavedTitle(_ path: String? = nil) -> String { String(localized: "“\((path ?? openPath)?.fileName ?? name)” Wasn’t Saved") }

    var errorCount: Int { issues.count(where: \.isError) }
    var warningCount: Int { issues.count - errorCount }

    var showsLastSuccessfulBuild: Bool { hasPDF && result?.failed == true && result?.pdf == nil }

    @discardableResult
    func alerting<T>(_ title: @autoclosure () -> String, _ work: () async throws -> T) async -> T? {
        await app?.alerting(title(), unless: { closed }, work) ?? nil
    }

    let notices = ProjectNotices()

    func savePlace() async {
        guard initialLoadComplete else { return }
        saveUIState(["file": openPath, "line": cursorLine, "page": pdf.keptPage, "zoom": pdf.keptZoom.json, "panel": panel.shown])
        await uiStateWrites?.value
    }

    func load() async {
        connectEditor()
        let session = core.observe { [weak self] event in self?.handle(event) }
        async let pdfShown = showBuildPDF(try? await core.call("pdf_path", ["id": id], as: String.self))
        let ui: UIState
        do {
            let opened = try await core.call("session_open", ["id": id, "session": session, "autoCompile": app?.autoCompile ?? false],
                                             as: SessionOpened.self)
            guard !closed else { throw CancellationError() }
            self.session = session
            name = opened.name
            root = URL(filePath: opened.root, directoryHint: .isDirectory)
            settings = opened.settings
            ui = opened.ui
            showUIState(ui)
            (panel.shown, pdf.restorePage, pdf.restoreZoom) = (ui.panel, ui.page, ui.zoom)
            if !treeChanged { tree.show(opened.tree) }
            let restored = ui.file.flatMap { tree.node(at: $0) == nil ? nil : $0 }
            if let file = restored ?? settings?.mainFile { await open(file, line: restored == nil ? nil : ui.line, showsSource: false) }
        } catch {
            core.forget(session)
            core.send("session_close", ["session": session])
            guard !closed else { return }
            app?.report(error, "Couldn’t Open “\(name)”")
            if app?.project === self { await app?.close() }
            return
        }
        _ = await pdfShown
        guard !closed else { return }
        initialLoadComplete = true
        if ui.livePreview, canSwitchLivePreview { livePreview = true }
    }

    private func connectEditor() {
        editor.onCursor = { [weak self] line, column in
            guard let self, line != cursorLine || column != cursorColumn else { return }
            cursorLine = line
            cursorColumn = column
            currentLine = line
            if !caretMoved {
                caretMoved = true
                Task { [weak self] in self?.caretMoved = false }
            }
            findHeadings()
            liveCaret()
        }
        editor.textView.composing = { [weak self] composing in self?.composing(composing) }
        editor.textView.keyboardChanged = { [weak self] in self?.sourceHasKeyboard = $0 }
        editor.onScroll = { [weak self] line in
            guard let self, line != topLine else { return }
            topLine = line
            findHeadings()
        }
        editor.textView.fileDrop = { [weak self] in self?.dropped($0) }
        editor.textView.issues.clicked = { [weak self] line in
            guard let self else { return }
            if let index = editor.textView.issues.lines[line]?.index {
                panel.show(.issues)
                chooseIssue(index, focus: false, open: false)
            } else if editor.textView.issues.live[line] != nil {
                panel.show(.texpresso)
            }
        }
        editor.textView.headings = { [weak self] in
            guard let self else { return [] }
            return outline.filter { $0.file == self.openPath }.map { ($0.line, $0.title) }
        }
        editor.textView.forwardSync = { [weak self] quietly in
            guard let self, hasPDF, isLaTeX, !quietly || app?.showPDF == true else { return nil }
            return { Task { await self.forwardSync(quietly: quietly) } }
        }
        editor.textView.openDefinition = { [weak self] place in
            Task { await self?.open(place.file, line: place.line, column: place.column, length: place.length, jump: true) }
        }
        editor.textView.quickHelp = { [weak self] offset in Task { await self?.quickHelp(at: offset) } }
        editor.command = { [weak self] in self?.app?.perform($0, on: self) }
    }

    func autoCompileChanged() {
        guard let session, !closed else { return }
        core.send("session_set_options", ["session": session, "autoCompile": app?.autoCompile ?? false])
    }

    private func saveUIState(_ patch: [String: any Sendable]) {
        guard !showingUIState, !closed else { return }
        _ = enqueue(&uiStateWrites) { [core, id] in try? await core.call("set_ui_state", ["id": id, "patch": patch]) }
    }

    func showUIState(_ state: UIState) {
        showingUIState = true
        (expandedFolders, foldedHeadings) = (Set(state.expandedFolders), Set(state.foldedHeadings))
        showingUIState = false
    }

    func handle(_ event: SessionEvent) {
        guard !closed else { return }
        switch event {
        case .document(let state): documentChanged(state)
        case .outline(let analysis):
            self.analysis = analysis
            showOutline()
        case .reload(let reloaded): reload(reloaded)
        case .closed(let gone):
            documents[gone.path] = nil
            if openPath == gone.path, gone.reason != "closed" { clearOpenFile() }
        case .renamed(let renamed):
            documents[renamed.to] = documents.removeValue(forKey: renamed.from)
        case .conflict(let asked) where asked.kind == .changed: diskConflict = asked.path
        case .conflict(let asked): missingFile = asked.path
        case .issues(let marked):
            documents[marked.path, default: OpenDocument()].lineIssues = marked.byLine
            if editor.path == marked.path { editor.textView.issues.lines = marked.byLine }
        case .liveIssues(let marked):
            documents[marked.path, default: OpenDocument()].liveIssues = marked.byLine
            if editor.path == marked.path { editor.textView.issues.live = marked.byLine }
        case .checks(let found): inOrder { self.checks = found.items }
        case .build(let state): inOrder { self.buildChanged(state) }
        case .buildFinished(let finished): inOrder { await self.buildFinished(finished) }
        case .buildCleaned: inOrder { self.buildCleaned() }
        case .tree(let listed):
            treeChanged = true
            tree.show(listed.tree)
            if let openPath, !editsText, tree.node(at: openPath) == nil { clearOpenFile() }
            if let main = Self.mainMarked(in: listed.tree), let current = settings?.mainFile, main != current {
                settings?.mainFile = main
                mainFileChanged()
            }
        case .filesChanged(let changed):
            if let openPath, !editsText, changed.paths.contains(openPath) { previewVersion += 1 }
        case .live(let state): liveChanged(state)
        case .livePDF(let read): showLive(read)
        }
    }

    private static func mainMarked(in nodes: [TreeNode]) -> String? {
        nodes.lazy.compactMap { $0.main == true ? $0.path : mainMarked(in: $0.children ?? []) }.first
    }

    private func documentChanged(_ state: DocumentState) {
        let before = documents[state.path]?.state
        documents[state.path, default: OpenDocument()].state = state
        if !state.held { documents[state.path]?.heldReason = nil }
        if let error = state.error, before?.error == nil {
            let title = notSavedTitle(state.path)
            if let app, app.alert == nil, !closed { app.alert = AppAlert(title, error) } else { notices.announce(title) }
        }
    }

    private func reload(_ event: ReloadEvent) {
        if editor.path == event.path {
            editor.reload(text: event.text)
        } else if let session, let source = SourceDocument(session: session, path: event.path) {
            source.reload(event.text)
        }
    }

    @discardableResult func inOrder(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> { enqueue(&buildLane, work) }

    func open(_ path: String, line: Int? = nil, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true,
              jump: Bool = false, showsSource: Bool = true) async {
        openRequests += 1
        let request = openRequests
        let latest = { request == self.openRequests && !self.closed }
        await enqueue(&opens) { [self] in
            guard latest() else { return }
            if showsSource { app?.showSource = true }
            if jump, let from = caretPlace { trail.jumped(from: from) }
            if path != openPath {
                guard let session else { return }
                if tree.node(at: path) == nil { await tree.reload() }
                let text = isText(path)
                do {
                    if text { try await core.call("session_open_document", ["session": session, "path": path]) }
                } catch {
                    if latest() { app?.report(error, "Couldn’t Open “\(path.fileName)”") }
                    return
                }
                guard latest() else {
                    if text { core.send("session_close_document", ["session": session, "path": path]) }
                    return
                }
                let was = editsText ? openPath : nil
                show(path, focus: focus)
                if let was { await closeDocument(was) }
            }
            if let line, editsText, latest() { editor.reveal(line: line, column: column, length: length, atTop: atTop, focus: focus) }
        }.value
    }

    private func show(_ path: String, focus: Bool) {
        openPath = path
        guard editsText else { return }
        guard let session, let source = SourceDocument(session: session, path: path) else { openPath = nil; return }
        editor.open(path: path, text: source.text, source: source, focus: focus)
        editor.textView.issues.lines = documents[path]?.lineIssues ?? [:]
        editor.textView.issues.live = documents[path]?.liveIssues ?? [:]
    }

    func closeDocument(_ path: String) async {
        guard let session else { return }
        await alerting(notSavedTitle(path)) { try await core.call("session_close_document", ["session": session, "path": path]) }
    }

    private func composing(_ composing: Bool) {
        guard let session, let path = composing ? editor.path : composingPath else { return }
        composingPath = composing ? path : nil
        core.send("session_composing", ["session": session, "path": path, "composing": composing])
    }

    func url(_ path: String) -> URL? { root.map { $0.appending(path: path) } }

    func projectPath(_ url: URL) -> String? {
        guard let folder = root?.resolvingSymlinksInPath().pathComponents else { return nil }
        let inside = url.resolvingSymlinksInPath().pathComponents
        guard inside.count > folder.count, inside.starts(with: folder) else { return nil }
        return inside.dropFirst(folder.count).joined(separator: "/")
    }

    private func dropped(_ url: URL) -> SourceTextView.FileDrop? {
        let into = openKind?.rawValue ?? ""
        guard let path = projectPath(url) else {
            let type = UTType(filenameExtension: url.pathExtension)
            let kind = type?.conforms(to: .pdf) == true ? "pdf" : type?.conforms(to: .image) == true ? "image" : ""
            return Self.includeGraphics(url.lastPathComponent, kind: kind, into: into) == nil ? nil
                : .copy { [weak self] in await self?.copyFigure(url) }
        }
        guard let kind = tree.node(at: path)?.kind else { return nil }
        if let insert = Self.includeGraphics(path, kind: kind.rawValue, into: into) { return .insert(insert) }
        return .open { [weak self] in Task { await self?.open(path) } }
    }

    private func copyFigure(_ url: URL) async -> String? {
        let folder = openPath?.parentFolder ?? ""
        let args: [String: any Sendable] = ["id": id, "dir": folder, "paths": [url.path(percentEncoded: false)], "conflict": "keepBoth"]
        guard let made = await alerting("Couldn’t Add “\(url.lastPathComponent)”", {
            try await core.call("import_files", args, as: Imported.self)
        }) else { return nil }
        await tree.reload()
        let name = made.existing.first?.keepBoth ?? url.lastPathComponent, path = folder.isEmpty ? name : "\(folder)/\(name)"
        guard let kind = tree.node(at: path)?.kind else { return nil }
        return Self.includeGraphics(path, kind: kind.rawValue)
    }

    static func includeGraphics(_ path: String, kind: String, into: String = "tex") -> String? {
        guard into == "tex", ["image", "pdf"].contains(kind),
              ["png", "jpg", "jpeg", "pdf"].contains((path as NSString).pathExtension.lowercased()) else { return nil }
        var depth = 0
        for character in path {
            switch character {
            case "%", "#", "\\": return nil
            case "{": depth += 1
            case "}": depth -= 1; if depth < 0 { return nil }
            default: break
            }
        }
        return depth == 0 ? "\\includegraphics{\(path)}" : nil
    }

    @discardableResult
    func save(reporting: Bool = true) async -> Bool {
        guard let session, !closed else { return true }
        do {
            return try await core.call("session_save", ["session": session, "reporting": reporting], as: Saved.self).saved
        } catch {
            if reporting, !closed { app?.report(error, notSavedTitle()) }
            return false
        }
    }

    private func showOutline() {
        if isLaTeX, let analysis {
            (outline, outlineTree, headingStyles, words) = (analysis.outline, analysis.tree, analysis.headingStyles, analysis.words)
        } else {
            (outline, outlineTree, words) = ([], [], nil)
        }
        findHeadings()
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
        return outline.last { $0.line <= line && $0.file.caseInsensitiveCompare(openPath) == .orderedSame }?.id
    }

    func replaceAll() async {
        guard let session else { return }
        let asked = search.searched
        let args = asked.arguments.merging(["session": session, "replacement": search.replacement]) { $1 }
        guard let answer = await alerting("Couldn’t Replace “\(asked.query)”", {
            try await editProject("session_replace", args, named: String(localized: "Replace"))
        }) else { return }
        let count = (answer.edits?.edits.count ?? 0) + answer.written.reduce(0) { $0 + $1.count }
        let files = answer.written.count + (answer.edits == nil ? 0 : 1)
        notices.note(String(AttributedString(localized: "Replaced ^[\(count) match](inflect: true) in ^[\(files) file](inflect: true)")
            .characters))
        await search.run(in: session)
    }

    func findUsages() async {
        guard let session, let path = editor.path else { return }
        let offset = editor.textView.selection.location
        guard let found = await alerting("Couldn’t Find Usages", {
            try await core.call("session_usages", ["session": session, "path": path, "offset": offset], as: Usages?.self)
        }) else { return }
        guard let found else {
            NSSound.beep()
            return
        }
        search.show(found)
        app?.sidebarShown = true
    }

    func quickHelp(at offset: Int) async {
        guard let session, let path = editor.path else { return }
        guard let answer = await alerting("Couldn’t Show Quick Help", {
            try await core.call("session_quick_help", ["session": session, "path": path, "offset": offset], as: QuickHelp?.self)
        }), editor.path == path else { return }
        guard let help = answer else {
            NSSound.beep()
            return
        }
        editor.textView.showQuickHelp(help, at: offset)
    }

    private var caretPlace: Place? { openPath.map { Place(path: $0, line: editsText ? cursorLine : 1) } }

    func canRetrace(back: Bool) -> Bool { openPath != nil && (back ? trail.back : trail.forward).contains(where: exists) }

    private func exists(_ place: Place) -> Bool { root.map { FileManager.default.fileExists(atPath: $0.appending(path: place.path).path) } ?? false }

    func retrace(back: Bool) async {
        guard let at = caretPlace, let to = trail.step(back: back, from: at, exists: exists) else { return }
        await open(to.path, line: to.line)
    }

    func renameSymbol(_ symbol: Definition, to name: String) async throws {
        guard let session else { return }
        try await editProject("session_rename_symbol", ["session": session, "kind": symbol.kind, "from": symbol.name, "to": name],
                              named: String(localized: "Rename"))
    }

    func saveVersion(named name: String) async throws {
        guard let session else { return }
        let saved = try await core.call("session_history_save", ["session": session, "name": name], as: Snapshot.self)
        notices.note(String(localized: "Saved Version “\(saved.title)”"))
    }

    func restoreVersion(_ snapshot: Snapshot, paths: [String]?) async throws {
        guard let session else { return }
        apply(try await core.call("session_history_restore", ["session": session, "id": snapshot.id, "paths": paths], as: Edited.self).edits,
              named: String(localized: "Restore"))
    }

    @discardableResult
    private func editProject(_ command: String, _ args: [String: any Sendable], named name: String) async throws -> ProjectEdits {
        let answer = try await core.call(command, args, as: ProjectEdits.self)
        if apply(answer.edits, named: name) { return answer }
        if let session, let snapshot = answer.snapshot, !answer.written.isEmpty {
            _ = try await core.call("session_history_restore", ["session": session, "id": snapshot, "paths": answer.written.map(\.file)],
                                    as: Edited.self)
        }
        throw CoreError(message: String(localized: "The file shown changed meanwhile, so nothing was changed. Try again."))
    }

    @discardableResult
    private func apply(_ edits: ProjectEdits.Document?, named name: String) -> Bool {
        guard let edits else { return true }
        guard edits.path == editor.path, edits.version == editor.textView.document.version else { return false }
        editor.textView.apply(edits.edits, named: name)
        return true
    }

    func run(_ fix: LogItem.Fix) async {
        guard let session else { return }
        fixing = fix
        defer { fixing = nil }
        let answer: Edited?
        do {
            answer = try await core.call("session_fix", ["session": session, "id": fix.id], as: Edited?.self)
        } catch {
            if !closed { app?.report(error, "Couldn’t \(fix.title)") }
            return
        }
        guard let answer, !closed else { return }
        apply(answer.edits, named: fix.title)
        if let updated = answer.settings { settings = updated }
        await compile()
    }

    func answer(_ path: String, _ answer: String, holding reason: String? = nil) {
        if diskConflict == path { diskConflict = nil }
        if missingFile == path { missingFile = nil }
        if let reason { documents[path, default: OpenDocument()].heldReason = reason }
        if answer == "close", openPath == path { clearOpenFile() }
        guard let session else { return }
        Task {
            await alerting(notSavedTitle(path)) {
                try await core.call("session_resolve", ["session": session, "path": path, "answer": answer])
            }
        }
    }

    @discardableResult
    func close() -> Task<Bool, Never> {
        if let closing { return closing }
        guard !closed else { return Task { true } }
        let editable = editor.textView.isEditable
        editor.textView.isEditable = false
        let task = Task { [self] in
            defer {
                closing = nil
                if !closed { editor.textView.isEditable = editable }
            }
            await uiStateWrites?.value
            if let session {
                do {
                    guard try await core.call("session_close", ["session": session], as: Saved.self).saved else { return false }
                } catch {
                    app?.report(error, notSavedTitle())
                    return false
                }
                core.forget(session)
            }
            closed = true
            let undo = app?.undoManager
            undo?.removeAllActions(withTarget: self)
            for item in trashed { undo?.removeAllActions(withTarget: item) }
            trashed = []
            removeExport()
            notices.cancel()
            tree.close()
            syncTask?.cancel()
            pdfLoad?.cancel()
            liveLogWatch?.cancel()
            pdf.endLiveRun()
            return true
        }
        closing = task
        return task
    }

    @ObservationIgnored private var settingsPatches = 0

    @discardableResult func patchSettings(_ change: SettingsChange) async -> Bool {
        guard let session, !closed else { return false }
        settingsPatches += 1
        let patch = settingsPatches, before = settings
        if settings != nil { change.apply(&settings!) }
        let latest = { patch == self.settingsPatches }
        guard let updated = await alerting("Couldn’t Change the Project’s Settings", {
            try await core.call("session_set_settings", ["session": session, "patch": change.patch], as: ProjectSettings.self)
        }) else {
            if !closed, latest() { settings = before }
            return false
        }
        guard !closed else { return false }
        if latest() { settings = updated }
        if updated.mainFile != before?.mainFile { mainFileChanged() }
        return true
    }

    func mainFileChanged() {
        Task { if let path = try? await core.call("pdf_path", ["id": id], as: String.self) { await showBuildPDF(path) } }
    }

    func reveal(_ item: OutlineItem) {
        guard item.file != openPath || cursorLine != item.line || topLine != item.line else { return }
        Task { await open(item.file, line: item.line, atTop: true, focus: false, jump: true) }
    }
}

private nonisolated struct ProjectEdits: Decodable {
    nonisolated struct Document: Decodable {
        var path: String
        var version: Int
        var edits: [TextEdit]
    }

    nonisolated struct Written: Decodable {
        var file: String
        var count: Int
    }

    var edits: Document?
    var written: [Written]
    var snapshot: String?
}

private nonisolated struct Edited: Decodable {
    let edits: ProjectEdits.Document?
    let settings: ProjectSettings?
}
