import AppKit
import Observation

/// A project's window state over the core's session for it (docs/core-api.md), which owns its documents' text, saves,
/// builds, conflicts with other apps, the folder's watcher and Live Preview, and says what changed in events.
@Observable
final class ProjectModel {
    let id: String
    var settings: ProjectSettings?
    let tree: FileTree
    private(set) var initialLoadComplete = false
    var openPath: String? {
        didSet { if openPath != oldValue { openKindChanged() } }
    }
    /// The open file's, from the tree; kept while the tree hasn't the file yet (a rename) or has it no longer (gone).
    private(set) var openKind: FileKind?
    /// The outline's headings in order: `outlineTree`'s, each at its `id`.
    private(set) var outline: [OutlineItem] = []
    private(set) var outlineTree: [OutlineNode] = []
    /// The levels the main file's class has, as the last analysis found them.
    private(set) var headingStyles = HeadingStyle.standard
    var words: Int?
    var cursorLine = 1
    var cursorColumn = 0
    @ObservationIgnored var topLine = 1
    @ObservationIgnored private(set) var topHeading: Int?
    /// The outline's row for where the writer is: the caret's heading, or the top line's once a scroll passes a heading.
    private(set) var currentHeading: Int?
    /// The line `currentHeading` is for: the caret's, or the top line's once a scroll passed a heading.
    @ObservationIgnored private var currentLine = 1
    /// For the rest of the turn the caret moved in, so a scroll that move made leaves the caret's heading current.
    @ObservationIgnored private var caretMoved = false

    @ObservationIgnored private(set) var session: UInt64?
    @ObservationIgnored private var root: URL?
    /// Each open document's state, as the session's `document` events give it.
    private var documents: [String: DocumentState] = [:]
    /// Why a document held after Cancel in an alert isn't saved, for the status bar.
    private var heldReasons: [String: String] = [:]
    @ObservationIgnored private var lineIssues: [String: [Int: SourceTextView.LineIssue]] = [:]
    @ObservationIgnored private var composingPath: String?
    /// A `tree` event came before the answer to the session's open, whose tree is older.
    @ObservationIgnored private var treeChanged = false

    var compiling = false
    var outdated = false
    var result: CompileResult?
    @ObservationIgnored var finishedBuilds = 0
    var chosenIssue: Int?
    nonisolated enum ShownPDF: Equatable { case none, build(URL), live(URL) }
    var shown = ShownPDF.none
    var hasPDF: Bool { shown != .none }
    var livePDF: Bool { if case .live = shown { true } else { false } }
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

    /// The sidebar's, which the core keeps in the project's settings and moves with a rename (`set_ui_state`; `session_open`
    /// and `session_rename` answer it).
    var expandedFolders: Set<String> = [] {
        didSet { if expandedFolders != oldValue { saveUIState(["expandedFolders": expandedFolders.sorted()]) } }
    }
    var foldedHeadings: Set<String> = [] {
        didSet { if foldedHeadings != oldValue { saveUIState(["foldedHeadings": foldedHeadings.sorted()]) } }
    }
    @ObservationIgnored private var showingUIState = false
    /// The sidebar's state is written in the order it changes, and a rename waits for the last write before it moves it:
    /// these are the service's commands, not the session's, which the core takes in the order sent.
    @ObservationIgnored var uiStateWrites: Task<Void, Never>?

    let search: ProjectSearch

    let editor = SourceEditor()
    @ObservationIgnored weak var app: AppModel?
    let core = Core.shared
    @ObservationIgnored private var analysis: Task<Void, Never>?
    /// Files open one at a time, and only the latest asked for carries on: the editor never shows one file while
    /// `openPath` names another, and no open leaves the session a document it doesn't show.
    @ObservationIgnored private var opens: Task<Void, Never>?
    @ObservationIgnored private var openRequests = 0
    // Each of these is cancelled by the next request of its kind, which then has the editor or viewer.
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var pdfLoad: Task<Bool, Never>?
    /// The build's events in turn: a finished build's PDF is shown before the next event says what follows it.
    @ObservationIgnored private var buildLane: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored var trashed: [UndoableTrash] = []
    @ObservationIgnored var exportFolder: URL?
    private(set) var closed = false

    init(id: String, app: AppModel) {
        self.id = id
        self.app = app
        search = ProjectSearch(id: id)
        tree = FileTree(id: id)
        texpresso.watchLog { [panel] in panel.showsLiveLog } tell: { [weak self] shown in
            guard let self, let session else { return }
            core.send("session_live_log", ["session": session, "shown": shown])
        }
        texpresso.onAlert = { [weak self] in self?.panel.show(.texpresso) }
        texpresso.onEnded = { [weak self] in Task { await self?.endLivePDF() } }
        tree.onChange = { [weak self] in
            self?.openKindChanged()
            self?.analyze()
        }
        pdf.onVisiblePages = { [weak self] in self?.liveView($0) }
        pdf.buildBehindLive = { [weak self] in self.flatMap { $0.livePDF ? $0.buildPDF : nil } }
    }

    var isLaTeX: Bool { openKind == .tex }

    /// The level of the caret's line, as its sectioning command: empty for Normal Text.
    var headingCommand: String {
        outline.first { $0.file == openPath && $0.line == cursorLine }?.command ?? ""
    }
    var editsText: Bool { openKind?.isText == true }

    private func openKindChanged() {
        guard let openPath else { return openKind = nil }
        if let kind = tree.node(at: openPath)?.kind, kind != openKind { openKind = kind }
    }

    func isText(_ path: String) -> Bool { tree.node(at: path)?.kind?.isText == true }

    /// After a save that failed, or Cancel in an alert about the file on disk: the status bar's Not Saved.
    var saveFailure: String? {
        for (path, state) in documents.sorted(by: { $0.key < $1.key }) {
            if let error = state.error { return error }
            if state.held { return heldReasons[path] ?? String(localized: "“\(path.fileName)” wasn’t saved.") }
        }
        return nil
    }

    var errorCount: Int { result?.errors.count ?? 0 }
    var warningCount: Int { result?.warnings.count ?? 0 }

    var showsLastSuccessfulBuild: Bool { hasPDF && result?.failed == true && result?.pdf == nil }
    var texAvailable: Bool { app?.tex?.available ?? false }

    func report(_ error: any Error, _ title: String) {
        app?.alert = AppAlert(title, error)
    }

    let notices = ProjectNotices()

    var saved: SavedWorkspace {
        SavedWorkspace(project: id, file: openPath, line: cursorLine, buildPanel: panel.shown, pdfPage: pdf.restorePage ?? pdf.page,
                       pdfZoom: pdf.restoreZoom ?? pdf.zoom)
    }

    // MARK: - Loading

    /// Stops if the project is left meanwhile, so it never writes to the editor after the next one.
    func load(restoring saved: SavedWorkspace?) async {
        connectEditor()
        if let saved {
            panel.shown = saved.buildPanel
            pdf.restorePage = saved.pdfPage
            pdf.restoreZoom = saved.pdfZoom
        }
        // Its events come to `handle` from here on: the app numbers the session, so none comes before its observer.
        let session = core.observe { [weak self] event in self?.handle(event) }
        // The last build's PDF loads beside the session's open, the file's reading and its analysis, and is shown before the
        // workspace appears, so the pane doesn't open on its empty state.
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
            // Left meanwhile, or the core may have opened it and failed only in its answer; one it never opened is a 404, logged.
            core.send("session_close", ["session": session])
            // Home stays, with the alert over it: a workspace would have no files to show.
            guard !closed else { return }
            report(error, "Couldn’t Open “\(id)”")
            if app?.project === self { await app?.close() }
            return
        }
        _ = await pdfShown
        guard !closed else { return }
        initialLoadComplete = true
    }

    /// The editor tells the model where the caret and the top line are, and asks it about drops, issues, headings and SyncTeX.
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
    }

    /// The preference changed: the session builds by itself only where `status` last found TeX.
    func autoCompileChanged() {
        guard let session, !closed else { return }
        core.send("session_set_options", ["session": session, "autoCompile": app?.autoCompile ?? false])
    }

    private func saveUIState(_ patch: [String: any Sendable]) {
        guard !showingUIState, !closed else { return }
        let args: [String: any Sendable] = ["id": id, "patch": patch]
        _ = enqueue(&uiStateWrites) { [core] in try? await core.call("set_ui_state", args) }
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
        case .closed(let gone): documentClosed(gone)
        case .renamed(let renamed): documentRenamed(renamed)
        case .conflict(let asked): conflict(asked)
        case .issues(let marked): markIssues(marked)
        case .build(let state): inOrder { self.buildChanged(state) }
        case .buildFinished(let finished): inOrder { await self.buildFinished(finished) }
        case .buildCleaned: inOrder { self.buildCleaned() }
        case .tree(let listed): showTree(listed)
        case .filesChanged(let changed): filesChanged(changed)
        case .live(let state): liveChanged(state)
        case .livePDF(let read): showLive(read)
        case .liveRestarted: notices.note(String(localized: "Live Preview Restarted"))
        }
    }

    private func documentChanged(_ state: DocumentState) {
        let before = documents[state.path]
        documents[state.path] = state
        if !state.held { heldReasons[state.path] = nil }
        if state.error != nil, before?.error == nil { notices.announce(String(localized: "“\(state.path.fileName)” Wasn’t Saved")) }
    }

    /// Another app's text, or the disk's after Revert: shown without an edit, which the session waits for before it saves
    /// the file again.
    private func reload(_ event: ReloadEvent) {
        if editor.path == event.path {
            editor.reload(text: event.text)
            analyze()
        } else if let session, let source = SourceDocument(session: session, path: event.path) {
            source.reload(event.text)
        }
    }

    /// One this model closed (`closed`) has the next file shown, or is cleared already.
    private func documentClosed(_ event: ClosedEvent) {
        documents[event.path] = nil
        heldReasons[event.path] = nil
        lineIssues[event.path] = nil
        if openPath == event.path, event.reason != "closed" { clearOpenFile() }
    }

    /// The editor and the file shown follow the rename's own answer (`performRename`), which covers a file previewed too.
    private func documentRenamed(_ event: RenamedEvent) {
        documents[event.to] = documents.removeValue(forKey: event.from)
        heldReasons[event.to] = heldReasons.removeValue(forKey: event.from)
        lineIssues[event.to] = lineIssues.removeValue(forKey: event.from)
    }

    private func conflict(_ event: ConflictEvent) {
        switch event.kind {
        case .changed: diskConflict = event.path
        case .gone: missingFile = event.path
        }
    }

    private func markIssues(_ event: IssuesEvent) {
        let lines = Dictionary(event.lines.map { line in
            (line.line, SourceTextView.LineIssue(isError: line.error, message: line.message, short: line.short, compact: line.compact,
                                                 tokens: line.tokens.map(\.range), others: line.others))
        }) { $1 }
        lineIssues[event.path] = lines.isEmpty ? nil : lines
        if editor.path == event.path { editor.textView.issueLines = lines }
    }

    private func showTree(_ event: TreeEvent) {
        treeChanged = true
        tree.show(event.tree)
        // A file previewed, not edited, that went: the session has no document of it to close.
        if let openPath, !editsText, tree.node(at: openPath) == nil { clearOpenFile() }
    }

    private func filesChanged(_ event: PathsEvent) {
        if let openPath, !editsText, event.paths.contains(openPath) { previewVersion += 1 }
        if event.paths.contains(where: { tree.node(at: $0)?.kind == .tex }) { analyze() }
    }

    /// `work` on the build's lane, after the build's events before it.
    @discardableResult
    func inOrder(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        enqueue(&buildLane, work)
    }

    // MARK: - Editing

    /// After the opens asked for before it; one superseded meanwhile stops, closing the document it opened.
    func open(_ path: String, line: Int? = nil, column: Int? = nil, atTop: Bool = false, focus: Bool = true) async {
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
                    if latest() { report(error, "Couldn’t Open “\(path.fileName)”") }
                    return
                }
                // Read first and closed last, with nothing awaited between the close and the switch.
                var shows = latest()
                if shows, let was = openPath, editsText { shows = await closeDocument(was) && latest() }
                guard shows else {
                    // The session keeps no document the editor doesn't show; a later open of it opens it again.
                    if text, path != openPath, !closed { core.send("session_close_document", ["session": session, "path": path]) }
                    return
                }
                show(path, focus: focus)
            }
            if let line, editsText, latest() { editor.reveal(line: line, column: column, atTop: atTop, focus: focus) }
        }.value
    }

    /// Its text as the session's document has it now, whatever reloads came while it opened.
    private func show(_ path: String, focus: Bool) {
        openPath = path
        analyze()
        guard editsText else { return }
        guard let session, let source = SourceDocument(session: session, path: path) else {
            openPath = nil
            return
        }
        editor.open(path: path, text: source.text, source: source, focus: focus)
        editor.textView.issueLines = lineIssues[path] ?? [:]
    }

    /// Saved first; false, staying open, if that failed or asks about the disk.
    func closeDocument(_ path: String) async -> Bool {
        guard let session else { return true }
        do {
            return try await core.call("session_close_document", ["session": session, "path": path], as: Closed.self).closed
        } catch {
            if !closed { report(error, String(localized: "“\(path.fileName)” Wasn’t Saved")) }
            return false
        }
    }

    private func composing(_ composing: Bool) {
        guard let session, let path = composing ? editor.path : composingPath else { return }
        composingPath = composing ? path : nil
        core.send("session_composing", ["session": session, "path": path, "composing": composing])
    }

    func url(_ path: String) -> URL? {
        root.map { $0.appending(path: path) }
    }

    /// Where a file dropped on the window is in this project, as the disk spells it; asked as the drag moves, so at once.
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

    /// Every document with unsaved edits; a build follows when automatic. A failure is an alert only when `reporting`.
    @discardableResult
    func save(reporting: Bool = true) async -> Bool {
        guard let session, !closed else { return true }
        do {
            return try await core.call("session_save", ["session": session, "reporting": reporting], as: Saved.self).saved
        } catch {
            if reporting, !closed { report(error, String(localized: "“\((openPath ?? id).fileName)” Wasn’t Saved")) }
            return false
        }
    }

    /// The session keeps the analysis's outline, which `heading(at:)` asks about.
    func analyze() {
        analysis?.cancel()
        guard isLaTeX, let path = openPath, let session else {
            outline = []
            outlineTree = []
            words = nil
            findHeadings()
            return
        }
        analysis = Task {
            guard let doc = try? await core.call("session_analyze", ["session": session, "path": path], as: Analysis.self),
                  !Task.isCancelled else { return }
            outline = doc.outline
            outlineTree = doc.tree
            headingStyles = doc.headingStyles
            words = doc.words
            findHeadings()
        }
    }

    /// A scroll makes the top line's heading the current one only as it passes a heading, and a caret's move wins over a
    /// scroll in the same turn.
    private func findHeadings() {
        let atTop = heading(at: topLine)
        if atTop != topHeading {
            topHeading = atTop
            if !caretMoved { currentLine = topLine }
        }
        let current = currentLine == topLine ? atTop : heading(at: currentLine)
        if current != currentHeading { currentHeading = current }
    }

    /// At once: the core answers it from the outline it keeps, without the session's queue (docs/core-api.md).
    private func heading(at line: Int) -> Int? {
        guard let session, let openPath, !outline.isEmpty else { return nil }
        return try? core.now("session_outline_current", ["session": session, "path": openPath, "line": line], as: Int?.self)
    }

    // MARK: - Changes on disk

    /// The question about `path` is answered (`save`, `revert`, `close`, or `cancel` with the reason it is held: the edits
    /// stay unsaved, and the autosave quiet, until a save is asked for, which asks again); one about another file still
    /// waits for its alert.
    func answer(_ path: String, _ answer: String, holding reason: String? = nil) {
        if diskConflict == path { diskConflict = nil }
        if missingFile == path { missingFile = nil }
        if let reason { heldReasons[path] = reason }
        if answer == "close", openPath == path { clearOpenFile() }
        guard let session else { return }
        Task {
            do {
                try await core.call("session_resolve", ["session": session, "path": path, "answer": answer])
            } catch {
                if !closed { report(error, String(localized: "“\(path.fileName)” Wasn’t Saved")) }
            }
        }
    }

    // MARK: - Closing

    func close() {
        guard !closed else { return }
        closed = true
        // The old workspace can remain visible while the session closes.
        editor.textView.isEditable = false
        // Its renames and its files' moves to the Trash can't be undone once it's closed; the window's stack outlives it.
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
        // The session saves what it can, and stops its build and Live Preview.
        if let session {
            core.forget(session)
            closing = Task { [uiStateWrites] in
                await uiStateWrites?.value
                try? await core.call("session_close", ["session": session])
            }
        }
    }

    /// Once the session has stopped its build and Live Preview, so another model can't race it for the project's.
    func waitUntilClosed() async {
        await closing?.value
    }

    // MARK: - Settings

    @ObservationIgnored private var settingsPatches = 0

    /// Shown at once; put back if the session refuses it. A build follows when automatic: the session's.
    @discardableResult func patchSettings(_ change: SettingsChange) async -> Bool {
        guard let session, !closed else { return false }
        settingsPatches += 1
        let patch = settingsPatches, before = settings
        settings?.apply(change)
        // The session takes patches in order, but its answers can come back in another: the latest's has them all.
        let latest = { patch == self.settingsPatches }
        do {
            let updated = try await core.call("session_set_settings", ["session": session, "patch": change.patch], as: ProjectSettings.self)
            guard !closed else { return false }
            if latest() { settings = updated }
            if updated.mainFile != before?.mainFile { mainFileChanged() }
            return true
        } catch {
            if !closed {
                if latest() { settings = before }
                report(error, "Couldn’t Change the Project’s Settings")
            }
            return false
        }
    }

    /// The session stops the build, restarts Live Preview and builds the new one; the PDF is the new main file's.
    func mainFileChanged() {
        analyze()
        Task {
            if let path = try? await core.call("pdf_path", ["id": id], as: String.self) { await showBuildPDF(path) }
        }
    }

    // MARK: - Editor commands

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

/// What a file dropped on the open one inserts there (`drop_text`); none means it opens.
private nonisolated struct DropText: Decodable {
    let insert: String?
}
