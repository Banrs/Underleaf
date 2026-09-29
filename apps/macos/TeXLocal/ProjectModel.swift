import AppKit
import Observation
import UserNotifications

/// One open project: its files, the document in the editor, and its builds.
@Observable
final class ProjectModel {
    let id: String
    var settings: ProjectSettings?
    var tree: [TreeNode] = []
    var openPath: String?
    var outline: [OutlineItem] = []
    var counts: (words: Int, lines: Int)?
    var cursorLine = 1
    /// The line at the top of the source, which the outline follows.
    var topLine = 1

    var dirty = false
    var saving = false
    var compiling = false
    var result: CompileResult?
    /// Bumped whenever a new PDF is on disk, so the viewer reloads.
    var pdfVersion = 0
    var pdfURL: URL?
    /// Why the PDF may not match the source (workspace.js `setPdfFreshness`).
    var pdfFreshness: PDFFreshness?
    /// The token lets the same spot be flashed twice.
    var highlight: (loc: ForwardLoc, token: Int)?
    var showLogs = false
    /// 1-based, for reopening where it was.
    var pdfPage = 0
    /// For Go to Page's range.
    var pdfPageCount = 0
    @ObservationIgnored var restorePDFPage: Int?
    var panelTab: PanelTab = .issues

    /// A failed build always names an issue (the core falls back to
    /// latexmk's summary), so the panel opens on them.
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

    /// The source's find bar: CodeMirror's search behind native fields.
    var findShown = false
    var findQuery = FindQuery() {
        didSet {
            guard findQuery != oldValue else { return }
            // Cancelled and replaced, so the last query wins.
            findSync?.cancel()
            let query = findQuery
            findSync = Task { [editor] in
                guard !Task.isCancelled else { return }
                await editor.setFind(query)
            }
        }
    }
    var findMatches = FindMatches()
    /// Bumped to focus the find or replace field; both reset as the bar
    /// closes, so the next bar doesn't take a stale focus request.
    var findFocus = 0
    var replaceFocus = 0
    /// Find and Replace… opens the bar on the replace field.
    private var replacing = false
    /// The replace row: Find and Replace… adds it until the bar closes, so a plain
    /// Find keeps the bar to one row.
    var replaceShown = false
    @ObservationIgnored private var findSync: Task<Void, Never>?

    /// While the workspace asks Replace, Keep Both or Stop.
    var importClash: ImportClash?

    var searchQuery = "" { didSet { scheduleSearch() } }
    /// The sidebar shows search results for a query that isn't only spaces.
    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The latest finished search's hits: nil until the first for a query ends,
    /// so its results pane doesn't read No Results while it runs.
    var searchHits: [SearchHit]?

    /// Per project: one editor web view, which the source column shows.
    let editor = EditorBridge()
    private weak var app: AppModel?
    private let core = Core.shared
    private var saveTask: Task<Void, Never>?
    /// Each save waits for the one before it.
    private var lastSave: Task<Bool, Never>?
    private var searchTask: Task<Void, Never>?
    private var analysis: Task<Void, Never>?
    private var highlightToken = 0
    /// Bumped by each `open`, so an earlier one still in flight stands down.
    private var openGeneration = 0
    private var compileQueued = false
    /// A build still running when the project closes reports nothing.
    private var closed = false
    private var readingText = false
    /// The editor's web process died holding edits not yet on disk.
    private var lostEdits = false
    /// Writes that reached the disk, and how many of them the PDF was built
    /// from: equal means the PDF matches the disk.
    private var writes = 0
    private var builtWrites = 0

    /// Long enough to cover a pause between keystrokes.
    private static let autosaveDelay = Duration.milliseconds(700)
    /// Each search reads every file in the project; wait for typing to pause.
    private static let searchDelay = Duration.milliseconds(200)

    init(id: String, app: AppModel) {
        self.id = id
        self.app = app
    }

    /// Only LaTeX has an outline, counts and the LaTeX tools.
    var isLaTeX: Bool { openPath?.hasSuffix(".tex") == true }
    /// The open file is in the editor rather than a preview.
    var editsText: Bool { openPath.map(isTextFile) ?? false }
    var hasUnsavedText: Bool { dirty && editsText }
    var hasPDF: Bool { pdfVersion > 0 && pdfURL != nil }

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
        SavedWorkspace(project: id, file: openPath, line: cursorLine, buildPanel: showLogs, pdfPage: pdfPage)
    }

    // ---------- loading ----------

    /// Opens the main file, or where `saved` left off. Stops if the project
    /// is left meanwhile, so it never writes to the editor after the next one.
    func load(restoring saved: SavedWorkspace? = nil) async {
        editor.onChanged = { [weak self] in self?.edited() }
        editor.onCursor = { [weak self] line in self?.cursorLine = line }
        editor.onScroll = { [weak self] line in self?.topLine = line }
        editor.onFind = { [weak self] query in
            guard let self else { return }
            findQuery = query
            findShown = true
            if replacing {
                replaceShown = true
                replaceFocus += 1
            } else {
                findFocus += 1
            }
            replacing = false
        }
        editor.onFindClosed = { [weak self] in self?.findClosed() }
        editor.onFindMatches = { [weak self] matches in self?.findMatches = matches }
        editor.onCrash = { [weak self] in
            if let self, dirty || readingText { lostEdits = true }
        }
        editor.onRestart = { [weak self] in Task { await self?.editorRestarted() } }
        editor.webView.fileDrop = { [weak self] in self?.dropped($0) }
        await editor.setHostKeys(MenuCommand.editorHostKeys)
        await editor.useHostFind()
        do {
            settings = try await core.call("get_settings", ["id": id], as: ProjectSettings.self)
            await reloadTree()
            await watchFolder()
            await refreshSymbols()
            guard !closed else { return }
            if let saved {
                showLogs = saved.buildPanel
                restorePDFPage = saved.pdfPage
            }
            let restored = saved?.file.flatMap { file in tree.flattened.contains { $0.path == file } ? file : nil }
            if let file = restored ?? settings?.mainFile { await open(file, line: restored == nil ? nil : saved?.line) }
        } catch {
            if !closed { report(error, "Couldn’t Open “\(id)”") }
        }
        guard !closed else { return }
        if await !showPDFOnDisk(), autoCompile { await compile(auto: true) }
    }

    /// `quietly` for a reload another app's change asked for: its failure
    /// isn't the user's to act on, and the next change tries again.
    func reloadTree(quietly: Bool = false) async {
        do {
            let files = try await core.call("file_tree", ["id": id], as: [TreeNode].self)
            // Only a change redraws the sidebar: a save's temporary file asks for a reload too.
            if files != tree, !closed { tree = files }
        } catch {
            if !quietly { report(error, "Couldn’t Read the Project’s Files") }
        }
    }

    private func refreshSymbols() async {
        if let symbols = try? await core.call("scan_symbols", ["id": id], as: Symbols.self), !closed {
            await editor.setSymbols(symbols)
        }
    }

    /// Shows the PDF the last build left, if it has pages.
    @discardableResult private func showPDFOnDisk() async -> Bool {
        guard let path = try? await core.call("pdf_path", ["id": id], as: String.self) else { return false }
        let url = URL(fileURLWithPath: path)
        guard await Self.hasPages(url) else { return false }
        pdfURL = url
        pdfVersion += 1
        return true
    }

    private func fileURL(_ path: String) async -> URL? {
        (try? await core.call("raw_path", ["id": id, "path": path], as: String.self)).map(URL.init(fileURLWithPath:))
    }

    // ---------- editing ----------

    /// Text opens in the editor, anything else in a preview. The sidebar
    /// passes `focus: false` so the arrow keys stay in its list.
    func open(_ path: String, line: Int? = nil, atTop: Bool = false, focus: Bool = true) async {
        // Only the latest open carries on, so the editor can't show one file
        // while `openPath`, where autosave writes, names another. Checked
        // after the last await before the editor.
        openGeneration += 1
        let generation = openGeneration
        if path != openPath {
            guard await saveEdits(), generation == openGeneration else { return }
            do {
                let text = isTextFile(path) ? try await core.call("read_file", ["id": id, "path": path], as: FileText.self).text : nil
                let url = await fileURL(path)
                guard generation == openGeneration, !closed else { return }
                openPath = path
                openURL = url
                diskText = text
                analyze(text ?? "")
                if let text {
                    await editor.open(path: path, text: text, focus: focus)
                    cursorLine = await editor.currentLine()
                }
            } catch {
                if !closed { report(error, "Couldn’t Open “\(name(path))”") }
                return
            }
        }
        if let line, editsText, generation == openGeneration, !closed { await editor.reveal(line: line, atTop: atTop, focus: focus) }
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
            if await self.save(), self.autoCompile { await self.compile(auto: true) }
        }
    }

    /// False when it couldn't be saved. Saves run in order, one at a time
    /// (workspace.js `saveQueue`), so true means the text reached the disk.
    @discardableResult
    func save() async -> Bool {
        let previous = lastSave
        let task = Task {
            _ = await previous?.value
            return await self.write()
        }
        lastSave = task
        return await task.value
    }

    private func write() async -> Bool {
        guard hasUnsavedText, let path = openPath else { return true }
        // Not over another app's change until asked which to keep.
        guard diskConflict == nil, missingFile == nil else { return false }
        saving = true
        defer { saving = false }
        // Before the read: an edit during the read or write marks it dirty
        // again, and its own save follows.
        dirty = false
        let crashes = editor.crashes
        readingText = true
        let document = await editor.document()
        readingText = false
        guard let document else {
            // The web process died with the edits; the restart reports it.
            if lostEdits || editor.crashes != crashes { return true }
            dirty = true
            app?.alert = AppAlert("“\(name(path))” Wasn’t Saved",
                                  "The editor’s text couldn’t be read. Your changes are still in the editor, and TeXLocal saves them again after your next edit.")
            return false
        }
        // Another file opened meanwhile: the text is that file's, never to be written to this one.
        guard document.path == path else {
            app?.alert = AppAlert("“\(name(path))” Wasn’t Saved",
                                  "Another file opened in the editor before its text could be read.")
            return false
        }
        let text = document.text
        do {
            // Before the write, so its own change event matches.
            diskText = text
            try await core.perform("write_file", ["id": id, "path": path, "text": text])
            writes += 1
            analyze(text)
            await refreshSymbols()
            return true
        } catch {
            dirty = true
            report(error, "“\(name(path))” Wasn’t Saved")
            return false
        }
    }

    /// The web process died and the page came back empty: reopen the file
    /// from disk. Unsaved edits died with it.
    private func editorRestarted() async {
        let lost = lostEdits
        lostEdits = false
        guard let path = openPath else { return }
        saveTask?.cancel()
        clearOpenFile()
        // A save in flight read its text before the crash and still lands.
        _ = await lastSave?.value
        // The disk matches the PDF unless a save has landed since it was built.
        if pdfFreshness == .edited, writes == builtWrites { pdfFreshness = nil }
        await open(path)
        if lost {
            app?.alert = AppAlert("Unsaved Changes Were Lost",
                                  "The editor stopped unexpectedly. Changes to \(path) since it was last saved were lost.")
        }
    }

    /// The outline and counts, for .tex files only; the latest text's wins.
    private func analyze(_ text: String) {
        analysis?.cancel()
        guard isLaTeX else {
            outline = []
            counts = nil
            return
        }
        analysis = Task {
            guard let doc = try? await Outline.analyze(text), !Task.isCancelled else { return }
            outline = doc.items
            counts = (doc.words, doc.lines)
        }
    }

    /// Saves now, cancelling the pending autosave: before a file switch, a
    /// close or quit.
    func flush() async -> Bool {
        saveTask?.cancel()
        // Until no edit arrived during the write (savequeue.js flushUntilStable).
        repeat {
            guard await save() else { return false }
        } while hasUnsavedText
        return true
    }

    /// Saves now and builds when auto-compile is on, since cancelling the
    /// autosave also cancelled its build (workspace.js `doSave`).
    @discardableResult
    func saveEdits() async -> Bool {
        let edited = dirty
        guard await flush() else { return false }
        if edited, autoCompile { Task { await compile(auto: true) } }
        return true
    }

    // ---------- changes on disk ----------

    /// So another app's change (an editor, a sync, git) shows here: the open
    /// file's rather than being saved over, and files come, go and move in
    /// the sidebar.
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
                // The folder itself: moved, or FSEvents lost count of it.
                let folder = change.path == watcher.folder || change.path == watcher.folder + "/"
                treeChanged = treeChanged || change.structural && folder
                continue
            }
            // A folder moves as one change, not one for each file in it.
            openFileChanged = openFileChanged || path == openPath
                || change.structural && openPath?.hasPrefix(path + "/") == true
            let parent = (path as NSString).deletingLastPathComponent
            treeChanged = treeChanged || change.structural && (parent.isEmpty || folders.contains(parent))
        }
        if openFileChanged { scheduleDiskCheck() }
        if treeChanged { scheduleTreeReload() }
    }

    /// FSEvents coalesces a burst of changes; a newer reload replaces this one.
    private func scheduleTreeReload() {
        treeReload?.cancel()
        treeReload = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.reloadTree(quietly: true)
        }
    }

    /// FolderWatcher coalesces a write's events; a newer check replaces this one.
    private func scheduleDiskCheck() {
        diskCheck?.cancel()
        diskCheck = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.checkDisk()
        }
    }

    /// With no unsaved edits the editor takes the disk's text; otherwise ask.
    private func checkDisk() async {
        guard let path = openPath, !closed else { return }
        if let url = openURL, !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            fileGone(path)
            return
        }
        guard editsText,
              let file = try? await core.call("read_file", ["id": id, "path": path], as: FileText.self),
              path == openPath, !closed, file.text != diskText
        else { return }
        diskText = file.text
        writes += 1
        if pdfVersion > 0 { pdfFreshness = .edited }
        if dirty || saving {
            saveTask?.cancel()
            diskConflict = path
        } else {
            await showDiskText(file.text, of: path)
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

    /// The edits go with the file.
    func closeMissingFile() {
        missingFile = nil
        clearOpenFile()
    }

    /// Keeps the scroll position.
    private func showDiskText(_ text: String, of path: String) async {
        let top = topLine
        await editor.open(path: path, text: text, focus: false)
        analyze(text)
        await editor.reveal(line: top, atTop: true, focus: false)
        cursorLine = await editor.currentLine()
    }

    func revertToDisk() async {
        diskConflict = nil
        guard let path = openPath, let text = diskText else { return }
        saveTask?.cancel()
        _ = await lastSave?.value
        await showDiskText(text, of: path)
        // Written back, in case a save under way when the change came
        // wrote the edits over it.
        dirty = true
        guard await save() else { return }
        if autoCompile { await compile(auto: true) }
    }

    /// The next save writes these edits over the other app's.
    func keepEdits() {
        diskConflict = nil
        // The autosave was cancelled while asking.
        Task { await saveEdits() }
    }

    // ---------- compile ----------

    /// Asked while a build runs, queues one to follow (workspace.js
    /// `pendingCompile`). An automatic build reports failures only in the log,
    /// not an alert after every pause in typing.
    func compile(auto: Bool = false) async {
        guard texAvailable, !closed else { return }
        if compiling {
            compileQueued = true
            return
        }
        // Before the save, so a second request queues instead of racing this one.
        compiling = true
        let saved = await flush()
        let built = writes
        if saved {
            do {
                let result = try await core.call("compile", ["id": id], as: CompileResult.self)
                if closed {
                    compiling = false
                    return
                }
                self.result = result
                // Shown whenever the build wrote one, errors or not.
                if result.pdf != nil, await showPDFOnDisk() {
                    builtWrites = built
                    // Edits or saves made while it built aren't in it.
                    pdfFreshness = dirty || writes != built ? .edited : nil
                } else if !result.stopped, pdfVersion > 0 {
                    pdfFreshness = .lastSuccessful
                }
                if result.failed { showBuildPanel() }
                if !result.stopped { notify(result) }
            } catch {
                if !auto, !closed { report(error, "Couldn’t Compile") }
            }
        }
        compiling = false
        // After a failed save the queued build would only build stale text.
        let again = saved && compileQueued && !closed
        compileQueued = false
        if again { await compile(auto: true) }
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
        compileQueued = false
        folderWatcher = nil
        treeReload?.cancel()
        diskCheck?.cancel()
        editor.close()
    }

    /// Kills the build's process group; the compile returns stopped.
    func stopCompile() {
        guard compiling else { return }
        compileQueued = false
        Task { try? await core.perform("stop_compile", ["id": id]) }
    }

    // ---------- settings ----------

    @discardableResult
    private func patchSettings(_ patch: [String: Any]) async -> Bool {
        do {
            settings = try await core.call("set_settings", ["id": id, "patch": patch], as: ProjectSettings.self)
            return true
        } catch {
            report(error, "Couldn’t Change the Project’s Settings")
            return false
        }
    }

    func setEngine(_ engine: String) async {
        // A new engine means nothing until a build uses it, so this builds
        // whatever the auto-compile setting.
        if await patchSettings(["engine": engine]) { await compile() }
    }

    func setShellEscape(_ on: Bool) async {
        await patchSettings(["shellEscape": on])
    }

    func setStopOnFirstError(_ on: Bool) async {
        await patchSettings(["stopOnFirstError": on])
    }

    func setMainFile(_ path: String) async {
        guard path != settings?.mainFile else { return }
        if await patchSettings(["mainFile": path]) { await mainFileChanged() }
    }

    // ---------- SyncTeX ----------

    func forwardSync() async {
        guard let path = openPath else { return }
        guard await saveEdits() else { return }
        let line = await editor.currentLine()
        do {
            let loc = try await core.call("synctex_forward", ["id": id, "file": path, "line": line], as: ForwardLoc.self)
            highlightToken += 1
            highlight = (loc, highlightToken)
            showLogs = false
            showPDF = true
        } catch {
            report(error, "Couldn’t Find This Line in the PDF")
        }
    }

    func inverseSync(page: Int, x: Double, y: Double) async {
        do {
            let loc = try await core.call("synctex_inverse", ["id": id, "page": page, "x": x, "y": y], as: InverseLoc.self)
            await open(loc.file, line: loc.line)
            editor.focus()
        } catch {
            report(error, "Couldn’t Find This Spot in the Source")
        }
    }

    // ---------- files ----------

    func createEntry(_ path: String, directory: Bool) async {
        do {
            try await core.perform("create_entry", ["id": id, "path": path, "dir": directory])
            await reloadTree()
            if !directory { await open(path) }
        } catch {
            report(error, "Couldn’t Create “\(name(path))”")
        }
    }

    func renameEntry(_ from: String, to: String) async {
        guard to != from else { return }
        guard await saveEdits() else { return }
        do {
            let result = try await core.call("rename_entry", ["id": id, "from": from, "to": to], as: RenameResult.self)
            await editor.rename(from: result.from, to: result.to)
            // The open file may move with its folder. The editor keeps its
            // text; only the save path changes, so the old path can't return.
            let wasOpen = openPath
            openPath = openPath.map { remapPath($0, from: result.from, to: result.to) }
            if let openPath, openPath != wasOpen {
                openURL = await fileURL(openPath)
            }
            let main = settings?.mainFile
            settings = try? await core.call("get_settings", ["id": id], as: ProjectSettings.self)
            await reloadTree()
            if settings?.mainFile != main { await mainFileChanged() }
        } catch {
            report(error, "Couldn’t Rename “\(name(from))”")
        }
    }

    func deleteEntry(_ path: String) async {
        // Saved first (sidebar.js `beforePathMutation`): the Trash gets the
        // latest text, and no pending autosave writes the file back.
        guard await saveEdits() else { return }
        do {
            try await core.perform("delete_entry", ["id": id, "path": path])
            await editor.forget(path: path)
            if let open = openPath, open == path || open.hasPrefix(path + "/") { clearOpenFile() }
            await reloadTree()
        } catch {
            report(error, "Couldn’t Move “\(name(path))” to the Trash")
        }
    }

    /// No file editing: the editor's page may still hold the old text, but
    /// nothing saves or analyses it.
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

    /// A build that fails early can leave a PDF with no pages.
    @concurrent private nonisolated static func hasPages(_ url: URL) async -> Bool {
        (CGPDFDocument(url as CFURL)?.numberOfPages ?? 0) > 0
    }

    /// The PDF is named after the main file (sidebar.js `onMainFileChange`).
    /// The old one stays on screen until the build replaces it.
    private func mainFileChanged() async {
        await showPDFOnDisk()
        await compile(auto: true)
    }

    /// Taken names are asked about first (`importClash`), then copied again
    /// with the answer: "replace" (old ones to the Trash) or "keepBoth".
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

    func format(_ command: EditorCommand, _ arg: String? = nil) {
        Task { await editor.command(command, arg) }
    }

    func findStep(_ delta: Int) {
        format(delta > 0 ? .findNext : .findPrevious)
    }

    func replace(all: Bool) {
        format(all ? .replaceAll : .replaceNext)
    }

    func findAndReplace() {
        guard editsText else { return }
        replacing = true
        format(.find)
    }

    /// Edit › Find's items for the source (`WorkspaceController.findAction` sends
    /// them here unless the PDF has the keyboard). The
    /// page's find takes the selection as its query, so it serves Use
    /// Selection for Find too. With no text open, Find goes to the PDF.
    func findAction(_ action: NSTextFinder.Action) -> (() -> Void)? {
        guard editsText else {
            guard action == .showFindInterface, pdfVersion > 0 else { return nil }
            return { [weak self] in self?.app?.requestPDF(.find) }
        }
        switch action {
        case .showFindInterface, .setSearchString: return { self.format(.find) }
        case .showReplaceInterface: return findAndReplace
        case .nextMatch: return { self.findStep(1) }
        case .previousMatch: return { self.findStep(-1) }
        default: return nil
        }
    }

    private func findClosed() {
        findShown = false
        replaceShown = false
        findFocus = 0
        replaceFocus = 0
    }

    /// Done or Escape: unmarks the matches and returns typing to the text.
    func closeFind() {
        findClosed()
        Task {
            await editor.closeFind()
            editor.focus()
        }
    }

    /// An outline heading at the top of the source; the keyboard stays where it is.
    func reveal(_ item: OutlineItem) {
        guard let path = openPath else { return }
        Task { await open(path, line: item.line, atTop: true, focus: false) }
    }

    func reveal(line: Int) {
        Task { await editor.reveal(line: line) }
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
        // A few by name, so a folder's worth doesn't fill the alert.
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
