import AppKit
import Observation

/// One open project: its files, the document in the editor, and its builds.
@Observable
final class ProjectModel {
    let id: String
    var settings: ProjectSettings?
    var tree: [TreeNode] = []
    /// The first file and its outline are ready for the workspace to appear.
    private(set) var initialLoadComplete = false
    var openPath: String?
    var outline: [OutlineItem] = []
    /// The main file's `\documentclass`, for the levels Aa offers and how it sets them.
    var documentClass: DocumentClass?
    /// The main file `documentClass` was read from.
    @ObservationIgnored private var classFile: String?
    var counts: (words: Int, lines: Int)?
    var cursorLine = 1
    /// The caret's column (UTF-16, from 0), for the status bar.
    var cursorColumn = 0
    /// The line at the top of the source; unobserved, as it changes on every
    /// line scrolled past.
    @ObservationIgnored var topLine = 1
    /// The heading at the top of the source, which the outline follows.
    private(set) var topHeading: Int?

    var dirty = false
    /// Edits since the build of the PDF on screen started.
    private(set) var pdfOutdated = false
    @ObservationIgnored private var edits = 0
    var compiling = false
    var result: CompileResult?
    /// The PDF the viewer shows; nil until one loads.
    var pdfURL: URL?
    /// The PDF pane shows TeXpresso's live document, not the last build's.
    private(set) var livePDF = false
    var showLogs = false
    /// The PDF view's page, scale and find, for the menus and the window.
    let pdf = PDFController()
    var panelTab: PanelTab = .issues
    /// A separate live window; the saved PDF and its usual build remain available.
    let texpresso: TeXpressoSession
    @ObservationIgnored private var liveRestartTask: Task<Void, Never>?
    @ObservationIgnored private var liveDiskTask: Task<Void, Never>?
    @ObservationIgnored private var liveDiskPaths = Set<String>()
    @ObservationIgnored private var liveIntent = 0

    /// Show issues, including the core's fallback issue for a failed build.
    func showBuildPanel() {
        panelTab = .issues
        showLogs = true
    }

    /// The open file on disk, for the window's document icon.
    var openURL: URL?
    /// The open file's path, while the alert asks whether to keep the edits
    /// here or the change on disk.
    var diskConflict: String?
    /// The open file's path, while the alert asks what becomes of its unsaved
    /// edits now another app has moved or deleted it.
    var missingFile: String?
    /// The text last read or written, to tell another app's change from our save.
    private var diskText: String?
    private var folderWatcher: FolderWatcher?
    private var treeReload: Task<Void, Never>?
    /// The tree's reads, numbered as they start: the latest started, and the latest taken.
    @ObservationIgnored private var treeReads = 0
    @ObservationIgnored private var treeTaken = 0

    var importClash: ImportClash?

    var searchQuery = ""
    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The latest finished search's hits: nil until the first for a query ends,
    /// so its results pane doesn't read No Results while it runs.
    var searchHits: [SearchHit]?

    let editor = SourceEditor()
    private weak var app: AppModel?
    private let core = Core.shared
    private var saveTask: Task<Void, Never>?
    /// Saves, settings, renames, deletions and disk checks finish in order, including their model updates.
    private var lastMutation: Task<Bool, Never>?
    private var analysis: Task<Void, Never>?
    private var symbolsTask: Task<Void, Never>?
    // Each of these is cancelled by the next request of its kind, which then has the editor or viewer.
    private var openTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var pdfLoad: Task<Bool, Never>?
    /// The build asked for while one runs: automatic unless any request wasn't.
    private var compileQueued: Bool?
    /// Stop while the build's save runs, before the core has a build to stop.
    private var stopRequested = false
    /// A build still running when the project closes reports nothing.
    private(set) var closed = false

    /// Long enough to cover a pause between keystrokes.
    private static let autosaveDelay = Duration.milliseconds(700)
    /// Several saves during a typing burst need only one symbols scan.
    private static let symbolsDelay = Duration.milliseconds(150)

    init(id: String, app: AppModel) {
        self.id = id
        self.app = app
        texpresso = TeXpressoSession(id: id) { command, arguments in
            try await Core.shared.call(command, arguments, as: TeXpressoStatus.self)
        }
        texpresso.pdfCall = { arguments in
            try await Core.shared.call("texpresso_pdf", arguments, as: TeXpressoPDF.self)
        }
        texpresso.onFailure = { [weak self] in self?.showTeXpressoLog() }
        texpresso.onOwnershipLost = { [weak self] in self?.cancelTeXpressoWork() }
        texpresso.onPDF = { [weak self] in self?.showLivePDF($0) }
        // The last build's PDF comes back, and automatic builds paused for it resume.
        texpresso.onEnded = { [weak self] in
            guard let self else { return }
            if livePDF { Task { await self.endLivePDF() } }
            if autoCompile { Task { await self.compile(auto: true) } }
        }
    }

    /// Only LaTeX has an outline, counts and the LaTeX tools.
    var isLaTeX: Bool { openPath.map(isLaTeXFile) ?? false }
    /// The levels the main file's class has, how it numbers and sets them.
    var headingStyles: HeadingStyles {
        HeadingStyles(documentClass: documentClass, hasChapters: outline.contains { $0.level == 1 })
    }

    var headingLevel: HeadingLevel {
        outline.first { $0.file == openPath && $0.line == cursorLine }.flatMap { HeadingLevel.atDepth($0.level) } ?? .normalText
    }
    var editsText: Bool { openPath.map(isTextFile) ?? false }
    var hasUnsavedText: Bool { dirty && openPath != nil && editor.path == openPath }
    var hasPDF: Bool { pdfURL != nil }

    var errorCount: Int { result?.errors.count ?? 0 }
    var warningCount: Int { result?.warnings.count ?? 0 }

    /// A PDF from before the project opened may be on screen, but its
    /// build's issues weren't kept.
    var noBuildTitle: String { hasPDF ? "Not Built Since Opening" : "Not Compiled" }
    /// The latest build failed without writing a PDF, so the one shown is an earlier build's.
    var showsLastSuccessfulBuild: Bool { hasPDF && result?.failed == true && result?.pdf == nil }
    var texAvailable: Bool { app?.tex?.available ?? false }
    var autoCompile: Bool { app?.autoCompile ?? false }

    private func report(_ error: Error, _ title: String) {
        app?.alert = AppAlert(title, error)
    }

    /// The tree's entry at a project path.
    func node(at path: String) -> TreeNode? { tree.flattened.first { $0.path == path } }
    var folders: [String] { tree.flattened.filter(\.isDirectory).map(\.path) }

    var saved: SavedWorkspace {
        SavedWorkspace(project: id, file: openPath, line: cursorLine, buildPanel: showLogs, pdfPage: pdf.restorePage ?? pdf.page,
                       pdfZoom: pdf.restoreZoom ?? pdf.zoom)
    }

    // ---------- loading ----------

    /// Opens the main file, or where `saved` left off. Stops if the project
    /// is left meanwhile, so it never writes to the editor after the next one.
    func load(restoring saved: SavedWorkspace? = nil) async {
        editor.onChanged = { [weak self] in self?.edited() }
        editor.onCursor = { [weak self] line, column in
            guard let self else { return }
            // Each set notifies: the outline follows the line alone.
            if cursorLine != line { cursorLine = line }
            cursorColumn = column
        }
        editor.onScroll = { [weak self] line in
            guard let self else { return }
            topLine = line
            // The outline redraws only as a heading reaches the top.
            let heading = Outline.current(outline, file: openPath, line: line)
            if heading != topHeading { topHeading = heading }
        }
        editor.textView.fileDrop = { [weak self] in self?.dropped($0) }
        editor.textView.forwardSync = { [weak self] in
            self?.hasPDF == true && self?.isLaTeX == true ? { Task { await self?.forwardSync() } } : nil
        }
        do {
            settings = try await core.call("get_settings", ["id": id], as: ProjectSettings.self)
            await reloadTree()
            await watchFolder()
            refreshSymbols()
            guard !closed else { return }
            if let saved {
                showLogs = saved.buildPanel
                pdf.restorePage = saved.pdfPage
                pdf.restoreZoom = saved.pdfZoom
            }
            let restored = saved?.file.flatMap { node(at: $0) == nil ? nil : $0 }
            if let file = restored ?? settings?.mainFile { await open(file, line: restored == nil ? nil : saved?.line) }
            // The workspace is installed only after its first outline is ready.
            await analysis?.value
        } catch {
            if !closed { report(error, "Couldn’t Open “\(id)”") }
        }
        guard !closed else { return }
        initialLoadComplete = true
        if await !showPDFOnDisk(), autoCompile { await compile(auto: true) }
    }

    /// `quietly` for a reload another app's change asked for: its failure
    /// isn't the user's to act on, and the next change tries again. A read that started
    /// before the last one taken is dropped: a folder change's read ending after a new
    /// file's would take away the row its name is being typed in.
    func reloadTree(quietly: Bool = false) async {
        treeReads += 1
        let read = treeReads
        do {
            let files = try await core.call("file_tree", ["id": id], as: [TreeNode].self)
            guard read > treeTaken else { return }
            treeTaken = read
            // A save's temporary file can trigger an unchanged tree reload.
            if files != tree, !closed, !Task.isCancelled {
                tree = files
                analyze()
                // TeXpresso's rescan retains virtual files. A fresh session
                // drops overrides for deleted or renamed includes.
                if initialLoadComplete, texpresso.active { restartTeXpresso() }
            }
        } catch {
            if !quietly { report(error, "Couldn’t Read the Project’s Files") }
        }
    }

    private func refreshSymbols(delayed: Bool = false) {
        symbolsTask?.cancel()
        symbolsTask = Task { [weak self] in
            if delayed { try? await Task.sleep(for: Self.symbolsDelay) }
            guard let self, !Task.isCancelled else { return }
            if let symbols = try? await core.call("scan_symbols", ["id": id], as: Symbols.self),
               !Task.isCancelled, !closed {
                editor.textView.symbols = symbols
            }
        }
    }

    /// The main file's PDF on disk, unless a later load replaces this one. A no-op
    /// build's PDF is already shown: reopening every page would lose PDFKit's state.
    /// `replacingLive`, it takes the live document's place, which stays until then.
    @discardableResult private func showPDFOnDisk(reloadIfUnchanged: Bool = true, replacingLive: Bool = false) async -> Bool {
        // A build during live preview keeps its PDF for after it.
        guard !livePDF || replacingLive else { return true }
        pdfLoad?.cancel()
        let load = Task {
            guard !closed, !livePDF || replacingLive, let path = try? await core.call("pdf_path", ["id": id], as: String.self),
                  !Task.isCancelled, !closed else { return false }
            let url = URL(fileURLWithPath: path)
            if !reloadIfUnchanged, url == pdfURL { return true }
            guard let document = await PDFController.loadDocument(url), !Task.isCancelled, !closed else { return false }
            livePDF = false
            pdfURL = url
            pdf.show(document)
            return true
        }
        pdfLoad = load
        return await load.value
    }

    /// Live preview over, the last build's PDF, or the pane's empty state without one: the live
    /// document isn't a build's, to save or sync with. A new live session's document wins.
    private func endLivePDF() async {
        guard !(await showPDFOnDisk(replacingLive: true)), livePDF, !texpresso.active, !closed else { return }
        livePDF = false
        pdfURL = nil
        pdf.clear()
    }

    /// TeXpresso's document in the PDF pane, as a build's replaces the last; the pane shows on
    /// the first, as the preview the person asked for.
    private func showLivePDF(_ url: URL) {
        pdfLoad?.cancel()
        pdfLoad = Task {
            guard let document = await PDFController.loadDocument(url), !Task.isCancelled, !closed, texpresso.active else { return false }
            if !livePDF, app?.showPDF == false { app?.showPDF = true }
            livePDF = true
            pdfURL = url
            pdf.show(document)
            return true
        }
    }

    // ---------- editing ----------

    /// Text opens in the editor, anything else in a preview. The sidebar
    /// passes `focus: false` so the arrow keys stay in its list. Only the latest
    /// open carries on, so the editor can't show one file while `openPath`,
    /// where autosave writes, names another.
    func open(_ path: String, line: Int? = nil, column: Int? = nil, atTop: Bool = false, focus: Bool = true) async {
        openTask?.cancel()
        let task = Task {
            if path != openPath {
                texpresso.flushEdits()
                guard await saveEdits(), !Task.isCancelled, !closed else { return }
                do {
                    let text = isTextFile(path) ? try await core.call("read_file", ["id": id, "path": path], as: FileText.self).text : nil
                    guard !Task.isCancelled, !closed else { return }
                    openPath = path
                    openURL = url(path)
                    diskText = text
                    analyze()
                    if let text {
                        editor.open(path: path, text: text, focus: focus)
                        cursorLine = editor.currentLine
                    }
                } catch {
                    if !Task.isCancelled, !closed { report(error, "Couldn’t Open “\(path.fileName)”") }
                    return
                }
            }
            if let line, editsText, !Task.isCancelled, !closed { editor.reveal(line: line, column: column, atTop: atTop, focus: focus) }
        }
        openTask = task
        await task.value
    }

    /// A file of the project on disk, to drag out; nil until its folder is watched.
    func url(_ path: String) -> URL? {
        folderWatcher.map { URL(filePath: $0.folder).appending(path: path) }
    }

    /// A dragged file's path in the project; nil for one from elsewhere.
    func projectPath(_ url: URL) -> String? {
        folderWatcher?.relativePath(FolderWatcher.realPath(url))
    }

    /// A file of the project dropped on the source opens in the editor; one from elsewhere goes on the sidebar.
    private func dropped(_ url: URL) -> (() -> Void)? {
        guard let path = projectPath(url), node(at: path)?.isDirectory == false else { return nil }
        return { [weak self] in Task { await self?.open(path) } }
    }

    func showInFinder(_ path: String) {
        if let url = self.url(path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func edited() {
        dirty = true
        edits += 1
        if texpresso.active, let document = editor.document {
            texpresso.update(TeXpressoFile(path: document.path, text: document.text))
        }
        if hasPDF, !pdfOutdated { pdfOutdated = true }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            let saved = await self.save()
            guard saved, !Task.isCancelled else { return }
            if self.autoCompile { await self.compile(auto: true) }
        }
    }

    /// Queued after earlier mutations; true means the text reached disk.
    @discardableResult
    func save() async -> Bool {
        await mutate { await $0.write() }
    }

    private func write() async -> Bool {
        guard hasUnsavedText, let document = editor.document else { return true }
        // Not over another app's change until asked which to keep.
        guard diskConflict == nil, missingFile == nil else { return false }
        // The editor's text, which is the open file's: they change together.
        let (path, text) = document
        // An edit during the write marks it dirty again, and its own save follows.
        dirty = false
        let previous = diskText
        do {
            // Before the write, so its own change event matches.
            diskText = text
            try await core.perform("write_file", ["id": id, "path": path, "text": text])
            analyze()
            refreshSymbols(delayed: true)
            return true
        } catch {
            // The disk still has what it had, so a later change event isn't taken for another app's.
            if diskText == text { diskText = previous }
            dirty = true
            report(error, "“\(path.fileName)” Wasn’t Saved")
            return false
        }
    }

    /// The project's outline and words and the open file's lines, for a .tex file
    /// only. The core reads the saved files; the latest reading wins.
    private func analyze() {
        analysis?.cancel()
        guard isLaTeX, let path = openPath else {
            outline = []
            counts = nil
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
            counts = (doc.words, doc.lines)
            // The class changes with the main file only.
            guard let main = settings?.mainFile, main == path || main != classFile,
                  let text = main == path ? editor.document?.text
                    : try? await core.call("read_file", ["id": id, "path": main], as: FileText.self).text,
                  !Task.isCancelled else { return }
            documentClass = DocumentClass(in: text)
            classFile = main
        }
    }

    /// Saves before a file switch, close or quit; cancels pending autosave.
    func flush() async -> Bool {
        saveTask?.cancel()
        // Repeat if an edit arrives during the write.
        repeat {
            guard await save() else { return false }
        } while hasUnsavedText
        return true
    }

    /// Restores the automatic build canceled with the pending autosave.
    @discardableResult
    func saveEdits() async -> Bool {
        let edited = dirty
        guard await flush() else { return false }
        if edited, autoCompile { Task { await compile(auto: true) } }
        return true
    }

    // ---------- changes on disk ----------

    /// Watch external edits and file-tree changes rather than saving over them.
    private func watchFolder() async {
        guard let root = try? await core.call("project_root", ["id": id], as: String.self), !closed else { return }
        folderWatcher = FolderWatcher(folder: URL(fileURLWithPath: root)) { [weak self] in self?.folderChanged($0) }
    }

    /// The tree is read again when something comes, goes or moves in a folder
    /// it shows; what it shows (not hidden files or the build's) is the core's.
    private func folderChanged(_ changes: [FolderWatcher.Change]) {
        guard let watcher = folderWatcher else { return }
        let folders = Set(self.folders)
        var openFileChanged = false, treeChanged = false
        for change in changes {
            guard let path = watcher.relativePath(change.path) else {
                // The folder itself: moved, or FSEvents lost count of it, so the
                // open file may have changed unseen too.
                let folder = change.path == watcher.folder || change.path == watcher.folder + "/"
                treeChanged = treeChanged || change.structural && folder
                openFileChanged = openFileChanged || change.structural && folder && openPath != nil
                continue
            }
            // A folder moves as one change, not one for each file in it.
            openFileChanged = openFileChanged || path == openPath
                || change.structural && openPath?.hasPrefix(path + "/") == true
            let parent = path.parentFolder
            treeChanged = treeChanged || change.structural && (parent.isEmpty || folders.contains(parent))
            if texpresso.active, node(at: path) != nil { liveDiskPaths.insert(path) }
        }
        if openFileChanged {
            // In the mutation lane, so our own rename or write is never read as another app's change.
            Task { [weak self] in
                guard let self, await mutate(nil, { await $0.checkDisk() }), autoCompile else { return }
                await compile(auto: true)
            }
        }
        // A newer reload replaces one that hasn't started.
        if treeChanged {
            treeReload?.cancel()
            treeReload = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.reloadTree(quietly: true)
            }
        }
        if texpresso.active, !liveDiskPaths.isEmpty { refreshTeXpressoDisk() }
    }

    /// With no unsaved edits the editor takes the disk's text, and true says so; otherwise ask.
    private func checkDisk() async -> Bool {
        guard let path = openPath else { return false }
        if let url = openURL, !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            fileGone(path)
            return false
        }
        guard editsText, let file = try? await core.call("read_file", ["id": id, "path": path], as: FileText.self),
              path == openPath, !closed, file.text != diskText else { return false }
        diskText = file.text
        guard !dirty else {
            saveTask?.cancel()
            diskConflict = path
            return false
        }
        showDiskText(file.text, of: path)
        return true
    }

    /// Another app moved or deleted the open file. It closes, as the sidebar
    /// drops it, unless it has unsaved edits: those are asked about, and not
    /// saved meanwhile, which would put the file back unasked.
    private func fileGone(_ path: String) {
        saveTask?.cancel()
        if hasUnsavedText {
            missingFile = path
        } else {
            clearOpenFile()
        }
    }

    /// The edits saved where the file was, making it again.
    func saveMissingFile() {
        missingFile = nil
        Task { await saveEdits() }
    }

    /// Discards unsaved edits to a file that no longer exists.
    func closeMissingFile() {
        missingFile = nil
        clearOpenFile()
    }

    private func showDiskText(_ text: String, of path: String) {
        let top = topLine
        editor.open(path: path, text: text, focus: false)
        analyze()
        editor.reveal(line: top, atTop: true, focus: false)
        cursorLine = editor.currentLine
        texpresso.update(TeXpressoFile(path: path, text: text))
    }

    /// The disk's text of `path`, the file the alert asked about, written back in case
    /// a save under way when the change came wrote the edits over it.
    func revertToDisk(_ path: String) async {
        diskConflict = nil
        saveTask?.cancel()
        let reverted = await mutate { model in
            guard model.openPath == path, let text = model.diskText else { return false }
            model.showDiskText(text, of: path)
            model.dirty = true
            return await model.write()
        }
        if reverted, autoCompile { await compile(auto: true) }
    }

    /// The next save writes these edits over the other app's.
    func keepEdits() {
        diskConflict = nil
        // The autosave was cancelled while asking, or the edits were already saved
        // before the other app's change: either way they're written again.
        dirty = true
        Task { await saveEdits() }
    }

    // ---------- compile ----------

    /// A request during a build queues one follow-up. Automatic failures open
    /// issues when the new build has no PDF; clean builds close empty issues.
    /// Automatic ones wait while TeXpresso previews, without changing the preference.
    func compile(auto: Bool = false) async {
        guard texAvailable, !closed, !auto || !livePreviewing else { return }
        if compiling {
            compileQueued = (compileQueued ?? true) && auto
            return
        }
        // Before the save, so a second request queues instead of racing this one.
        compiling = true
        stopRequested = false
        // Through the mutation lane, after the settings and renames asked for before.
        let built = edits
        let saved = await flush()
        if saved, !stopRequested, !closed, !auto || !livePreviewing {
            do {
                let result = try await core.call("compile", ["id": id], as: CompileResult.self)
                // The PDF is the main file's now: a main-file change stopped any build of the old one.
                if result.pdf != nil, !closed {
                    await showPDFOnDisk(reloadIfUnchanged: result.pdfChanged)
                    // Edits made while it built aren't in it.
                    pdfOutdated = edits != built
                }
                if !closed {
                    self.result = result
                    if result.failed, !auto || result.pdf == nil { showBuildPanel() }
                    if result.ok, panelTab == .issues, result.errors.isEmpty, result.warnings.isEmpty { showLogs = false }
                }
            } catch {
                if !auto, !closed { report(error, "Couldn’t Compile") }
            }
        }
        compiling = false
        // After a failed save the queued build would only build stale text.
        let again = saved && !closed ? compileQueued : nil
        compileQueued = nil
        if let again { await compile(auto: again) }
    }

    /// A build still running stops and reports nothing, so it can't supersede the next project's.
    func close() {
        guard !closed else { return }
        stopCompile()
        closed = true
        // The old workspace can remain visible while a live start drains.
        editor.textView.isEditable = false
        liveIntent += 1
        liveRestartTask?.cancel()
        liveDiskTask?.cancel()
        texpresso.close()
        // Its renames can't be undone once it's closed; the window's stack outlives it.
        app?.undoManager?.removeAllActions(withTarget: self)
        compileQueued = nil
        folderWatcher = nil
        saveTask?.cancel()
        analysis?.cancel()
        symbolsTask?.cancel()
        treeReload?.cancel()
        openTask?.cancel()
        syncTask?.cancel()
        pdfLoad?.cancel()
    }

    /// Kills the build's process group; the compile returns stopped.
    func stopCompile() {
        guard compiling else { return }
        compileQueued = nil
        stopRequested = true
        Task { try? await core.perform("stop_compile", ["id": id]) }
    }

    // ---------- settings ----------

    private func mutate(_ title: String? = nil, _ update: @escaping @MainActor (ProjectModel) async throws -> Bool) async -> Bool {
        let previous = lastMutation
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self, !closed else { return false }
            do {
                return try await update(self)
            } catch {
                if !closed, let title { report(error, title) }
                return false
            }
        }
        lastMutation = task
        return await task.value
    }

    @discardableResult
    func patchSettings(_ patch: [String: Any]) async -> Bool {
        await mutate("Couldn’t Change the Project’s Settings") { model in
            let updated = try await model.core.call("set_settings", ["id": model.id, "patch": patch], as: ProjectSettings.self)
            guard !model.closed else { return false }
            model.settings = updated
            return true
        }
    }

    func setEngine(_ engine: String) async {
        if await patchSettings(["engine": engine]) { await compile() }
    }

    func setMainFile(_ path: String) async {
        if await keepingLive({ await patchSettings(["mainFile": path]) }), !closed { await mainFileChanged() }
    }

    // ---------- TeXpresso live preview ----------

    private var livePreviewing: Bool { texpresso.active || liveRestartTask != nil }

    /// The core ends a live session when a rename or a new main file changes what it previews.
    /// One live before `change` starts again after it, unless stopped or started meanwhile.
    @discardableResult
    private func keepingLive(_ change: () async -> Bool) async -> Bool {
        let live = texpresso.active ? liveIntent : nil
        let changed = await change()
        if changed, live == liveIntent, !closed { restartTeXpresso() }
        return changed
    }

    private var liveFiles: [TeXpressoFile] {
        guard editsText, let document = editor.document, document.path == openPath else { return [] }
        return [TeXpressoFile(path: document.path, text: document.text)]
    }

    func startTeXpresso() {
        guard !closed, texpresso.canStart else { return }
        liveIntent += 1
        // The preview is the feedback; the log opens only on a failure.
        texpresso.start(files: liveFiles)
    }

    func stopTeXpresso() {
        cancelTeXpressoWork()
        texpresso.stop()
    }

    private func cancelTeXpressoWork() {
        liveIntent += 1
        liveRestartTask?.cancel()
        liveRestartTask = nil
        liveDiskTask?.cancel()
        liveDiskPaths.removeAll()
    }

    func showTeXpressoLog() {
        panelTab = .texpresso
        showLogs = true
    }

    func rescanTeXpresso() { texpresso.rescan(files: liveFiles) }

    private func restartTeXpresso() {
        liveRestartTask?.cancel()
        liveRestartTask = Task { [weak self] in
            // Coalesce a rename's tree and main-file notifications.
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !closed, !Task.isCancelled else { return }
            texpresso.restart(files: liveFiles)
            liveRestartTask = nil
        }
    }

    /// Another app's change to an include the editor sent replaces TeXpresso's copy; the open
    /// file's is the editor's, even while it asks about the change. A path whose read fails waits
    /// for the next change.
    private func refreshTeXpressoDisk() {
        liveDiskTask?.cancel()
        liveDiskTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self else { return }
            // Our own save of the open file isn't news to TeXpresso, which has the editor's text:
            // a rescan then, landing as it typesets the edit, stalled it (TeXpresso e8df770).
            var others = false
            for path in liveDiskPaths {
                guard !closed, !Task.isCancelled, texpresso.active else { return }
                if path != openPath { others = true }
                if path != openPath, isTextFile(path) {
                    guard let file = try? await core.call("read_file", ["id": id, "path": path], as: FileText.self) else { continue }
                    guard !Task.isCancelled, path != openPath else { continue }
                    texpresso.update(TeXpressoFile(path: path, text: file.text))
                }
                liveDiskPaths.remove(path)
            }
            guard others, !closed, !Task.isCancelled else { return }
            rescanTeXpresso()
        }
    }

    // ---------- SyncTeX ----------

    /// Each sync replaces the one before; the PDF pane shows the spot once it has its width.
    func forwardSync() async {
        guard let path = openPath else { return }
        let (line, column, word) = (editor.currentLine, editor.currentColumn, editor.currentSyncWord)
        let live = livePDF, args = syncArguments(["id": id, "file": path, "line": line, "column": column])
        syncTask?.cancel()
        let task = Task {
            guard await saveEdits(), !Task.isCancelled, !closed, openPath == path else { return }
            // Only on the pages it was found in: a rebuild may have moved it.
            let shown = pdf.shownVersion
            do {
                let loc = try await core.call("synctex_forward", args, as: ForwardLoc.self)
                guard !Task.isCancelled, !closed, openPath == path, pdf.shownVersion == shown, livePDF == live else { return }
                app?.requestPDF(.reveal(loc, word))
            } catch {
                if !Task.isCancelled, !closed { report(error, "Couldn’t Find This Line in the PDF") }
            }
        }
        syncTask = task
        await task.value
    }

    /// SyncTeX for the pages shown: TeXpresso's, through its session, or the last build's.
    private func syncArguments(_ arguments: [String: Any]) -> [String: Any] {
        guard livePDF, let session = texpresso.session else { return arguments }
        return arguments.merging(["live": true, "session": session]) { $1 }
    }

    /// `word`, the PDF's word clicked `offset` in, takes the caret to it on the line.
    func inverseSync(page: Int, x: Double, y: Double, word: SyncTeXWord? = nil) async {
        syncTask?.cancel()
        let task = Task {
            do {
                // A nil word bridges as null, which the core reads as none.
                let args = syncArguments(["id": id, "page": page, "x": x, "y": y, "word": word?.text as Any, "offset": word?.offset as Any,
                                          "context": word?.context as Any, "contextOffset": word?.contextOffset as Any])
                let loc = try await core.call("synctex_inverse", args, as: InverseLoc.self)
                guard !Task.isCancelled, !closed else { return }
                await open(loc.file, line: loc.line, column: loc.column)
            } catch {
                if !Task.isCancelled, !closed { report(error, "Couldn’t Find This Spot in the Source") }
            }
        }
        syncTask = task
        await task.value
    }

    // ---------- files ----------

    /// "untitled.tex", or "untitled folder", in `folder`, numbered past the names taken
    /// there as Finder numbers them; its path once made. In the lane, after the renames and
    /// deletions asked for before it. A file opens, leaving the keyboard for its name.
    func createEntry(in folder: String, directory: Bool) async -> String? {
        let name = directory ? "untitled folder" : "untitled.tex"
        var made: String?
        _ = await mutate("Couldn’t Create “\(name)”") { model in
            for number in 1... {
                let free = number == 1 ? name : name.numbered(number)
                let path = folder.isEmpty ? free : "\(folder)/\(free)"
                do {
                    try await model.core.perform("create_entry", ["id": model.id, "path": path, "dir": directory])
                    made = path
                    return true
                } catch let error as CoreError where error.status == 409 {
                    continue
                }
            }
            return false
        }
        guard let made, !closed else { return nil }
        await reloadTree()
        if !directory { await open(made, focus: false) }
        return made
    }

    /// `action` names it in Edit › Undo: a drop in the tree is a Move.
    func renameEntry(_ from: String, to: String, action: String = String(localized: "Rename")) async {
        if let result = await performRename(from, to: to) { registerRenameUndo(result, action: action) }
    }

    /// Undo renames it back, by the core's normalised paths; the main file follows it both
    /// ways. The Redo is registered as the Undo starts, as `UndoableTrash`'s are, and one
    /// that fails takes it away. The closures hold the model: the manager doesn't.
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

    private func performRename(_ from: String, to: String) async -> RenameResult? {
        guard to != from, await saveEdits() else { return nil }
        var reopen: String?
        var mainChanged = false
        var renamed: RenameResult?
        // Restarted once the editor and tree have the new names.
        await keepingLive {
            let renaming = await mutate("Couldn’t Rename “\(from.fileName)”") { model in
                let result = try await model.core.call("rename_entry", ["id": model.id, "from": from, "to": to], as: RenameResult.self)
                guard !model.closed else { return false }
                renamed = result
                model.editor.rename(from: result.from, to: result.to)
                // The open file may move with its folder. The editor keeps its
                // text; only the save path changes, so the old path can't return.
                if let was = model.openPath, case let now = remapPath(was, from: result.from, to: result.to), now != was {
                    model.openPath = now
                    model.openURL = model.url(now)
                    // Its new kind may edit or preview it differently.
                    if isTextFile(now) != isTextFile(was) || isLaTeXFile(now) != isLaTeXFile(was) { reopen = now }
                }
                mainChanged = result.mainFile != model.settings?.mainFile
                model.settings = model.settings.map {
                    ProjectSettings(mainFile: result.mainFile, engine: $0.engine,
                                    shellEscape: $0.shellEscape, stopOnFirstError: $0.stopOnFirstError)
                }
                return true
            }
            // Opening flushes edits, so it must run after this mutation releases the queue.
            guard !closed else { return false }
            if let reopen, openPath == reopen, await flush(), !closed, openPath == reopen {
                clearOpenFile()
                await open(reopen, focus: false)
            }
            await reloadTree()
            return renaming
        }
        guard !closed else { return nil }
        if mainChanged { await mainFileChanged() }
        return renamed
    }

    /// Move to Trash, which Edit › Undo takes back.
    func deleteEntry(_ path: String) async {
        guard let original = url(path) else { return }
        let item = UndoableTrash(
            original: original, name: path.fileName, undoManager: app?.undoManager,
            trash: { [weak self] item in await self?.trashEntry(path, item) ?? false },
            changed: { [weak self] in await self?.reloadTree() },
            failed: { [weak self] title, error in self?.report(error, title) })
        await item.moveToTrash()
        if !closed { await reloadTree() }
    }

    /// In the lane, so it follows the saves and renames asked for before it.
    private func trashEntry(_ path: String, _ item: UndoableTrash) async -> Bool {
        await mutate("Couldn’t Move “\(path.fileName)” to the Trash") { model in
            // Saved first, so an autosave cannot recreate the deleted file.
            repeat {
                guard await model.write() else { return false }
                // Recheck after saving: another editor may have changed the main file (#37).
                let settings = try await model.core.call("get_settings", ["id": model.id], as: ProjectSettings.self)
                guard !model.closed else { return false }
                model.settings = settings
                if settings.mainFile == path || settings.mainFile.hasPrefix(path + "/") {
                    throw CoreError(message: "Choose a different main file before moving this to the Trash.", status: 409)
                }
                // Typing during the settings read must reach disk before the editor is cleared.
            } while model.hasUnsavedText
            try item.recycle()
            guard !model.closed else { return false }
            model.editor.forget(path: path)
            if let open = model.openPath, open == path || open.hasPrefix(path + "/") { model.clearOpenFile() }
            return true
        }
    }

    /// No file editing: the editor may still hold the old text, but nothing saves or analyses it.
    private func clearOpenFile() {
        analysis?.cancel()
        openPath = nil
        openURL = nil
        diskText = nil
        dirty = false
        outline = []
        counts = nil
    }

    /// The new main file's PDF, if it has one, replaces the old one's; a build of
    /// the old one stops (the core reports it stopped) and a build of the new one follows.
    private func mainFileChanged() async {
        analyze()
        stopCompile()
        if texpresso.active { restartTeXpresso() }
        await showPDFOnDisk()
        if !closed { await compile(auto: true) }
    }

    /// Files dropped on the tree: the project's own move into `dir`, as in Finder,
    /// and files from elsewhere are copied in.
    func dropFiles(_ urls: [URL], into dir: String) async {
        var outside: [URL] = []
        for url in urls {
            guard let path = projectPath(url) else { outside.append(url); continue }
            // Not into the folder it's in, nor a folder into itself.
            guard path.parentFolder != dir, dir != path, !dir.hasPrefix(path + "/") else { continue }
            await renameEntry(path, to: dir.isEmpty ? path.fileName : "\(dir)/\(path.fileName)",
                               action: String(localized: "Move"))
        }
        if !outside.isEmpty { await importFiles(outside, into: dir) }
    }

    /// Taken names are asked about first (`importClash`), then copied again
    /// with the answer: "replace" (old ones to the Trash) or "keepBoth".
    func importFiles(_ urls: [URL], into dir: String = "", conflict: String? = nil) async {
        var args: [String: Any] = ["id": id, "dir": dir, "paths": urls.map(\.path)]
        args["conflict"] = conflict
        do {
            let clashes = try await core.call("import_files", args, as: Imported.self).existing.map(\.path)
            if conflict == nil, !clashes.isEmpty { importClash = ImportClash(urls: urls, dir: dir, names: clashes) }
        } catch {
            report(error, "Couldn’t Add the Files")
        }
        // After a failure too: the files copied before it are there.
        await reloadTree()
    }

    // ---------- export ----------

    /// In a temporary folder; the save panel copies it where it goes. The core archives the
    /// files on disk, so the open file's edits are saved first: an archive without them would
    /// be a stale copy reported as a good one.
    func exportZip() async throws -> URL {
        guard await saveEdits() else {
            let name = openPath?.fileName ?? id
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedFailureReasonErrorKey: String(localized: "“\(name)” couldn’t be saved, so the archive would be missing its changes."),
            ])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("\(id).zip")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await core.perform("export_zip", ["id": id, "dest": url.path])
        return url
    }

    // ---------- search ----------

    /// Hits for the current query, unless the calling task is cancelled by a newer one.
    func search() async {
        guard isSearching else {
            searchHits = nil
            return
        }
        let hits = (try? await core.call("search_project", ["id": id, "query": searchQuery], as: [SearchHit].self)) ?? []
        if !Task.isCancelled { searchHits = hits }
    }

    // ---------- editor commands ----------

    /// An outline heading at the top of the source, in its file; the keyboard stays where it is.
    func reveal(_ item: OutlineItem) {
        // Already there: a click chooses the row as it goes down, then taps it.
        guard item.file != openPath || cursorLine != item.line || topLine != item.line else { return }
        Task { await open(item.file, line: item.line, atTop: true, focus: false) }
    }
}

/// Where a project was left, in the window's restorable state (`MainWindowController`).
/// Pane visibility and sizes are in the defaults instead.
nonisolated struct SavedWorkspace: Codable, Equatable {
    var project: String
    var file: String?
    var line: Int
    var buildPanel: Bool
    var pdfPage: Int
    /// Nil in what an earlier version saved.
    var pdfZoom: PDFController.Zoom?
}

/// An import whose names are already taken where it goes.
struct ImportClash {
    let urls: [URL]
    let dir: String
    /// Project paths.
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
