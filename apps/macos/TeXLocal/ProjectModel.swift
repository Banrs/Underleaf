import AppKit
import Observation
import UniformTypeIdentifiers

/// A project's window state over its core session (docs/core-api.md), which owns its text, saves, builds and Live Preview.
@Observable
final class ProjectModel {
    let id: String
    /// The listing's until the session answers with its own; an opened folder's id is no name.
    private(set) var name: String
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
    /// Go Back's and Go Forward's, from the session's last answer.
    var trail = Trail()

    @ObservationIgnored private(set) var session: UInt64?
    @ObservationIgnored private var root: URL?
    private var documents: [String: OpenDocument] = [:]
    private struct OpenDocument {
        var state: DocumentState?
        /// Why a document held after Cancel in an alert isn't saved.
        var heldReason: String?
        var lineIssues: [Int: IssuesEvent.Line] = [:], liveIssues: [Int: IssuesEvent.Line] = [:]
    }
    @ObservationIgnored private var composingPath: String?
    /// A `tree` event came before the session's open answered with an older tree.
    @ObservationIgnored private var treeChanged = false

    var compiling = false
    var outdated = false
    /// One at a time, as tlmgr takes one and a fix is followed by a build.
    var fixing: LogItem.Fix?
    var result: CompileResult?
    /// What the session finds wrong without TeX, kept through builds and cleans.
    var checks: [LogItem] = []
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

    /// In the session's order, which an `issues` line's `index` numbers.
    var issues: [LogItem] { (result?.errors ?? []) + (result?.warnings ?? []) + checks }
    /// The bad boxes after the issues, as Overleaf lists its typesetting warnings: numbered on from them, which the session
    /// numbers alone.
    var listed: [LogItem] { issues + (result?.badBoxes ?? []) }

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
    /// The session's last `outline`.
    @ObservationIgnored private var analysis: Analysis?
    @ObservationIgnored private var opens: Task<Void, Never>?
    @ObservationIgnored private var openRequests = 0
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var pdfLoad: Task<Bool, Never>?
    /// A finished build's PDF is shown before the next build event.
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
        // The session sends the log while the panel shows it.
        liveLogWatch = track({ [panel] in panel.showsLiveLog }, initial: false) { [weak self] shown in
            guard let self else { return }
            if let session { core.send("session_live_log", ["session": session, "shown": shown]) }
            if !shown { texpresso.logClosed() }
        }
        tree.onChange = { [weak self] in self?.openKindChanged() }
        pdf.onVisiblePages = { [weak self] in self?.liveView($0) }
    }

    var isLaTeX: Bool { openKind == .tex }
    /// The toolbar's LaTeX tools act on the source, so only while it shows.
    var sourceToolsEnabled: Bool { isLaTeX && app?.showSource == true }

    /// The caret's line's sectioning command: empty for Normal Text.
    var headingCommand: String { outline.first { $0.file == openPath && $0.line == cursorLine }?.command ?? "" }
    var editsText: Bool { openKind?.isText == true }

    private func openKindChanged() {
        defer { showOutline() }
        guard let openPath else { return openKind = nil }
        if let kind = tree.node(at: openPath)?.kind, kind != openKind { openKind = kind }
    }

    func isText(_ path: String) -> Bool { tree.node(at: path)?.kind?.isText == true }

    /// The status bar's Not Saved: after a failed save, or Cancel in an alert about the file on disk.
    var saveFailure: String? {
        for (path, document) in documents.sorted(by: { $0.key < $1.key }) {
            if let error = document.state?.error { return error }
            if document.state?.held == true { return document.heldReason ?? String(localized: "“\(path.fileName)” wasn’t saved.") }
        }
        return nil
    }

    /// One spelling for every failed save, as `AppModel.report` drops an alert whose title is the one showing.
    func notSavedTitle(_ path: String? = nil) -> String { String(localized: "“\((path ?? openPath)?.fileName ?? name)” Wasn’t Saved") }

    /// With the checks', as Xcode's counts include its live issues.
    var errorCount: Int { issues.count(where: \.isError) }
    var warningCount: Int { issues.count - errorCount }

    var showsLastSuccessfulBuild: Bool { hasPDF && result?.failed == true && result?.pdf == nil }

    /// A closed project reports nothing.
    @discardableResult
    func alerting<T>(_ title: @autoclosure () -> String, _ work: () async throws -> T) async -> T? {
        await app?.alerting(title(), unless: { closed }, work) ?? nil
    }

    let notices = ProjectNotices()

    /// As the project is left and on quit, for `load` to show again; one that never loaded has no place of its own to keep.
    func savePlace() async {
        guard initialLoadComplete else { return }
        saveUIState(["file": openPath, "line": cursorLine, "page": pdf.keptPage, "zoom": pdf.keptZoom.json, "panel": panel.shown])
        await uiStateWrites?.value
    }

    // MARK: - Loading

    /// Stops if the project is left meanwhile.
    func load() async {
        connectEditor()
        let session = core.observe { [weak self] event in self?.handle(event) }
        // Shown before the workspace appears, so the pane doesn't open empty; the PDF's place waits for the view's size.
        async let pdfShown = showBuildPDF(try? await core.call("pdf_path", ["id": id], as: String.self))
        let ui: UIState
        do {
            // With automatic builds and no PDF, the session starts one.
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
            // The core may have opened it and failed only in its answer.
            core.send("session_close", ["session": session])
            // Home stays, with the alert over it.
            guard !closed else { return }
            app?.report(error, "Couldn’t Open “\(name)”")
            if app?.project === self { await app?.close() }
            return
        }
        _ = await pdfShown
        guard !closed else { return }
        initialLoadComplete = true
        // The core remembers the user's last Start or Stop, so Live Preview is per project.
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
                // Its log has TeX's own words round the error.
                panel.show(.texpresso)
            }
        }
        editor.textView.headings = { [weak self] in
            guard let self else { return [] }
            return outline.filter { $0.file == self.openPath }.map { ($0.line, $0.title) }
        }
        // Only to a PDF in view, quietly: a double-click would bring a hidden one back at each word selected.
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

    // MARK: - The session's events

    func handle(_ event: SessionEvent) {
        guard !closed else { return }
        switch event {
        case .document(let state): documentChanged(state)
        case .outline(let analysis):
            self.analysis = analysis
            showOutline()
        case .reload(let reloaded): reload(reloaded)
        case .closed(let gone):
            // One this model closed has the next file shown already.
            documents[gone.path] = nil
            if openPath == gone.path, gone.reason != "closed" { clearOpenFile() }
        case .renamed(let renamed):
            // The editor follows the rename's own answer (`performRename`).
            documents[renamed.to] = documents.removeValue(forKey: renamed.from)
        case .conflict(let asked) where asked.kind == .changed: diskConflict = asked.path
        case .conflict(let asked): missingFile = asked.path
        case .issues(let marked):
            documents[marked.path, default: OpenDocument()].lineIssues = marked.byLine
            if editor.path == marked.path { editor.textView.issues.lines = marked.byLine }
        case .liveIssues(let marked):
            documents[marked.path, default: OpenDocument()].liveIssues = marked.byLine
            if editor.path == marked.path { editor.textView.issues.live = marked.byLine }
        // After the build events before it, so the list numbers its rows as the session did then.
        case .checks(let found): inOrder { self.checks = found.items }
        case .build(let state): inOrder { self.buildChanged(state) }
        case .buildFinished(let finished): inOrder { await self.buildFinished(finished) }
        case .buildCleaned: inOrder { self.buildCleaned() }
        case .tree(let listed):
            treeChanged = true
            tree.show(listed.tree)
            // A previewed file has no document for the session to close.
            if let openPath, !editsText, tree.node(at: openPath) == nil { clearOpenFile() }
            // Another app may have chosen the main file in `.texlocal.json`; the session marks it in the tree it sends.
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
        } else if let session, let source = SourceDocument(session: session, path: event.path) {
            source.reload(event.text)
        }
    }

    @discardableResult func inOrder(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> { enqueue(&buildLane, work) }

    // MARK: - Editing

    /// After the opens asked for before it. One superseded meanwhile stops: the editor never shows a file without its
    /// document. A `jump` is one the person makes away from the caret, whose place
    /// Go Back returns to. It shows the source, as a PDF command shows the PDF, but for the project's own first file and a
    /// file its rename reopens.
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
                // A file made a moment ago may not be in the tree yet.
                if tree.node(at: path) == nil { await tree.reload() }
                let text = isText(path)
                do {
                    if text { try await core.call("session_open_document", ["session": session, "path": path]) }
                } catch {
                    if latest() { app?.report(error, "Couldn’t Open “\(path.fileName)”") }
                    return
                }
                guard latest() else {
                    // The session keeps no document the editor doesn't show.
                    if text { core.send("session_close_document", ["session": session, "path": path]) }
                    return
                }
                // Shown before the old one closes, so keys typed meanwhile go into the new one. One whose save fails stays
                // open in the session, Not Saved.
                let was = editsText ? openPath : nil
                show(path, focus: focus)
                if let was { await closeDocument(was) }
            }
            if let line, editsText, latest() { editor.reveal(line: line, column: column, length: length, atTop: atTop, focus: focus) }
        }.value
    }

    /// The session's text now, whatever reloads came while it opened.
    private func show(_ path: String, focus: Bool) {
        openPath = path
        guard editsText else { return }
        guard let session, let source = SourceDocument(session: session, path: path) else { openPath = nil; return }
        editor.open(path: path, text: source.text, source: source, focus: focus)
        editor.textView.issues.lines = documents[path]?.lineIssues ?? [:]
        editor.textView.issues.live = documents[path]?.liveIssues ?? [:]
    }

    /// Saved first; it stays open, Not Saved, if that failed or asks about the disk.
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

    /// The path in the project of a URL inside its folder, both resolved so /private/var and /var compare alike; asked as a drag moves.
    func projectPath(_ url: URL) -> String? {
        guard let folder = root?.resolvingSymlinksInPath().pathComponents else { return nil }
        let inside = url.resolvingSymlinksInPath().pathComponents
        guard inside.count > folder.count, inside.starts(with: folder) else { return nil }
        return inside.dropFirst(folder.count).joined(separator: "/")
    }

    private func dropped(_ url: URL) -> SourceTextView.FileDrop? {
        let into = openKind?.rawValue ?? ""
        guard let path = projectPath(url) else {
            // From outside, only a figure to insert: the sidebar adds other files.
            let type = UTType(filenameExtension: url.pathExtension)
            let kind = type?.conforms(to: .pdf) == true ? "pdf" : type?.conforms(to: .image) == true ? "image" : ""
            return Self.includeGraphics(url.lastPathComponent, kind: kind, into: into) == nil ? nil
                : .copy { [weak self] in await self?.copyFigure(url) }
        }
        guard let kind = tree.node(at: path)?.kind else { return nil }
        if let insert = Self.includeGraphics(path, kind: kind.rawValue, into: into) { return .insert(insert) }
        return .open { [weak self] in Task { await self?.open(path) } }
    }

    /// Beside the file shown, as a copy is named where its name is taken: its `\includegraphics`.
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

    /// A figure's `\includegraphics`, dropped in a TeX file: of images, those pdfTeX, XeTeX and LuaTeX alike read (not GIF,
    /// SVG, WebP or BMP), at a path TeX reads as written. `%`, `#` and `\` mean something else to it, and braces must pair;
    /// the rest (spaces, `_`, `&`, `$`, `^`, `~`) it takes as they are.
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

    /// While a LaTeX file shows; none for another.
    private func showOutline() {
        if isLaTeX, let analysis {
            (outline, outlineTree, headingStyles, words) = (analysis.outline, analysis.tree, analysis.headingStyles, analysis.words)
        } else {
            (outline, outlineTree, words) = ([], [], nil)
        }
        findHeadings()
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

    /// The last at or before `line` in the file shown, whose name the disk may spell in another case.
    private func heading(at line: Int) -> Int? {
        guard let openPath else { return nil }
        return outline.last { $0.line <= line && $0.file.caseInsensitiveCompare(openPath) == .orderedSame }?.id
    }

    /// The matches the search shows, which the field may be ahead of.
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

    /// Xcode's Find Selected Symbol in Workspace: the name at the selection's start, defined and used, in the sidebar as a
    /// search's hits. Enabled wherever the caret is, so where no name is it beeps, as Jump to Definition does.
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

    /// Xcode's Quick Help: a popover at `offset` saying what the name there is, or a beep where the core knows nothing of it.
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

    /// Where the caret is, for the places Go Back and Go Forward keep.
    private var caretPlace: Place? { openPath.map { Place(path: $0, line: editsText ? cursorLine : 1) } }

    func canRetrace(back: Bool) -> Bool { openPath != nil && (back ? trail.back : trail.forward).contains(where: exists) }

    private func exists(_ place: Place) -> Bool { root.map { FileManager.default.fileExists(atPath: $0.appending(path: place.path).path) } ?? false }

    /// Go Back, or Go Forward: shown as a jump is, but leaving no place behind.
    func retrace(back: Bool) async {
        guard let at = caretPlace, let to = trail.step(back: back, from: at, exists: exists) else { return }
        await open(to.path, line: to.line)
    }

    /// A refusal is the core's sentence, for the sheet to show.
    func renameSymbol(_ symbol: Definition, to name: String) async throws {
        guard let session else { return }
        try await editProject("session_rename_symbol", ["session": session, "kind": symbol.kind, "from": symbol.name, "to": name],
                              named: String(localized: "Rename"))
    }

    /// As Pages' Save a Version: a name for the project as it is, which the history keeps however old it gets.
    func saveVersion(named name: String) async throws {
        guard let session else { return }
        let saved = try await core.call("session_history_save", ["session": session, "name": name], as: Snapshot.self)
        notices.note(String(localized: "Saved Version “\(saved.title)”"))
    }

    /// The snapshot's `paths`, or all its files, after the core keeps the project as it is in a snapshot of its own. A refusal
    /// is the core's sentence, for the history sheet to show.
    func restoreVersion(_ snapshot: Snapshot, paths: [String]?) async throws {
        guard let session else { return }
        apply(try await core.call("session_history_restore", ["session": session, "id": snapshot.id, "paths": paths], as: Edited.self).edits,
              named: String(localized: "Restore"))
    }

    /// The core writes the other files, with no undo; the open document's edits are one undo step, as a command's, which the
    /// session saves as any. Edits typed past meanwhile no longer fit: the files written go back as the snapshot before has
    /// them, so the project isn't left half changed.
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

    /// False where they no longer fit: a file shown since has text of its own, as one typed in since does.
    @discardableResult
    private func apply(_ edits: ProjectEdits.Document?, named name: String) -> Bool {
        guard let edits else { return true }
        guard edits.path == editor.path, edits.version == editor.textView.document.version else { return false }
        editor.textView.apply(edits.edits, named: name)
        return true
    }

    /// The session runs it, then a build (docs/core-api.md, Explanations and fixes).
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
        // None: the password dialog was cancelled.
        guard let answer, !closed else { return }
        apply(answer.edits, named: fix.title)
        if let updated = answer.settings { settings = updated }
        await compile()
    }

    // MARK: - Changes on disk


    /// `save`, `revert`, `close`, or `cancel` with the reason it is held, unsaved, until a save asks again.
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

    // MARK: - Closing

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
            // Keep undo and observers until the core confirms that every edit is saved.
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

    // MARK: - Settings

    @ObservationIgnored private var settingsPatches = 0

    /// Shown at once; put back if the session refuses it.
    @discardableResult func patchSettings(_ change: SettingsChange) async -> Bool {
        guard let session, !closed else { return false }
        settingsPatches += 1
        let patch = settingsPatches, before = settings
        if settings != nil { change.apply(&settings!) }
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
        Task { if let path = try? await core.call("pdf_path", ["id": id], as: String.self) { await showBuildPDF(path) } }
    }

    func reveal(_ item: OutlineItem) {
        // Already there: a click chooses the row as it goes down, then taps it.
        guard item.file != openPath || cursorLine != item.line || topLine != item.line else { return }
        Task { await open(item.file, line: item.line, atTop: true, focus: false, jump: true) }
    }
}

/// None: the file dropped opens.

/// `session_replace`'s and `session_rename_symbol`'s.
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
    /// Taken just before; none where the history couldn't be kept.
    var snapshot: String?
}

/// What a restore or a fix answers that the window shows: the open document's edits, and a fix's settings.
private nonisolated struct Edited: Decodable {
    let edits: ProjectEdits.Document?
    let settings: ProjectSettings?
}
