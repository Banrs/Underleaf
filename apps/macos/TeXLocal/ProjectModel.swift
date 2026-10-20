import AppKit
import Observation

/// A project's window state over its core session (docs/core-api.md), which owns its text, saves, builds and Live Preview.
@Observable
final class ProjectModel {
    let id: String
    var settings: ProjectSettings?
    let tree: FileTree
    private(set) var initialLoadComplete = false
    var openPath: String? { didSet { if openPath != oldValue { openKindChanged() } } }
    /// Kept while the tree hasn't the file yet (a rename) or has it no longer (gone).
    private(set) var openKind: FileKind?
    /// `outlineTree`'s headings in order, each at its `id`.
    private(set) var outline: [OutlineItem] = []
    private(set) var outlineTree: [OutlineNode] = []
    private(set) var headingStyles = HeadingStyle.standard
    var words: Int?
    var cursorLine = 1
    var cursorColumn = 0
    @ObservationIgnored var topLine = 1
    @ObservationIgnored private(set) var topHeading: Int?
    /// The caret's heading, or the top line's once a scroll passes a heading.
    private(set) var currentHeading: Int?
    @ObservationIgnored private var currentLine = 1
    /// For the rest of the turn the caret moved in: a scroll that move made leaves the caret's heading current.
    @ObservationIgnored private var caretMoved = false

    @ObservationIgnored private(set) var session: UInt64?
    @ObservationIgnored private var root: URL?
    private var documents: [String: DocumentState] = [:]
    /// Why a document held after Cancel in an alert isn't saved.
    private var heldReasons: [String: String] = [:]
    @ObservationIgnored private var lineIssues: [String: [Int: IssuesEvent.Line]] = [:]
    @ObservationIgnored private var composingPath: String?
    /// A `tree` event came before the session's open answered with an older tree.
    @ObservationIgnored private var treeChanged = false

    var compiling = false
    var outdated = false
    var result: CompileResult?
    @ObservationIgnored var finishedBuilds = 0
    var chosenIssue: Int?
    nonisolated enum ShownPDF: Equatable { case none, build(URL), live }
    var shown = ShownPDF.none
    var hasPDF: Bool { shown != .none }
    var livePDF: Bool { shown == .live }
    var buildPDF: URL?
    let pdf = PDFController()
    let panel = BuildPanelModel()
    let texpresso = TeXpressoSession()

    var issues: [LogItem] { (result?.errors ?? []) + (result?.warnings ?? []) }

    var openURL: URL? { openPath.flatMap(url) }
    var diskConflict: String?
    var missingFile: String?
    private(set) var previewVersion = 0

    var importClash: ImportClash?

    /// The sidebar's, kept in the project's settings and moved with a rename by the core.
    var expandedFolders: Set<String> = [] {
        didSet { if expandedFolders != oldValue { saveUIState(["expandedFolders": expandedFolders.sorted()]) } }
    }
    var foldedHeadings: Set<String> = [] {
        didSet { if foldedHeadings != oldValue { saveUIState(["foldedHeadings": foldedHeadings.sorted()]) } }
    }
    @ObservationIgnored private var showingUIState = false
    /// Not the session's, so not in its order: written in turn, and a rename waits for the last.
    @ObservationIgnored var uiStateWrites: Task<Void, Never>?

    let search = ProjectSearch()

    let editor = SourceEditor()
    private(set) var sourceHasKeyboard = false
    @ObservationIgnored weak var app: AppModel?
    let core = Core.shared
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private var opens: Task<Void, Never>?
    @ObservationIgnored private var openRequests = 0
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var pdfLoad: Task<Bool, Never>?
    /// A finished build's PDF is shown before the next build event.
    @ObservationIgnored private var buildLane: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var liveLogWatch: Task<Void, Never>?
    @ObservationIgnored var trashed: [UndoableTrash] = []
    @ObservationIgnored var exportFolder: URL?
    private(set) var closed = false

    init(id: String, app: AppModel) {
        self.id = id
        self.app = app
        tree = FileTree(id: id)
        // The session sends the log while the panel shows it.
        liveLogWatch = track({ [panel] in panel.showsLiveLog }, initial: false) { [weak self] shown in
            guard let self else { return }
            if let session { core.send("session_live_log", ["session": session, "shown": shown]) }
            if !shown { texpresso.logClosed() }
        }
        tree.onChange = { [weak self] in
            self?.openKindChanged()
            self?.analyze()
        }
        pdf.onVisiblePages = { [weak self] in self?.liveView($0) }
    }

    var isLaTeX: Bool { openKind == .tex }

    /// The caret's line's sectioning command: empty for Normal Text.
    var headingCommand: String { outline.first { $0.file == openPath && $0.line == cursorLine }?.command ?? "" }
    var editsText: Bool { openKind?.isText == true }

    private func openKindChanged() {
        guard let openPath else { return openKind = nil }
        if let kind = tree.node(at: openPath)?.kind, kind != openKind { openKind = kind }
    }

    func isText(_ path: String) -> Bool { tree.node(at: path)?.kind?.isText == true }

    /// The status bar's Not Saved: after a failed save, or Cancel in an alert about the file on disk.
    var saveFailure: String? {
        for (path, state) in documents.sorted(by: { $0.key < $1.key }) {
            if let error = state.error { return error }
            if state.held { return heldReasons[path] ?? String(localized: "“\(path.fileName)” wasn’t saved.") }
        }
        return nil
    }

    /// One spelling for every failed save, as `AppModel.report` drops an alert whose title is the one showing.
    func notSavedTitle(_ path: String? = nil) -> String { String(localized: "“\((path ?? openPath ?? id).fileName)” Wasn’t Saved") }

    var errorCount: Int { result?.errors.count ?? 0 }
    var warningCount: Int { result?.warnings.count ?? 0 }

    var showsLastSuccessfulBuild: Bool { hasPDF && result?.failed == true && result?.pdf == nil }

    /// A closed project reports nothing.
    @discardableResult
    func alerting<T>(_ title: @autoclosure () -> String, _ work: () async throws -> T) async -> T? {
        await app?.alerting(title(), unless: { closed }, work) ?? nil
    }

    let notices = ProjectNotices()

    var saved: SavedWorkspace {
        SavedWorkspace(project: id, file: openPath, line: cursorLine, buildPanel: panel.shown, pdfPage: pdf.restorePage ?? pdf.page,
                       pdfZoom: pdf.restoreZoom ?? pdf.zoom)
    }

    // MARK: - Loading

    /// Stops if the project is left meanwhile.
    func load(restoring saved: SavedWorkspace?) async {
        connectEditor()
        if let saved { (panel.shown, pdf.restorePage, pdf.restoreZoom) = (saved.buildPanel, saved.pdfPage, saved.pdfZoom) }
        let session = core.observe { [weak self] event in self?.handle(event) }
        // Shown before the workspace appears, so the pane doesn't open empty.
        async let pdfShown = showBuildPDF(try? await core.call("pdf_path", ["id": id], as: String.self))
        do {
            // With automatic builds and no PDF, the session starts one.
            let opened = try await core.call("session_open", ["id": id, "session": session, "autoCompile": app?.autoCompile ?? false],
                                             as: SessionOpened.self)
            guard !closed else { throw CancellationError() }
            self.session = session
            root = URL(filePath: opened.root, directoryHint: .isDirectory)
            settings = opened.settings
            showUIState(opened.ui)
            if !treeChanged { tree.show(opened.tree) }
            let restored = saved?.file.flatMap { tree.node(at: $0) == nil ? nil : $0 }
            if let file = restored ?? settings?.mainFile { await open(file, line: restored == nil ? nil : saved?.line) }
            await analysis?.value
        } catch {
            core.forget(session)
            // The core may have opened it and failed only in its answer.
            core.send("session_close", ["session": session])
            // Home stays, with the alert over it.
            guard !closed else { return }
            app?.report(error, "Couldn’t Open “\(id)”")
            if app?.project === self { await app?.close() }
            return
        }
        _ = await pdfShown
        guard !closed else { return }
        initialLoadComplete = true
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
        editor.textView.issueClicked = { [weak self] line in
            guard let self, let place = issues.firstIndex(where: { $0.file == self.openPath && $0.line == line }) else { return }
            panel.show(.issues)
            chooseIssue(place, focus: false, open: false)
        }
        editor.textView.headings = { [weak self] in
            guard let self else { return [] }
            return outline.filter { $0.file == self.openPath }.map { ($0.line, $0.title) }
        }
        editor.textView.forwardSync = { [weak self] quietly in
            self?.hasPDF == true && self?.isLaTeX == true ? { Task { await self?.forwardSync(quietly: quietly) } } : nil
        }
        editor.textView.openDefinition = { [weak self] place in
            Task { await self?.open(place.file, line: place.line, column: place.column, length: place.length) }
        }
        editor.rename = { [weak self] in self?.app?.prompt = .rename($0) }
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

    // MARK: - The session's events

    private func handle(_ event: SessionEvent) {
        guard !closed else { return }
        switch event {
        case .document(let state): documentChanged(state)
        case .saved: analyze()
        case .reload(let reloaded): reload(reloaded)
        case .closed(let gone):
            // One this model closed has the next file shown already.
            (documents[gone.path], heldReasons[gone.path], lineIssues[gone.path]) = (nil, nil, nil)
            if openPath == gone.path, gone.reason != "closed" { clearOpenFile() }
        case .renamed(let renamed):
            // The editor follows the rename's own answer (`performRename`).
            documents[renamed.to] = documents.removeValue(forKey: renamed.from)
            heldReasons[renamed.to] = heldReasons.removeValue(forKey: renamed.from)
            lineIssues[renamed.to] = lineIssues.removeValue(forKey: renamed.from)
        case .conflict(let asked) where asked.kind == .changed: diskConflict = asked.path
        case .conflict(let asked): missingFile = asked.path
        case .issues(let marked):
            let lines = Dictionary(marked.lines.map { ($0.line, $0) }) { $1 }
            lineIssues[marked.path] = lines.isEmpty ? nil : lines
            if editor.path == marked.path { editor.textView.issues.lines = lines }
        case .build(let state): inOrder { self.buildChanged(state) }
        case .buildFinished(let finished): inOrder { await self.buildFinished(finished) }
        case .buildCleaned: inOrder { self.buildCleaned() }
        case .tree(let listed):
            treeChanged = true
            tree.show(listed.tree)
            // A previewed file has no document for the session to close.
            if let openPath, !editsText, tree.node(at: openPath) == nil { clearOpenFile() }
        case .filesChanged(let changed):
            if let openPath, !editsText, changed.paths.contains(openPath) { previewVersion += 1 }
            if changed.paths.contains(where: { tree.node(at: $0)?.kind == .tex }) { analyze() }
        case .live(let state): liveChanged(state)
        case .livePDF(let read): showLive(read)
        }
    }

    private func documentChanged(_ state: DocumentState) {
        let before = documents[state.path]
        documents[state.path] = state
        if !state.held { heldReasons[state.path] = nil }
        // A failed autosave is told once in an alert, as NSDocument's are; Not Saved stays until a save succeeds.
        if let error = state.error, before?.error == nil {
            let title = notSavedTitle(state.path)
            if let app, app.alert == nil, !closed { app.alert = AppAlert(title, error) } else { notices.announce(title) }
        }
    }

    /// Another app's text, or the disk's after Revert, shown without an edit.
    private func reload(_ event: ReloadEvent) {
        if editor.path == event.path {
            editor.reload(text: event.text)
            analyze()
        } else if let session, let source = SourceDocument(session: session, path: event.path) {
            source.reload(event.text)
        }
    }

    @discardableResult func inOrder(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> { enqueue(&buildLane, work) }

    // MARK: - Editing

    /// After the opens asked for before it. One superseded meanwhile stops, unless it has already closed the file shown:
    /// the editor never shows a file without its document.
    func open(_ path: String, line: Int? = nil, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true) async {
        openRequests += 1
        let request = openRequests
        let latest = { request == self.openRequests && !self.closed }
        await enqueue(&opens) { [self] in
            guard latest() else { return }
            if path != openPath {
                guard let session else { return }
                let text: Bool
                do {
                    // A file made a moment ago may not be in the tree yet.
                    if tree.node(at: path) == nil { await tree.reload() }
                    text = isText(path)
                    if text { try await core.call("session_open_document", ["session": session, "path": path]) }
                } catch {
                    if latest() { app?.report(error, "Couldn’t Open “\(path.fileName)”") }
                    return
                }
                // Nothing awaited between the close and the switch.
                var shows = latest()
                if shows, let was = openPath, editsText { shows = await closeDocument(was) && !closed }
                guard shows else {
                    // The session keeps no document the editor doesn't show.
                    if text, path != openPath, !closed { core.send("session_close_document", ["session": session, "path": path]) }
                    return
                }
                show(path, focus: focus)
            }
            if let line, editsText, latest() { editor.reveal(line: line, column: column, length: length, atTop: atTop, focus: focus) }
        }.value
    }

    /// The session's text now, whatever reloads came while it opened.
    private func show(_ path: String, focus: Bool) {
        openPath = path
        analyze()
        guard editsText else { return }
        guard let session, let source = SourceDocument(session: session, path: path) else { openPath = nil; return }
        editor.open(path: path, text: source.text, source: source, focus: focus)
        editor.textView.issues.lines = lineIssues[path] ?? [:]
    }

    /// Saved first; false, staying open, if that failed or asks about the disk.
    func closeDocument(_ path: String) async -> Bool {
        guard let session else { return true }
        return await alerting(notSavedTitle(path)) {
            try await core.call("session_close_document", ["session": session, "path": path], as: Closed.self).closed
        } ?? false
    }

    private func composing(_ composing: Bool) {
        guard let session, let path = composing ? editor.path : composingPath else { return }
        composingPath = composing ? path : nil
        core.send("session_composing", ["session": session, "path": path, "composing": composing])
    }

    func url(_ path: String) -> URL? { root.map { $0.appending(path: path) } }

    /// As the disk spells it; asked as a drag moves, so at once.
    func projectPath(_ url: URL) -> String? {
        guard let located = try? core.now("locate", ["path": url.path(percentEncoded: false)], as: Located?.self),
              located.id == id, !located.path.isEmpty else { return nil }
        return located.path
    }

    private func dropped(_ url: URL) -> SourceTextView.FileDrop? {
        guard let path = projectPath(url), let kind = tree.node(at: path)?.kind else { return nil }
        let drop: DropText? = Syntax.call("drop_text", ["path": path, "kind": kind.rawValue, "into": openKind?.rawValue ?? ""])
        if let insert = drop?.insert { return .insert(insert) }
        return .open { [weak self] in Task { await self?.open(path) } }
    }

    func showInFinder(_ path: String) {
        if let url = self.url(path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// A build follows when automatic.
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

    /// The session keeps the outline, which `heading(at:)` asks about.
    func analyze() {
        analysis?.cancel()
        guard isLaTeX, let path = openPath, let session else {
            (outline, outlineTree, words) = ([], [], nil)
            findHeadings()
            return
        }
        analysis = Task {
            guard let doc = try? await core.call("session_analyze", ["session": session, "path": path], as: Analysis.self),
                  !Task.isCancelled else { return }
            (outline, outlineTree, headingStyles, words) = (doc.outline, doc.tree, doc.headingStyles, doc.words)
            findHeadings()
        }
    }

    /// A scroll makes the top line's heading current only as it passes one; a caret's move wins over a scroll in its turn.
    private func findHeadings() {
        let atTop = heading(at: topLine)
        if atTop != topHeading {
            topHeading = atTop
            if !caretMoved { currentLine = topLine }
        }
        let current = currentLine == topLine ? atTop : heading(at: currentLine)
        if current != currentHeading { currentHeading = current }
    }

    /// At once: the core answers from the outline it keeps, outside the session's queue.
    private func heading(at line: Int) -> Int? {
        guard let session, let openPath, !outline.isEmpty else { return nil }
        return try? core.now("session_outline_current", ["session": session, "path": openPath, "line": line], as: Int?.self)
    }

    /// The matches the search shows, which the field may be ahead of.
    func replaceAll() async {
        guard let session else { return }
        let query = search.searched
        guard let answer = await alerting("Couldn’t Replace “\(query)”", {
            try await editProject("session_replace", ["session": session, "query": query, "replacement": search.replacement],
                                  named: String(localized: "Replace"))
        }) else { return }
        let count = (answer.edits?.edits.count ?? 0) + answer.written.reduce(0) { $0 + $1.count }
        let files = answer.written.count + (answer.edits == nil ? 0 : 1)
        notices.note(String(AttributedString(localized: "Replaced ^[\(count) match](inflect: true) in ^[\(files) file](inflect: true)")
            .characters))
        await search.run(in: session)
    }

    /// A refusal is the core's sentence, for the sheet to show.
    func renameSymbol(_ symbol: Definition, to name: String) async throws {
        guard let session else { return }
        try await editProject("session_rename_symbol", ["session": session, "kind": symbol.kind, "from": symbol.name, "to": name],
                              named: String(localized: "Rename"))
    }

    /// The core writes the other files, with no undo; the open document's edits are one undo step, as a command's, which the
    /// session saves as any.
    @discardableResult
    private func editProject(_ command: String, _ args: [String: any Sendable], named name: String) async throws -> ProjectEdits {
        let answer = try await core.call(command, args, as: ProjectEdits.self)
        // A file shown since has text of its own, as one typed in since does.
        if let edits = answer.edits, edits.path == editor.path, edits.version == editor.textView.document.version {
            editor.textView.apply(edits.edits, named: name)
        }
        return answer
    }

    // MARK: - Changes on disk

    /// `save`, `revert`, `close`, or `cancel` with the reason it is held, unsaved, until a save asks again.
    func answer(_ path: String, _ answer: String, holding reason: String? = nil) {
        if diskConflict == path { diskConflict = nil }
        if missingFile == path { missingFile = nil }
        if let reason { heldReasons[path] = reason }
        if answer == "close", openPath == path { clearOpenFile() }
        guard let session else { return }
        Task {
            await alerting(notSavedTitle(path)) {
                try await core.call("session_resolve", ["session": session, "path": path, "answer": answer])
            }
        }
    }

    // MARK: - Closing

    func close() {
        guard !closed else { return }
        closed = true
        // It can still show while the session closes.
        editor.textView.isEditable = false
        // The window's undo stack outlives it.
        let undo = app?.undoManager
        undo?.removeAllActions(withTarget: self)
        for item in trashed { undo?.removeAllActions(withTarget: item) }
        trashed = []
        removeExport()
        notices.cancel()
        analysis?.cancel()
        tree.close()
        syncTask?.cancel()
        pdfLoad?.cancel()
        liveLogWatch?.cancel()
        if let session {
            core.forget(session)
            closing = Task { [uiStateWrites] in
                await uiStateWrites?.value
                try? await core.call("session_close", ["session": session])
            }
        }
    }

    /// Until the session has stopped its build and Live Preview, which another model would race.
    func waitUntilClosed() async { await closing?.value }

    // MARK: - Settings

    @ObservationIgnored private var settingsPatches = 0

    /// Shown at once; put back if the session refuses it.
    @discardableResult func patchSettings(_ change: SettingsChange) async -> Bool {
        guard let session, !closed else { return false }
        settingsPatches += 1
        let patch = settingsPatches, before = settings
        settings?.apply(change)
        // Answers can come back out of order: the latest's has them all.
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

    /// The session restarts its build and Live Preview; the PDF is the new main file's.
    func mainFileChanged() {
        analyze()
        Task { if let path = try? await core.call("pdf_path", ["id": id], as: String.self) { await showBuildPDF(path) } }
    }

    func reveal(_ item: OutlineItem) {
        // Already there: a click chooses the row as it goes down, then taps it.
        guard item.file != openPath || cursorLine != item.line || topLine != item.line else { return }
        Task { await open(item.file, line: item.line, atTop: true, focus: false) }
    }
}

nonisolated struct SavedWorkspace: Codable, Equatable {
    var project: String
    var file: String?
    var line: Int
    var buildPanel: Bool
    var pdfPage: Int
    var pdfZoom: PDFController.Zoom?
}

/// None: the file dropped opens.
private nonisolated struct DropText: Decodable { let insert: String? }

/// `session_replace`'s and `session_rename_symbol`'s.
private nonisolated struct ProjectEdits: Decodable {
    nonisolated struct Document: Decodable {
        var path: String
        var version: Int
        var edits: [TextEdit]
    }

    nonisolated struct Written: Decodable { var count: Int }

    var edits: Document?
    var written: [Written]
}
