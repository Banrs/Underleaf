import AppKit
import Observation
import PDFKit
import UserNotifications

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
    var counts: (words: Int, lines: Int)?
    var cursorLine = 1
    /// The line at the top of the source; unobserved, as it changes on every
    /// line scrolled past.
    @ObservationIgnored var topLine = 1
    /// The heading at the top of the source, which the outline follows.
    private(set) var topHeading: Int?

    var dirty = false
    var saving = false
    var compiling = false
    var result: CompileResult?
    /// Bumped when the viewer loads a PDF, so its panes update.
    var pdfVersion = 0
    var pdfURL: URL?
    private(set) var pdfDocument: PDFDocument?
    private var pdfStamp: PDFStamp?
    var pdfFreshness: PDFFreshness?
    /// The token lets the same spot be flashed twice.
    var highlight: (loc: ForwardLoc, word: SyncTeXWord?, token: Int)?
    var showLogs = false
    /// The PDF view's page, scale and find, for the menus and the window.
    let pdf = PDFController()
    var panelTab: PanelTab = .issues

    /// Show issues, including the core's fallback issue for a failed build.
    func showBuildPanel() {
        panelTab = .issues
        showLogs = true
    }

    /// Shared across projects and launches.
    var showPDF = UserDefaults.standard.bool(forKey: DefaultsKey.showPDF) {
        didSet { UserDefaults.standard.set(showPDF, forKey: DefaultsKey.showPDF) }
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
    private var diskCheck: Task<Void, Never>?

    var findShown = false
    var findQuery = FindQuery() {
        didSet {
            if findQuery != oldValue { editor.setFind(findQuery) }
        }
    }
    var findMatches = FindMatches()
    /// Bumped to focus the find or replace field; both reset as the bar
    /// closes, so the next bar doesn't take a stale focus request.
    var findFocus = 0
    var replaceFocus = 0
    /// The replace row: Find and Replace… adds it until the bar closes, so a plain
    /// Find keeps the bar to one row.
    var replaceShown = false

    var importClash: ImportClash?

    var searchQuery = "" { didSet { scheduleSearch() } }
    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The latest finished search's hits: nil until the first for a query ends,
    /// so its results pane doesn't read No Results while it runs.
    var searchHits: [SearchHit]?

    let editor = SourceEditor()
    private weak var app: AppModel?
    private let core = Core.shared
    private var saveTask: Task<Void, Never>?
    /// Saves, settings, renames and deletions finish in order, including their model updates.
    private var lastMutation: Task<Bool, Never>?
    private var searchTask: Task<Void, Never>?
    private var analysis: Task<Void, Never>?
    private var symbolsTask: Task<Void, Never>?
    @ObservationIgnored private var syncGeneration = 0
    /// Bumped by each `open`, so an earlier one still in flight stands down.
    private var openGeneration = 0
    /// Changes to the main file invalidate a build that started for its old PDF.
    private var mainFileGeneration = 0
    private var pdfLoadGeneration = 0
    /// The build asked for while one runs: automatic unless any request wasn't.
    private var compileQueued: Bool?
    /// Stop while the build's save runs, before the core has a build to stop.
    private var stopRequested = false
    /// A build still running when the project closes reports nothing.
    private var closed = false
    /// Writes that reached the disk while a build may still be running.
    private var writes = 0

    /// Long enough to cover a pause between keystrokes.
    private static let autosaveDelay = Duration.milliseconds(700)
    /// Each search reads every file in the project; wait for typing to pause.
    private static let searchDelay = Duration.milliseconds(200)
    /// Several saves during a typing burst need only one symbols scan.
    private static let symbolsDelay = Duration.milliseconds(150)

    private struct PDFStamp: Equatable {
        let modified: Date
        let bytes: UInt64
        let fileNumber: UInt64

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
                  let modified = attributes[.modificationDate] as? Date,
                  let bytes = attributes[.size] as? NSNumber,
                  let fileNumber = attributes[.systemFileNumber] as? NSNumber else { return nil }
            self.modified = modified
            self.bytes = bytes.uint64Value
            self.fileNumber = fileNumber.uint64Value
        }
    }

    init(id: String, app: AppModel) {
        self.id = id
        self.app = app
    }

    /// Only LaTeX has an outline, counts and the LaTeX tools.
    var isLaTeX: Bool { openPath.map(isLaTeXFile) ?? false }
    var headingLevel: HeadingLevel {
        outline.first { $0.file == openPath && $0.line == cursorLine }.flatMap { HeadingLevel.atDepth($0.level) } ?? .normalText
    }
    var editsText: Bool { openPath.map(isTextFile) ?? false }
    var hasUnsavedText: Bool { dirty && openPath != nil && editor.path == openPath }
    var hasPDF: Bool { pdfVersion > 0 }

    var errorCount: Int { result?.errors.count ?? 0 }
    var warningCount: Int { result?.warnings.count ?? 0 }

    /// A PDF from before the project opened may be on screen, but its
    /// build's issues weren't kept.
    var noBuildTitle: String { pdfVersion > 0 ? "Not Built Since Opening" : "Not Compiled" }
    var texAvailable: Bool { app?.tex?.available ?? false }
    var autoCompile: Bool { app?.autoCompile ?? false }

    private func report(_ error: Error, _ title: String) {
        app?.alert = AppAlert(title, error)
    }

    private func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    var saved: SavedWorkspace {
        SavedWorkspace(project: id, file: openPath, line: cursorLine, buildPanel: showLogs, pdfPage: pdf.restorePage ?? pdf.page)
    }

    // ---------- loading ----------

    /// Opens the main file, or where `saved` left off. Stops if the project
    /// is left meanwhile, so it never writes to the editor after the next one.
    func load(restoring saved: SavedWorkspace? = nil) async {
        editor.onChanged = { [weak self] in self?.edited() }
        editor.onCursor = { [weak self] line in self?.cursorLine = line }
        editor.onScroll = { [weak self] line in
            guard let self else { return }
            topLine = line
            // The outline redraws only as a heading reaches the top.
            let heading = Outline.current(outline, file: openPath, line: line)
            if heading != topHeading { topHeading = heading }
        }
        editor.onFindMatches = { [weak self] matches in self?.findMatches = matches }
        // Escape in the text closes the find bar first.
        editor.textView.escape = { [weak self] in
            guard let self, findShown else { return false }
            closeFind()
            return true
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
            }
            let restored = saved?.file.flatMap { file in tree.flattened.contains { $0.path == file } ? file : nil }
            if let file = restored ?? settings?.mainFile { await open(file, line: restored == nil ? nil : saved?.line) }
            // The workspace is installed only after its first outline is ready.
            // A file watcher can replace an analysis while we wait.
            repeat {
                let pending = analysis
                await pending?.value
                if pending == analysis { break }
            } while !closed
        } catch {
            if !closed { report(error, "Couldn’t Open “\(id)”") }
        }
        guard !closed else { return }
        initialLoadComplete = true
        if await !showPDFOnDisk(), autoCompile { await compile(auto: true) }
    }

    /// `quietly` for a reload another app's change asked for: its failure
    /// isn't the user's to act on, and the next change tries again.
    func reloadTree(quietly: Bool = false) async {
        do {
            let files = try await core.call("file_tree", ["id": id], as: [TreeNode].self)
            // A save's temporary file can trigger an unchanged tree reload.
            if files != tree, !closed, !Task.isCancelled {
                tree = files
                analyze()
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

    @discardableResult private func showPDFOnDisk(reloadIfUnchanged: Bool = true) async -> Bool {
        pdfLoadGeneration += 1
        let generation = mainFileGeneration, load = pdfLoadGeneration
        guard !closed else { return false }
        guard let path = try? await core.call("pdf_path", ["id": id], as: String.self) else { return false }
        guard !closed, generation == mainFileGeneration, load == pdfLoadGeneration else { return false }
        let url = URL(fileURLWithPath: path)
        // The PDF already loaded was validated when it was first shown.
        // A no-op build need not reopen every page to keep that document.
        let stamp = PDFStamp(url)
        if !reloadIfUnchanged, url == pdfURL, let stamp, stamp == pdfStamp { return true }
        guard let document = await PDFController.loadDocument(url) else { return false }
        guard !closed, generation == mainFileGeneration, load == pdfLoadGeneration else { return false }
        pdfURL = url
        pdfDocument = document
        pdf.show(document)
        pdfStamp = stamp
        pdfVersion += 1
        return true
    }

    private func fileURL(_ path: String) async -> URL? {
        (try? await core.call("raw_path", ["id": id, "path": path], as: String.self)).map(URL.init(fileURLWithPath:))
    }

    // ---------- editing ----------

    /// Text opens in the editor, anything else in a preview. The sidebar
    /// passes `focus: false` so the arrow keys stay in its list.
    func open(_ path: String, line: Int? = nil, column: Int? = nil, atTop: Bool = false, focus: Bool = true,
              stillCurrent: (@MainActor () -> Bool)? = nil) async {
        guard stillCurrent?() != false else { return }
        // Only the latest open carries on, so the editor can't show one file
        // while `openPath`, where autosave writes, names another. Checked
        // after the last await before the editor.
        openGeneration += 1
        let generation = openGeneration
        if path != openPath {
            guard await saveEdits(), generation == openGeneration, stillCurrent?() != false else { return }
            do {
                let text = isTextFile(path) ? try await core.call("read_file", ["id": id, "path": path], as: FileText.self).text : nil
                let url = await fileURL(path)
                guard generation == openGeneration, !closed, stillCurrent?() != false else { return }
                openPath = path
                openURL = url
                diskText = text
                analyze()
                if let text {
                    editor.open(path: path, text: text, focus: focus)
                    cursorLine = editor.currentLine
                }
            } catch {
                if !closed, stillCurrent?() != false { report(error, "Couldn’t Open “\(name(path))”") }
                return
            }
        }
        if let line, editsText, generation == openGeneration, !closed { editor.reveal(line: line, column: column, atTop: atTop, focus: focus) }
    }

    /// A file of the project on disk, to drag out; nil until its folder is watched.
    func url(_ path: String) -> URL? {
        folderWatcher.map { URL(filePath: $0.folder).appending(path: path) }
    }

    /// A dragged file's path in the project; nil for one from elsewhere.
    func projectPath(_ url: URL) -> String? {
        folderWatcher?.relativePath(FolderWatcher.realPath(url))
    }

    /// A file dropped on the source: the project's own opens in the editor, and a
    /// project from elsewhere opens as it would from the Dock.
    private func dropped(_ url: URL) -> (() -> Void)? {
        if let path = projectPath(url) {
            guard tree.flattened.contains(where: { $0.path == path && !$0.isDirectory }) else { return nil }
            return { [weak self] in Task { await self?.open(path) } }
        }
        guard AppModel.canOpen(url) else { return nil }
        return { [weak app] in app?.pendingImport = url }
    }

    func showInFinder(_ path: String) {
        Task {
            if let url = await fileURL(path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func edited() {
        dirty = true
        if pdfVersion > 0, pdfFreshness == nil { pdfFreshness = .edited }
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
        saving = true
        defer { saving = false }
        // An edit during the write marks it dirty again, and its own save follows.
        dirty = false
        do {
            // Before the write, so its own change event matches.
            diskText = text
            try await core.perform("write_file", ["id": id, "path": path, "text": text])
            writes += 1
            analyze()
            refreshSymbols(delayed: true)
            return true
        } catch {
            dirty = true
            report(error, "“\(name(path))” Wasn’t Saved")
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
            guard let doc = try? await Outline.analyze(project: id, file: path), !Task.isCancelled else { return }
            outline = doc.items
            counts = (doc.words, doc.lines)
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
        let folders = Set(tree.flattened.filter(\.isDirectory).map(\.path))
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
            let parent = (path as NSString).deletingLastPathComponent
            treeChanged = treeChanged || change.structural && (parent.isEmpty || folders.contains(parent))
        }
        // A newer check or reload replaces one that hasn't started.
        if openFileChanged {
            diskCheck?.cancel()
            diskCheck = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.checkDisk()
            }
        }
        if treeChanged {
            treeReload?.cancel()
            treeReload = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.reloadTree(quietly: true)
            }
        }
    }

    /// With no unsaved edits the editor takes the disk's text; otherwise ask.
    private func checkDisk() async {
        // Our own rename or write must finish before its event is read as an external change.
        var mutation: Task<Bool, Never>?
        repeat {
            mutation = lastMutation
            _ = await mutation?.value
        } while mutation != lastMutation && !closed && !Task.isCancelled
        guard let path = openPath, !closed, !Task.isCancelled else { return }
        if let url = openURL, !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            fileGone(path)
            return
        }
        guard editsText else { return }
        guard let file = try? await core.call("read_file", ["id": id, "path": path], as: FileText.self),
              path == openPath, !closed, !Task.isCancelled
        else { return }
        guard mutation == lastMutation else { return await checkDisk() }
        guard file.text != diskText else { return }
        diskText = file.text
        writes += 1
        if pdfVersion > 0 { pdfFreshness = .edited }
        if dirty || saving {
            saveTask?.cancel()
            diskConflict = path
        } else {
            showDiskText(file.text, of: path)
            if autoCompile { await compile(auto: true) }
        }
    }

    /// Another app moved or deleted the open file. It closes, as the sidebar
    /// drops it, unless it has unsaved edits: those are asked about, and not
    /// saved meanwhile, which would put the file back unasked.
    private func fileGone(_ path: String) {
        saveTask?.cancel()
        if hasUnsavedText || saving {
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
    }

    func revertToDisk() async {
        guard let text = diskText else { return }
        let generation = openGeneration
        diskConflict = nil
        saveTask?.cancel()
        _ = await lastMutation?.value
        guard let path = openPath, !closed, generation == openGeneration else { return }
        showDiskText(text, of: path)
        // Written back, in case a save under way when the change came
        // wrote the edits over it.
        dirty = true
        guard await save() else { return }
        if autoCompile { await compile(auto: true) }
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
    func compile(auto: Bool = false) async {
        guard texAvailable, !closed else { return }
        if compiling {
            compileQueued = (compileQueued ?? true) && auto
            return
        }
        // Before the save, so a second request queues instead of racing this one.
        compiling = true
        stopRequested = false
        let saved = await flush()
        let settingsGeneration = mainFileGeneration
        _ = await lastMutation?.value
        let built = writes
        let mainFile = settings?.mainFile
        let mainFileGeneration = self.mainFileGeneration
        func currentBuild() -> Bool {
            !closed && mainFileGeneration == self.mainFileGeneration && mainFile == settings?.mainFile
        }
        if saved, !stopRequested, !closed, settingsGeneration == mainFileGeneration {
            do {
                let result = try await core.call("compile", ["id": id], as: CompileResult.self)
                // A main-file change queues a new build. Its older predecessor
                // must not replace that file's PDF, issues or build status.
                if currentBuild() {
                    // A no-op latexmk run keeps PDFKit's document and find state.
                    // A different output path always loads, even without new bytes.
                    let showedPDF = if result.pdf != nil {
                        await showPDFOnDisk(reloadIfUnchanged: result.pdfChanged)
                    } else { false }
                    if currentBuild() {
                        syncGeneration += 1
                        self.result = result
                        if showedPDF {
                            // Edits or saves made while it built aren't in it.
                            pdfFreshness = dirty || writes != built ? .edited : nil
                        } else if !result.stopped, pdfVersion > 0 {
                            pdfFreshness = .lastSuccessful
                        }
                        if result.failed, !auto || result.pdf == nil { showBuildPanel() }
                        if result.ok, panelTab == .issues, result.errors.isEmpty, result.warnings.isEmpty { showLogs = false }
                        if !result.stopped { notify(result) }
                    }
                }
            } catch {
                if !auto, currentBuild() { report(error, "Couldn’t Compile") }
            }
        }
        compiling = false
        // After a failed save the queued build would only build stale text.
        let again = saved && !closed ? compileQueued : nil
        compileQueued = nil
        if let again { await compile(auto: again) }
    }

    private func notify(_ result: CompileResult) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        // The system already shows the app's name.
        content.title = id
        content.body = switch (result.ok, result.errors.count) {
        case (true, _): "Compiled in \(result.durationText)"
        case (false, 0): "Build failed"
        case (false, 1): "Build failed with 1 error"
        case (false, let n): "Build failed with \(n) errors"
        }
        let center = UNUserNotificationCenter.current()
        Task {
            _ = try? await center.requestAuthorization(options: [.alert])
            try? await center.add(UNNotificationRequest(identifier: "compile.\(id)", content: content, trigger: nil))
        }
    }

    /// A build still running reports and queues nothing, so it can't
    /// supersede the next project's.
    func close() {
        closed = true
        compileQueued = nil
        folderWatcher = nil
        saveTask?.cancel()
        searchTask?.cancel()
        analysis?.cancel()
        symbolsTask?.cancel()
        treeReload?.cancel()
        diskCheck?.cancel()
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
    private func patchSettings(_ patch: [String: Any]) async -> Bool {
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

    func setShellEscape(_ on: Bool) async {
        await patchSettings(["shellEscape": on])
    }

    func setStopOnFirstError(_ on: Bool) async {
        await patchSettings(["stopOnFirstError": on])
    }

    func setMainFile(_ path: String) async {
        guard !closed else { return }
        mainFileGeneration += 1
        syncGeneration += 1
        let generation = mainFileGeneration
        _ = await patchSettings(["mainFile": path])
        guard !closed, generation == mainFileGeneration else { return }
        // Also resettle after a failed patch: an older in-flight build was
        // discarded, and an earlier queued main-file patch may have succeeded.
        await mainFileChanged()
    }

    // ---------- SyncTeX ----------

    func forwardSync() async {
        guard let path = openPath else { return }
        syncGeneration += 1
        let generation = syncGeneration, opened = openGeneration, version = pdfVersion
        let selection = editor.textView.selectedRange(), text = editor.textView.string
        let (line, column, word) = (editor.currentLine, editor.currentColumn, editor.currentSyncWord)
        func current() -> Bool {
            !closed && generation == syncGeneration && opened == openGeneration && version == pdfVersion
                && app?.project === self && openPath == path && editor.textView.selectedRange() == selection && editor.textView.string == text
        }
        guard await saveEdits(), current() else { return }
        do {
            let loc = try await core.call("synctex_forward", ["id": id, "file": path, "line": line, "column": column], as: ForwardLoc.self)
            guard current() else { return }
            highlight = (loc, word, generation)
            showPDF = true
        } catch {
            if current() { report(error, "Couldn’t Find This Line in the PDF") }
        }
    }

    /// `word`, the PDF's word clicked `offset` in, takes the caret to it on the line.
    func inverseSync(page: Int, x: Double, y: Double, word: SyncTeXWord? = nil) async {
        syncGeneration += 1
        let generation = syncGeneration, opened = openGeneration, version = pdfVersion, path = openPath
        let selection = editor.textView.selectedRange(), text = editor.textView.string
        func current(checkOpen: Bool = true) -> Bool {
            !closed && generation == syncGeneration && (!checkOpen || opened == openGeneration) && version == pdfVersion
                && app?.project === self && openPath == path && editor.textView.selectedRange() == selection && editor.textView.string == text
        }
        do {
            // A nil word bridges as null, which the core reads as none.
            let args: [String: Any] = ["id": id, "page": page, "x": x, "y": y, "word": word?.text as Any, "offset": word?.offset as Any,
                                       "context": word?.context as Any, "contextOffset": word?.contextOffset as Any]
            let loc = try await core.call("synctex_inverse", args, as: InverseLoc.self)
            guard current() else { return }
            let opening = openGeneration + 1
            await open(loc.file, line: loc.line, column: loc.column, stillCurrent: { current(checkOpen: false) })
            if generation == syncGeneration, opening == openGeneration, !closed, app?.project === self, openPath == loc.file { editor.focus() }
        } catch {
            if current() { report(error, "Couldn’t Find This Spot in the Source") }
        }
    }

    // ---------- files ----------

    func createEntry(_ path: String, directory: Bool) async throws {
        try await core.perform("create_entry", ["id": id, "path": path, "dir": directory])
        await reloadTree()
        if !directory { await open(path) }
    }

    func renameEntry(_ from: String, to: String) async {
        guard to != from else { return }
        guard await saveEdits() else { return }
        var reopen: (path: String, generation: Int)?
        var mainChanged = false
        _ = await mutate("Couldn’t Rename “\(name(from))”") { model in
            let main = model.settings?.mainFile
            let opened = model.openGeneration
            mainChanged = main.map { remapPath($0, from: from, to: to) != $0 } ?? false
            if mainChanged {
                model.mainFileGeneration += 1
                model.syncGeneration += 1
            }
            let result = try await model.core.call("rename_entry", ["id": model.id, "from": from, "to": to], as: RenameResult.self)
            guard !model.closed else { return false }
            model.editor.rename(from: result.from, to: result.to)
            // The open file may move with its folder. The editor keeps its
            // text; only the save path changes, so the old path can't return.
            let wasOpen = model.openPath
            model.openPath = model.openPath.map { remapPath($0, from: result.from, to: result.to) }
            if let openPath = model.openPath, let wasOpen, openPath != wasOpen {
                model.openURL = model.url(openPath)
                if isTextFile(openPath) != isTextFile(wasOpen) || isLaTeXFile(openPath) != isLaTeXFile(wasOpen) {
                    reopen = (openPath, opened)
                }
            }
            model.settings = model.settings.map {
                ProjectSettings(mainFile: result.mainFile, engine: $0.engine,
                                shellEscape: $0.shellEscape, stopOnFirstError: $0.stopOnFirstError)
            }
            if !mainChanged, result.mainFile != main {
                model.mainFileGeneration += 1
                model.syncGeneration += 1
                mainChanged = true
            }
            return true
        }
        // Opening flushes edits, so it must run after this mutation releases the queue.
        guard !closed else { return }
        if let reopen, openPath == reopen.path, openGeneration == reopen.generation,
           await saveEdits(), !closed, openPath == reopen.path, openGeneration == reopen.generation {
            clearOpenFile()
            await open(reopen.path, focus: false)
        } else if let path = openPath, openURL == nil {
            let url = await fileURL(path)
            if !closed, openPath == path { openURL = url }
        }
        await reloadTree()
        if mainChanged, !closed { await mainFileChanged() }
    }

    func deleteEntry(_ path: String) async {
        // Save before Trash so an autosave cannot recreate the deleted file.
        guard await saveEdits() else { return }
        let deleted = await mutate("Couldn’t Move “\(name(path))” to the Trash") { model in
            // Include edits made while this deletion waited behind another mutation.
            repeat {
                guard await model.write() else { return false }
            } while model.hasUnsavedText
            try await model.core.perform("delete_entry", ["id": model.id, "path": path])
            guard !model.closed else { return false }
            model.editor.forget(path: path)
            if let open = model.openPath, open == path || open.hasPrefix(path + "/") { model.clearOpenFile() }
            return true
        }
        if deleted, !closed { await reloadTree() }
    }

    /// No file editing: the editor may still hold the old text, but nothing saves or analyses it.
    private func clearOpenFile() {
        analysis?.cancel()
        diskCheck?.cancel()
        openPath = nil
        openURL = nil
        diskText = nil
        dirty = false
        outline = []
        counts = nil
    }

    /// Update the main file's PDF path while keeping the old preview until replacement.
    private func mainFileChanged() async {
        analyze()
        let generation = mainFileGeneration
        _ = await lastMutation?.value
        guard !closed, generation == mainFileGeneration else { return }
        await showPDFOnDisk()
        guard !closed, generation == mainFileGeneration else { return }
        await compile(auto: true)
    }

    /// Files dropped on the tree: the project's own move into `dir`, as in Finder,
    /// and files from elsewhere are copied in.
    func dropFiles(_ urls: [URL], into dir: String) async {
        var outside: [URL] = []
        for url in urls {
            guard let path = projectPath(url) else { outside.append(url); continue }
            // Not into the folder it's in, nor a folder into itself.
            let folder = (path as NSString).deletingLastPathComponent
            guard folder != dir, dir != path, !dir.hasPrefix(path + "/") else { continue }
            let name = (path as NSString).lastPathComponent
            await renameEntry(path, to: dir.isEmpty ? name : "\(dir)/\(name)")
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

    /// In a temporary folder; the save panel copies it where it goes.
    func exportZip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("\(id).zip")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await core.perform("export_zip", ["id": id, "dest": url.path])
        return url
    }

    // ---------- search ----------

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard isSearching else {
            searchHits = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled, let self else { return }
            let hits = (try? await self.core.call("search_project", ["id": self.id, "query": query], as: [SearchHit].self)) ?? []
            if !Task.isCancelled { self.searchHits = hits }
        }
    }

    // ---------- editor commands ----------

    func findStep(_ delta: Int) {
        if !editor.findStep(delta) { showFind() }
    }

    func showFind(replacing: Bool = false) {
        guard editsText else { return }
        if let selection = editor.selectionQuery { findQuery.search = selection }
        findShown = true
        editor.setFind(findQuery)
        if replacing {
            replaceShown = true
            replaceFocus += 1
        } else {
            findFocus += 1
        }
    }

    func findAction(_ action: NSTextFinder.Action) -> (() -> Void)? {
        guard editsText else {
            guard action == .showFindInterface, pdfVersion > 0 else { return nil }
            return { [weak self] in self?.app?.requestPDF(.find) }
        }
        switch action {
        case .showFindInterface, .setSearchString: return { self.showFind() }
        case .showReplaceInterface: return { self.showFind(replacing: true) }
        case .nextMatch: return { self.findStep(1) }
        case .previousMatch: return { self.findStep(-1) }
        default: return nil
        }
    }

    /// Done or Escape: unmarks the matches and returns typing to the text.
    func closeFind() {
        findShown = false
        replaceShown = false
        findFocus = 0
        replaceFocus = 0
        editor.closeFind()
        editor.focus()
    }

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
        return "An item named “\((name as NSString).lastPathComponent)” already exists in this location."
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

/// How the PDF on screen differs from the source.
nonisolated enum PDFFreshness {
    case edited
    /// The latest build failed; this is the one before it.
    case lastSuccessful

    var title: String {
        switch self {
        case .edited: "Preview Out of Date"
        case .lastSuccessful: "Last Successful Build"
        }
    }

    var systemImage: String {
        switch self {
        case .edited: "arrow.clockwise"
        case .lastSuccessful: "exclamationmark.triangle.fill"
        }
    }
}
