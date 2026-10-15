import Accessibility
import AppKit
import Observation
import PDFKit

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
    var outline: [OutlineItem] = []
    private(set) var outlineTree: [OutlineNode] = []
    /// `outline` as `outline_current` takes it.
    @ObservationIgnored private var headings: [[String: any Sendable]] = []
    var documentClass: DocumentClass?
    @ObservationIgnored private var classFile: String?
    var words: Int?
    var cursorLine = 1
    var cursorColumn = 0
    @ObservationIgnored var topLine = 1
    @ObservationIgnored private(set) var topHeading: Int?
    /// The outline's row for where the writer is: the caret's heading, or the top line's once a scroll passes a heading.
    private(set) var currentHeading: Int?
    @ObservationIgnored private var currentLine = 1
    @ObservationIgnored private var caretMoved = false
    @ObservationIgnored private(set) var findingHeadings: Task<Void, Never>?

    @ObservationIgnored private(set) var session: UInt64?
    @ObservationIgnored private var root: URL?
    /// Each open document's state, as the session's `document` events give it.
    private var documents: [String: DocumentState] = [:]
    /// Why a document held after Cancel in an alert isn't saved, for the status bar.
    @ObservationIgnored private var heldReasons: [String: String] = [:]
    @ObservationIgnored private var lineIssues: [String: [Int: SourceTextView.LineIssue]] = [:]
    /// Closed by this model, so its `document_closed` doesn't clear the editor showing the next file.
    @ObservationIgnored private var closingDocuments: Set<String> = []
    @ObservationIgnored private var composingPath: String?
    @ObservationIgnored private var sentAutoCompile: Bool?

    var compiling = false
    private(set) var outdated = false
    private(set) var result: CompileResult?
    @ObservationIgnored private(set) var finishedBuilds = 0
    private(set) var chosenIssue: Int?
    nonisolated enum ShownPDF: Equatable { case none, build(URL), live(URL) }
    var shown = ShownPDF.none
    var hasPDF: Bool { shown != .none }
    var livePDF: Bool { if case .live = shown { true } else { false } }
    private(set) var buildPDF: URL?
    let pdf = PDFController()
    let panel: BuildPanelModel
    let texpresso = TeXpressoSession()

    var issues: [LogItem] { (result?.errors ?? []) + (result?.warnings ?? []) }

    var openURL: URL? { openPath.flatMap(url) }
    var diskConflict: String?
    var missingFile: String?
    private(set) var previewVersion = 0

    var importClash: ImportClash?

    var expandedFolders: Set<String> {
        didSet { UserDefaults.standard.set(expandedFolders.sorted(), forKey: Self.key("expandedFolders", id)) }
    }
    var foldedHeadings: Set<String> {
        didSet { UserDefaults.standard.set(foldedHeadings.sorted(), forKey: Self.key("foldedHeadings", id)) }
    }
    private static let sidebarKeys = ["expandedFolders", "foldedHeadings"]
    private static func key(_ name: String, _ id: String) -> String { "\(name).\(id)" }

    static func moveSidebarState(from id: String, to new: String) {
        let defaults = UserDefaults.standard
        for name in sidebarKeys {
            guard let value = defaults.object(forKey: key(name, id)) else { continue }
            defaults.set(value, forKey: key(name, new))
            defaults.removeObject(forKey: key(name, id))
        }
    }

    static func forgetSidebarState(of id: String) {
        for name in sidebarKeys { UserDefaults.standard.removeObject(forKey: key(name, id)) }
    }

    let search: ProjectSearch

    let editor = SourceEditor()
    @ObservationIgnored private weak var app: AppModel?
    private let core = Core.shared
    @ObservationIgnored private var analysis: Task<Void, Never>?
    // Each of these is cancelled by the next request of its kind, which then has the editor or viewer.
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var pdfLoad: Task<Bool, Never>?
    /// The build's events in turn: a finished build's PDF is shown before the next event says what follows it.
    @ObservationIgnored private var buildLane: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var trashed: [UndoableTrash] = []
    private(set) var closed = false

    init(id: String, app: AppModel) {
        self.id = id
        self.app = app
        search = ProjectSearch(id: id)
        tree = FileTree(id: id)
        let defaults = UserDefaults.standard
        expandedFolders = Set(defaults.stringArray(forKey: Self.key("expandedFolders", id)) ?? [])
        foldedHeadings = Set(defaults.stringArray(forKey: Self.key("foldedHeadings", id)) ?? [])
        panel = BuildPanelModel(texpresso: texpresso)
        texpresso.onAlert = { [weak self] in self?.panel.show(.texpresso) }
        texpresso.onEnded = { [weak self] in Task { await self?.endLivePDF() } }
        texpresso.readStatus = { [weak self] in
            guard let self, let session else { return nil }
            return try? await core.session("session_live_status", ["session": session], as: TeXpressoStatus.self)
        }
        tree.onChange = { [weak self] in
            self?.openKindChanged()
            self?.analyze()
        }
        texpresso.showDocument = { [weak self] in self?.showLive($0) }
        texpresso.showPage = { [weak self] page, index in
            if self?.livePDF == true { self?.pdf.showLive(page, at: index) }
        }
        texpresso.shownPages = { [weak self] in self?.pdf.view.document?.pageCount ?? 0 }
        pdf.onVisiblePages = { [weak self] in self?.liveView($0) }
        pdf.buildBehindLive = { [weak self] in self.flatMap { $0.livePDF ? $0.buildPDF : nil } }
    }

    var isLaTeX: Bool { openKind == .tex }
    var headingStyles: [HeadingStyle] {
        HeadingStyle.styles(of: documentClass, hasChapters: outline.contains { $0.level == 1 })
    }

    var headingLevel: HeadingLevel {
        outline.first { $0.file == openPath && $0.line == cursorLine }.flatMap { HeadingLevel.atDepth($0.level) } ?? .normalText
    }
    var editsText: Bool { openKind?.isText == true }

    private func openKindChanged() {
        guard let openPath else {
            openKind = nil
            return
        }
        if let kind = tree.node(at: openPath)?.kind, kind != openKind { openKind = kind }
    }

    private func isText(_ path: String) -> Bool { tree.node(at: path)?.kind?.isText == true }

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
    /// The session builds by itself only where TeX is.
    private var autoCompile: Bool { (app?.autoCompile ?? false) && texAvailable }

    private func report(_ error: any Error, _ title: String) {
        app?.alert = AppAlert(title, error)
    }

    let notices = ProjectNotices()

    /// A SyncTeX search that finds no match is ordinary (a comment, the preamble, a figure); anything else is a failure to explain.
    private func reportSync(_ error: any Error, _ title: String) {
        guard (error as? CoreError)?.status == 404 else { return report(error, title) }
        NSSound.beep()
        notices.note(error.localizedDescription)
    }

    var saved: SavedWorkspace {
        SavedWorkspace(project: id, file: openPath, line: cursorLine, buildPanel: panel.shown, pdfPage: pdf.restorePage ?? pdf.page,
                       pdfZoom: pdf.restoreZoom ?? pdf.zoom)
    }

    // MARK: - Loading

    /// Stops if the project is left meanwhile, so it never writes to the editor after the next one.
    func load(restoring saved: SavedWorkspace?) async {
        editor.onCursor = { [weak self] line, column in
            guard let self else { return }
            cursorLine = line
            cursorColumn = column
            (currentLine, caretMoved) = (line, true)
            findHeadings()
            liveCaret()
        }
        editor.textView.composing = { [weak self] composing in self?.composing(composing) }
        editor.onScroll = { [weak self] line in
            guard let self else { return }
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
            return outline.filter { $0.file == self.openPath }.map { ($0.line, $0.displayTitle) }
        }
        editor.textView.forwardSync = { [weak self] quietly in
            self?.hasPDF == true && self?.isLaTeX == true ? { Task { await self?.forwardSync(quietly: quietly) } } : nil
        }
        if let saved {
            panel.shown = saved.buildPanel
            pdf.restorePage = saved.pdfPage
            pdf.restoreZoom = saved.pdfZoom
        }
        // The PDF loads while the file is read and analysed, and is shown before the workspace appears, so the pane doesn't open on its empty state.
        async let pdfShown = showPDFOnDisk()
        do {
            settings = try await core.call("get_settings", ["id": id], as: ProjectSettings.self)
            // With automatic builds and no PDF, the session starts one.
            let auto = autoCompile
            guard let opened = try await core.session("session_open", ["id": id, "autoCompile": auto], as: SessionOpened.self) else {
                throw CoreError(message: String(localized: "The project’s files couldn’t be read."))
            }
            guard !closed else {
                core.send("session_close", ["session": opened.session])
                return
            }
            session = opened.session
            sentAutoCompile = auto
            root = URL(filePath: opened.root, directoryHint: .isDirectory)
            // The tree as it opened, before any event's newer one.
            tree.show(opened.tree)
            core.observe(opened.session) { [weak self] type, event in self?.handle(type, event) }
            let restored = saved?.file.flatMap { tree.node(at: $0) == nil ? nil : $0 }
            if let file = restored ?? settings?.mainFile { await open(file, line: restored == nil ? nil : saved?.line) }
            await analysis?.value
        } catch {
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

    /// The preference, or whether TeX is found, changed.
    func optionsChanged() {
        guard let session, !closed, sentAutoCompile != autoCompile else { return }
        sentAutoCompile = autoCompile
        core.send("session_set_options", ["session": session, "autoCompile": autoCompile])
    }

    /// A no-op build's PDF is already shown: reopening every page would lose PDFKit's state.
    @discardableResult private func showPDFOnDisk(reloadIfUnchanged: Bool = true, replacingLive: Bool = false) async -> Bool {
        await restart(&pdfLoad) { [self] in
            guard !closed, let path = try? await core.call("pdf_path", ["id": id], as: String.self),
                  !Task.isCancelled, !closed else { return false }
            let url = URL(filePath: path)
            var live: Bool { replacingLive ? texpresso.active : livePDF }
            if live {
                buildPDF = FileManager.default.fileExists(atPath: path) ? url : nil
                return true
            }
            if !reloadIfUnchanged, shown == .build(url) { return true }
            guard let document = await PDFController.loadDocument(url), !Task.isCancelled, !closed, !live else { return false }
            buildPDF = url
            shown = .build(url)
            pdf.show(document)
            return true
        }.value
    }

    private func endLivePDF() async {
        guard livePDF, !texpresso.active, !(await showPDFOnDisk(replacingLive: true)), livePDF, !texpresso.active, !closed else { return }
        shown = .none
        pdf.clear()
    }

    private func showLive(_ live: LiveDocument) {
        guard texpresso.active, !closed else { return }
        if !livePDF, app?.showPDF == false { app?.showPDF = true }
        shown = .live(live.url)
        pdf.showLive(live.document, changed: live.changed, complete: live.complete)
    }

    // MARK: - The session's events

    private func handle(_ type: String, _ event: Data) {
        guard !closed else { return }
        func decoded<T: Decodable>(_ kind: T.Type) -> T? { Core.decode(kind, event, type) }
        switch type {
        case "document": if let state = decoded(DocumentState.self) { documentChanged(state) }
        case "saved": analyze()
        case "document_reload": if let reloaded = decoded(ReloadEvent.self) { reload(reloaded) }
        case "document_closed": if let gone = decoded(PathEvent.self) { documentClosed(gone) }
        case "document_renamed": if let renamed = decoded(RenamedEvent.self) { documentRenamed(renamed) }
        case "conflict": if let asked = decoded(ConflictEvent.self) { conflict(asked) }
        case "issues": if let marked = decoded(IssuesEvent.self) { markIssues(marked) }
        case "build": if let state = decoded(BuildState.self) { inOrder { self.buildChanged(state) } }
        case "build_finished": if let finished = decoded(BuildFinished.self) { inOrder { await self.buildFinished(finished) } }
        case "build_cleaned": inOrder { self.buildCleaned() }
        case "tree": if let listed = decoded(TreeEvent.self) { treeChanged(listed) }
        case "files_changed": if let changed = decoded(PathsEvent.self) { filesChanged(changed) }
        case "live": if let state = decoded(LiveState.self) { texpresso.receive(state) }
        case "live_document": if let document = decoded(LiveDocumentEvent.self) { texpresso.receive(document) }
        case "live_page": if let page = decoded(LivePageEvent.self) { texpresso.receive(page) }
        case "live_restarted": notices.note(String(localized: "Live Preview Restarted"))
        default: break
        }
    }

    private func documentChanged(_ state: DocumentState) {
        let before = documents[state.path]
        documents[state.path] = state
        if !state.held { heldReasons[state.path] = nil }
        if state.error != nil, before?.error == nil { notices.announce(String(localized: "“\(state.path.fileName)” Wasn’t Saved")) }
    }

    /// Another app's text, or the disk's after Revert: shown without an edit, as the session waits for to save the file again.
    private func reload(_ event: ReloadEvent) {
        if editor.path == event.path {
            let top = topLine
            editor.reload(text: event.text)
            analyze()
            editor.reveal(line: top, atTop: true, focus: false)
            cursorLine = editor.currentLine
        } else if let session, let source = SourceDocument(session: session, path: event.path) {
            source.reload(event.text)
        }
    }

    private func documentClosed(_ event: PathEvent) {
        documents[event.path] = nil
        heldReasons[event.path] = nil
        lineIssues[event.path] = nil
        if openPath == event.path, !closingDocuments.contains(event.path) { clearOpenFile() }
    }

    /// The editor follows the rename's own answer, which covers a folder's files it keeps too.
    private func documentRenamed(_ event: RenamedEvent) {
        documents[event.to] = documents.removeValue(forKey: event.from)
        heldReasons[event.to] = heldReasons.removeValue(forKey: event.from)
        lineIssues[event.to] = lineIssues.removeValue(forKey: event.from)
        if openPath == event.from { openPath = event.to }
    }

    private func conflict(_ event: ConflictEvent) {
        if event.kind == "gone" { missingFile = event.path } else { diskConflict = event.path }
    }

    private func markIssues(_ event: IssuesEvent) {
        let lines = Dictionary(event.lines.map { ($0.line, SourceTextView.LineIssue(isError: $0.error, message: $0.message, others: $0.others)) }) { $1 }
        lineIssues[event.path] = lines.isEmpty ? nil : lines
        if editor.path == event.path { editor.textView.issueLines = lines }
    }

    private func treeChanged(_ event: TreeEvent) {
        tree.show(event.tree)
        // A file previewed, not edited, that went: the session has no document of it to close.
        if let openPath, !editsText, tree.node(at: openPath) == nil { clearOpenFile() }
    }

    private func filesChanged(_ event: PathsEvent) {
        if let openPath, !editsText, event.paths.contains(openPath) { previewVersion += 1 }
        if event.paths.contains(where: { tree.node(at: $0)?.kind == .tex }) { analyze() }
    }

    @discardableResult
    private func inOrder(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = buildLane
        let task = Task {
            await previous?.value
            await work()
        }
        buildLane = task
        return task
    }

    // MARK: - Editing

    /// Only the latest open carries on, so the editor can't show one file while `openPath` names another.
    func open(_ path: String, line: Int? = nil, column: Int? = nil, atTop: Bool = false, focus: Bool = true) async {
        await restart(&openTask) { [self] in
            if path != openPath {
                guard let session else { return }
                do {
                    // A file made a moment ago may not be in the tree yet.
                    if tree.node(at: path) == nil { await tree.reload() }
                    // Read first and closed last, with nothing awaited between the close and the switch.
                    if isText(path) {
                        _ = try await core.session("session_open_document", ["session": session, "path": path], as: FileText.self)
                    }
                    guard !Task.isCancelled, !closed else { return }
                    if let was = openPath, editsText {
                        guard await closeDocument(was), !closed else { return }
                    }
                    show(path, focus: focus)
                } catch {
                    if !Task.isCancelled, !closed { report(error, "Couldn’t Open “\(path.fileName)”") }
                    return
                }
            }
            if let line, editsText, !Task.isCancelled, !closed { editor.reveal(line: line, column: column, atTop: atTop, focus: focus) }
        }.value
    }

    /// Its text as the session's document has it now, whatever reloads came while it opened.
    private func show(_ path: String, focus: Bool) {
        openPath = path
        openKind = tree.node(at: path)?.kind
        analyze()
        guard editsText else { return }
        guard let session, let source = SourceDocument(session: session, path: path) else {
            openPath = nil
            return
        }
        editor.open(path: path, text: source.text, source: source, focus: focus)
        cursorLine = editor.currentLine
        editor.textView.issueLines = lineIssues[path] ?? [:]
    }

    /// Saved first; false, staying open, if that failed or asks about the disk.
    private func closeDocument(_ path: String) async -> Bool {
        guard let session else { return true }
        closingDocuments.insert(path)
        defer { closingDocuments.remove(path) }
        do {
            return try await core.session("session_close_document", ["session": session, "path": path], as: Closed.self)?.closed ?? true
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
        guard let located = try? core.now("locate", ["path": url.path(percentEncoded: false)], as: Located.self),
              located.id == id, !located.path.isEmpty else { return nil }
        return located.path
    }

    private func dropped(_ url: URL) -> SourceTextView.FileDrop? {
        guard let path = projectPath(url), let node = tree.node(at: path), !node.isDirectory else { return nil }
        if isLaTeX, node.kind == .image || node.kind == .pdf {
            return .insert("\\includegraphics{\(path)}")
        }
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
            return try await core.session("session_save", ["session": session, "reporting": reporting], as: Saved.self)?.saved ?? false
        } catch {
            if reporting, !closed { report(error, String(localized: "“\((openPath ?? id).fileName)” Wasn’t Saved")) }
            return false
        }
    }

    private func analyze() {
        analysis?.cancel()
        guard isLaTeX, let path = openPath else {
            outline = []
            outlineTree = []
            headings = []
            words = nil
            findHeadings()
            return
        }
        analysis = Task {
            guard let doc = try? await core.call("analyze_project", ["id": id, "file": path], as: Analysis.self),
                  !Task.isCancelled else { return }
            outline = doc.outline.enumerated().map { index, heading in
                var item = heading
                item.id = index
                return item
            }
            outlineTree = doc.tree
            headings = doc.outline.map(\.heading)
            words = doc.words
            findHeadings()
            // The class changes with the main file only.
            guard let main = settings?.mainFile, main == path || main != classFile,
                  let text = main == path ? editor.document?.text
                    : try? await readText(main),
                  !Task.isCancelled else { return }
            documentClass = DocumentClass(in: text)
            classFile = main
        }
    }

    /// A scroll makes the top line's heading the current one only as it passes a heading, and a caret's move wins over a
    /// scroll at the same time.
    private func findHeadings() {
        let top = topLine
        findingHeadings?.cancel()
        findingHeadings = Task {
            let atTop = await heading(at: top)
            guard !Task.isCancelled else { return }
            if atTop != topHeading {
                topHeading = atTop
                if !caretMoved { currentLine = top }
            }
            caretMoved = false
            var current = atTop
            if currentLine != top { current = await heading(at: currentLine) }
            if !Task.isCancelled, current != currentHeading { currentHeading = current }
        }
    }

    private func heading(at line: Int) async -> Int? {
        guard !headings.isEmpty else { return nil }
        return try? await core.answer("outline_current", ["outline": headings, "file": openPath, "line": line], as: Int.self)
    }

    private func readText(_ path: String) async throws -> String {
        try await core.call("read_file", ["id": id, "path": path], as: FileText.self).text
    }

    // MARK: - Changes on disk

    func keepEdits(_ path: String) {
        diskConflict = nil
        resolve(path, "save")
    }

    func revertToDisk(_ path: String) {
        diskConflict = nil
        resolve(path, "revert")
    }

    func saveMissingFile(_ path: String) {
        missingFile = nil
        resolve(path, "save")
    }

    func closeMissingFile(_ path: String) {
        missingFile = nil
        resolve(path, "close")
        if openPath == path { clearOpenFile() }
    }

    /// Cancel: the edits stay unsaved, and the autosave quiet, until a save is asked for, which asks again.
    func leaveUnsaved(_ path: String, _ reason: String) {
        (diskConflict, missingFile) = (nil, nil)
        heldReasons[path] = reason
        resolve(path, "cancel")
    }

    private func resolve(_ path: String, _ answer: String) {
        guard let session else { return }
        Task {
            do {
                _ = try await core.session("session_resolve", ["session": session, "path": path, "answer": answer], as: Saved.self)
            } catch {
                if !closed { report(error, String(localized: "“\(path.fileName)” Wasn’t Saved")) }
            }
        }
    }

    // MARK: - Compile

    /// The session queues one more during a build, and leaves an automatic one while Live Preview runs.
    func compile(auto: Bool = false) async {
        guard let session, !closed, texAvailable else { return }
        do {
            try await core.session("session_compile", ["session": session, "auto": auto])
        } catch {
            if !closed { report(error, String(localized: "“\((openPath ?? id).fileName)” Wasn’t Saved")) }
        }
    }

    func stopCompile() {
        guard compiling, let session else { return }
        core.send("session_stop_compile", ["session": session])
    }

    func cleanBuildFolder() async {
        guard let session, !closed else { return }
        do {
            // Not in the session's lane: it waits for the build it stops.
            try await core.perform("session_clean", ["session": session])
        } catch {
            if !closed { report(error, "Couldn’t Clean the Build Folder") }
            return
        }
        await inOrder { self.buildCleaned() }.value
    }

    private func buildChanged(_ state: BuildState) {
        // Not through `notices.announce`: the result of a short build isn't held back for it.
        if state.compiling, !compiling, !state.auto { AccessibilityNotification.Announcement(String(localized: "Compiling")).post() }
        (compiling, outdated) = (state.compiling, state.outdated)
    }

    private func buildFinished(_ finished: BuildFinished) async {
        let result = finished.result
        if result.pdf != nil, !closed {
            await showPDFOnDisk(reloadIfUnchanged: result.pdfChanged)
            // Not after typing through the build: the PDF hasn't the caret's text yet, and the sync would save it mid-word and start the next build at once.
            if result.ok, !finished.outdated, app?.showPDF == true, isLaTeX, UserDefaults.standard.bool(forKey: DefaultsKey.syncAfterCompile) {
                Task { await forwardSync(quietly: true) }
            }
        }
        guard !closed else { return }
        self.result = result
        outdated = finished.outdated
        chosenIssue = nil
        finishedBuilds += 1
        if !finished.auto {
            finishedManualBuild(result)
        } else if finished.announce {
            announceResult(result, queued: true)
        }
    }

    private func buildCleaned() {
        guard !closed else { return }
        pdfLoad?.cancel()
        buildPDF = nil
        if !livePDF {
            shown = .none
            pdf.clear()
        }
        result = nil
        chosenIssue = nil
        outdated = false
    }

    private func finishedManualBuild(_ result: CompileResult) {
        if result.failed {
            panel.openForFailedBuild()
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        } else if result.ok, issues.isEmpty {
            panel.closeAfterCleanBuild()
        }
        announceResult(result)
    }

    private func announceResult(_ result: CompileResult, queued: Bool = false) {
        if result.failed {
            notices.announce(errorCount == 0 ? String(localized: "Build failed")
                     : String(AttributedString(localized: "Build failed, ^[\(errorCount) error](inflect: true)").characters), queued: queued)
        } else if result.ok {
            notices.announce(String(localized: "Build succeeded"), queued: queued)
        }
    }

    // MARK: - Issues

    func chooseIssue(_ place: Int?, focus: Bool, open: Bool = true) {
        chosenIssue = place
        if let session { core.send("session_choose_issue", ["session": session, "index": place]) }
        let issues = issues
        guard open, let place, issues.indices.contains(place), let file = issues[place].file else { return }
        Task { await self.open(file, line: issues[place].line, focus: focus) }
    }

    func goToIssue(next: Bool) {
        guard let session else { return }
        Task {
            guard let chosen = try? await core.session("session_issue", ["session": session, "next": next], as: ChosenIssue.self),
                  !closed else { return }
            panel.show(.issues)
            chosenIssue = chosen.index
            if let file = chosen.issue.file { await open(file, line: chosen.issue.line, focus: true) }
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
        openTask?.cancel()
        syncTask?.cancel()
        pdfLoad?.cancel()
        // The session saves what it can, and stops its build and Live Preview.
        if let session {
            core.forget(session)
            closing = Task { _ = try? await core.session("session_close", ["session": session]) }
        }
    }

    /// Once the session has stopped its build and Live Preview, so another model can't race it for the project's.
    func waitUntilClosed() async {
        await closing?.value
    }

    // MARK: - Settings

    /// Shown at once; put back if the session refuses it.
    func patchSettings(_ change: SettingsChange) async -> Bool {
        guard let session, !closed else { return false }
        let before = settings
        settings?.apply(change)
        do {
            guard let updated = try await core.session("session_set_settings", ["session": session, "patch": change.patch],
                                                       as: ProjectSettings.self) else { return false }
            guard !closed else { return false }
            settings = updated
            if updated.mainFile != before?.mainFile { mainFileChanged() }
            return true
        } catch {
            if !closed {
                settings = before
                report(error, "Couldn’t Change the Project’s Settings")
            }
            return false
        }
    }

    /// A build follows when automatic: the session's.
    func setBuildOption(_ change: SettingsChange) async {
        _ = await patchSettings(change)
    }

    func setMainFile(_ path: String) async {
        _ = await patchSettings(.mainFile(path))
    }

    /// The session stops the build, restarts Live Preview and builds the new one; the PDF is the new main file's.
    private func mainFileChanged() {
        analyze()
        Task { await showPDFOnDisk() }
    }

    // MARK: - Live preview

    func startTeXpresso() {
        guard !closed, let session, texpresso.canStart else { return }
        if let pages = pdf.visiblePages { core.send("session_live_view", ["session": session, "first": pages.lowerBound, "last": pages.upperBound]) }
        texpresso.starting()
        liveCaret()
        core.send("session_live_start", ["session": session])
    }

    func stopTeXpresso() {
        guard let session else { return }
        texpresso.stopping()
        Task {
            if let state = try? await core.session("session_live_stop", ["session": session], as: LiveState.self) { texpresso.stopped(state) }
        }
        // Its pages go now, not as its stop ends.
        Task { await endLivePDF() }
    }

    private func liveView(_ pages: ClosedRange<Int>) {
        guard texpresso.active, let session else { return }
        core.send("session_live_view", ["session": session, "first": pages.lowerBound, "last": pages.upperBound])
    }

    /// Told as it moves; the session tells TeXpresso where it settles.
    private func liveCaret() {
        guard texpresso.active, let session, let path = editor.path else { return }
        core.send("session_live_caret", ["session": session, "path": path, "offset": editor.textView.selectedRange().location])
    }

    // MARK: - SyncTeX

    func forwardSync(quietly: Bool = false) async {
        guard let path = openPath else { return }
        let (line, column) = (editor.currentLine, editor.currentColumn)
        let live = livePDF, args = syncArguments(["id": id, "file": path, "line": line, "column": column])
        await restart(&syncTask) { [self] in
            guard await save(reporting: !quietly), !Task.isCancelled, !closed, openPath == path else { return }
            // Only on the pages it was found in: a rebuild may have moved it.
            let shown = pdf.shownVersion
            do {
                let loc = try await core.call("synctex_forward", args, as: ForwardLoc.self)
                guard !Task.isCancelled, !closed, openPath == path, pdf.shownVersion == shown, livePDF == live else { return }
                app?.requestPDF(.reveal(loc, SyncSource(id: id, file: path, line: line, column: column)))
            } catch {
                if !quietly, !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Line in the PDF") }
            }
        }.value
    }

    private func syncArguments(_ arguments: [String: any Sendable]) -> [String: any Sendable] {
        guard livePDF, let token = texpresso.token else { return arguments }
        return arguments.merging(["live": true, "session": token]) { $1 }
    }

    /// With the click, the core finds the clicked word in the source lines round SyncTeX's.
    func inverseSync(page: Int, x: Double, y: Double, click: PageClick? = nil) async {
        await restart(&syncTask) { [self] in
            do {
                // A nil click bridges as null, which the core reads as none.
                let args = syncArguments(["id": id, "page": page, "x": x, "y": y, "text": click?.text, "at": click?.at])
                let loc = try await core.call("synctex_inverse", args, as: InverseLoc.self)
                guard !Task.isCancelled, !closed else { return }
                await open(loc.file, line: loc.line, column: loc.column)
            } catch {
                if !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Spot in the Source") }
            }
        }.value
    }

    // MARK: - Files

    func createEntry(in folder: String, directory: Bool) async -> String? {
        let name = directory ? "untitled folder" : "untitled.tex"
        let made: String
        do {
            // A taken name is numbered on ("untitled 2.tex").
            made = try await core.call("create_entry", ["id": id, "path": folder.isEmpty ? name : "\(folder)/\(name)", "dir": directory,
                                                        "free": true], as: PathEvent.self).path
        } catch {
            if !closed { report(error, "Couldn’t Create “\(name)”") }
            return nil
        }
        guard !closed else { return nil }
        await tree.reload()
        if !directory { await open(made, focus: false) }
        return made
    }

    func renameEntry(_ from: String, to: String, action: String = String(localized: "Rename")) async {
        if let result = await performRename(from, to: to) { registerRenameUndo(result, action: action) }
    }

    /// The Redo is registered as the Undo starts, as `UndoableTrash`'s are, and one that fails takes it away. The closures hold the model: the manager doesn't.
    private func registerRenameUndo(_ result: RenameResult, action: String) {
        guard let undo = app?.undoManager else { return }
        undo.registerUndo(withTarget: self) { _ in
            self.registerRenameUndo(RenameResult(from: result.to, to: result.from, mainFile: result.mainFile), action: action)
            Task {
                if await self.performRename(result.to, to: result.from) == nil { self.app?.undoManager?.removeAllActions(withTarget: self) }
            }
        }
        undo.setActionName(action)
    }

    /// The session saves first and moves its open documents; the editor keeps its text and undo under the new name.
    private func performRename(_ from: String, to: String) async -> RenameResult? {
        guard to != from, let session, !closed else { return nil }
        let (before, wasText) = (openPath, editsText)
        let renamed: RenameResult?
        do {
            renamed = try await core.session("session_rename", ["session": session, "from": from, "to": to], as: RenameResult.self)
        } catch {
            if !closed { report(error, "Couldn’t Rename “\(from.fileName)”") }
            return nil
        }
        guard let result = renamed, !closed else { return nil }
        editor.rename(from: result.from, to: result.to)
        let now = before.map { remapPath($0, from: result.from, to: result.to) }
        let moved = now != before && (openPath == before || openPath == now)
        if moved { openPath = now }
        let mainChanged = result.mainFile != settings?.mainFile
        settings?.mainFile = result.mainFile
        // The new name's kind is the tree's.
        await tree.reload()
        if moved, let now, openPath == now, !closed {
            // A text file now previewed, or the other way: shown afresh.
            if isText(now) != wasText {
                if wasText { _ = await closeDocument(now) }
                if openPath == now { clearOpenFile() }
                await open(now, focus: false)
            } else {
                analyze()
            }
        }
        if mainChanged, !closed { mainFileChanged() }
        return result
    }

    func deleteEntry(_ path: String) async {
        guard let original = url(path) else { return }
        let item = UndoableTrash(
            original: original, name: path.fileName, undoManager: app?.undoManager,
            trash: { [weak self] item in await self?.trashEntry(path, item) ?? false },
            changed: { [weak self] in await self?.tree.reload() },
            failed: { [weak self] title, error in self?.report(error, title) })
        trashed.append(item)
        await item.moveToTrash()
        if !closed { await tree.reload() }
    }

    /// The session saves and holds its saves under `path`, so no autosave makes the file again, and refuses the main file;
    /// the Trash is the app's, so the move can be undone.
    private func trashEntry(_ path: String, _ item: UndoableTrash) async -> Bool {
        guard let session, !closed else { return false }
        let title = "Couldn’t Move “\(path.fileName)” to the Trash"
        do {
            guard try await core.session("session_prepare_delete", ["session": session, "path": path], as: Ready.self)?.ready == true,
                  !closed else { return false }
        } catch {
            guard !closed else { return false }
            report(error, title)
            // Another window may have made it the main file.
            if (error as? CoreError)?.status == 409, let read = try? await core.call("get_settings", ["id": id], as: ProjectSettings.self) {
                settings = read
            }
            return false
        }
        do {
            try item.recycle()
        } catch {
            core.send("session_deleted", ["session": session, "path": path, "trashed": false])
            report(error, title)
            return false
        }
        core.send("session_deleted", ["session": session, "path": path])
        editor.forget(path: path)
        if let open = openPath, open == path || open.hasPrefix(path + "/") { clearOpenFile() }
        return true
    }

    private func clearOpenFile() {
        openPath = nil
        analyze()
    }

    func dropFiles(_ urls: [URL], into dir: String) async {
        var outside: [URL] = []
        for url in urls {
            guard let path = projectPath(url) else { outside.append(url); continue }
            guard path.parentFolder != dir, dir != path, !dir.hasPrefix(path + "/") else { continue }
            await renameEntry(path, to: dir.isEmpty ? path.fileName : "\(dir)/\(path.fileName)",
                               action: String(localized: "Move"))
        }
        if !outside.isEmpty { await importFiles(outside, into: dir) }
    }

    func importFiles(_ urls: [URL], into dir: String = "", conflict: String? = nil) async {
        var args: [String: any Sendable] = ["id": id, "dir": dir, "paths": urls.map { $0.path(percentEncoded: false) }]
        args["conflict"] = conflict
        do {
            let clashes = try await core.call("import_files", args, as: Imported.self).existing.map(\.path)
            if conflict == nil, !clashes.isEmpty { importClash = ImportClash(urls: urls, dir: dir, names: clashes) }
        } catch {
            report(error, "Couldn’t Add the Files")
        }
        // After a failure too: the files copied before it are there.
        await tree.reload()
    }

    // MARK: - Export

    /// The core archives the files on disk, so the edits are saved first: an archive without them would be a stale copy reported as a good one.
    func exportZip() async throws -> URL {
        guard await save() else {
            let name = openPath?.fileName ?? id
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedFailureReasonErrorKey: String(localized: "“\(name)” couldn’t be saved, so the archive would be missing its changes."),
            ])
        }
        removeExport()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        exportFolder = folder
        let url = folder.appending(path: "\(id).zip")
        try await core.perform("export_zip", ["id": id, "dest": url.path(percentEncoded: false)])
        return url
    }

    @ObservationIgnored private var exportFolder: URL?

    private func removeExport() {
        if let exportFolder { try? FileManager.default.removeItem(at: exportFolder) }
        exportFolder = nil
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

struct ImportClash {
    let urls: [URL]
    let dir: String
    let names: [String]

    var title: String {
        guard names.count == 1, let name = names.first else {
            return "\(names.count) items with these names already exist in this location."
        }
        return "An item named “\(name.fileName)” already exists in this location."
    }

    var message: String {
        let replace = names.count == 1
            ? "Do you want to replace it with the one you’re copying? The one here goes to the Trash."
            : "Do you want to replace them with the ones you’re copying? The ones here go to the Trash."
        guard names.count > 1 else { return replace }
        let shown = names.prefix(3).map { "“\($0)”" }
        let more = names.count > shown.count ? ["\(names.count - shown.count) more"] : []
        return (shown + more).formatted(.list(type: .and)) + ". " + replace
    }
}

// MARK: - The session's answers and events (docs/core-api.md)

nonisolated struct SessionOpened: Decodable, Sendable {
    let session: UInt64
    let root: String
    let tree: [TreeNode]
}

nonisolated struct Located: Decodable, Sendable { let id, path: String }
nonisolated struct Saved: Decodable, Sendable { let saved: Bool }
nonisolated struct Closed: Decodable, Sendable { let closed: Bool }
nonisolated struct Ready: Decodable, Sendable { let ready: Bool }
nonisolated struct ChosenIssue: Decodable, Sendable { let index: Int, issue: LogItem }

nonisolated struct DocumentState: Decodable, Equatable {
    let path: String
    let error: String?
    let held: Bool
}

nonisolated struct ReloadEvent: Decodable { let path, text: String }
nonisolated struct PathEvent: Decodable, Sendable { let path: String }
nonisolated struct RenamedEvent: Decodable { let from, to: String }
nonisolated struct ConflictEvent: Decodable { let path, kind: String }
nonisolated struct TreeEvent: Decodable { let tree: [TreeNode] }
nonisolated struct PathsEvent: Decodable { let paths: [String] }
nonisolated struct BuildState: Decodable { let compiling, auto, outdated: Bool }

nonisolated struct BuildFinished: Decodable {
    let auto, announce, outdated: Bool
    let result: CompileResult
}

nonisolated struct IssuesEvent: Decodable {
    nonisolated struct Line: Decodable {
        let line: Int
        let error: Bool
        let message: String
        let others: [String]
    }

    let path: String
    let lines: [Line]
}
