import AppKit
import Observation
import UserNotifications

/// One open project: its files, the document in the editor, and its builds.
/// Every command the menus, toolbar and editor shortcuts can run lands here.
@MainActor @Observable
final class ProjectModel {
    let id: String
    var settings: ProjectSettings?
    var tree: [TreeNode] = []
    var openPath: String?
    var outline: [OutlineItem] = []
    /// Words and lines in the open .tex file, for the status bar.
    var counts: (words: Int, lines: Int)?
    var cursorLine = 1
    /// The line at the top of the source as it scrolls: what the outline follows.
    var topLine = 1

    var dirty = false
    var saving = false
    var compiling = false
    var result: CompileResult?
    /// Bumped whenever a new PDF is on disk, so the viewer reloads.
    var pdfVersion = 0
    var pdfURL: URL?
    /// Why the PDF on screen may not show the source as it is now
    /// (workspace.js `setPdfFreshness`); nil when it does.
    var pdfFreshness: PDFFreshness?
    /// The latest forward-search target, with a counter so the same spot can
    /// be flashed twice.
    var highlight: (loc: ForwardLoc, token: Int)?
    var showLogs = false
    /// Which of the panel's tabs is showing.
    var panelTab: PanelTab = .issues
    /// Remembered across projects and launches, like the web's.
    var showPDF = UserDefaults.standard.object(forKey: "showPDF") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPDF, forKey: "showPDF") }
    }

    /// The open file on disk, for the window's document icon.
    var openURL: URL?
    /// The open file changed on disk while it had edits here: the path,
    /// for the alert that asks which to keep.
    var diskConflict: String?
    /// The open file's text as last read from or written to disk, so a
    /// change on disk is told from this app's own saves.
    private var diskText: String?
    private var watcher: FileWatcher?
    private var diskCheck: Task<Void, Never>?

    /// The source's find bar (Edit › Find and Replace…): CodeMirror's
    /// search, driven from native fields, searched for as the query changes.
    var findShown = false
    var findQuery = FindQuery() {
        didSet { if findQuery != oldValue { Task { await editor.setFind(findQuery) } } }
    }
    var findMatches = FindMatches()
    /// Bumped to put the cursor in the find field, its text selected.
    var findFocus = 0

    var searchQuery = "" { didSet { scheduleSearch() } }
    var searchHits: [SearchHit] = []

    private let editor: EditorBridge
    private weak var app: AppModel?
    private let core = Core.shared
    private var saveTask: Task<Void, Never>?
    /// The latest save; each save waits for the one before it.
    private var lastSave: Task<Bool, Never>?
    private var searchTask: Task<Void, Never>?
    private var highlightToken = 0
    /// Bumped by each `open`, so an earlier one still in flight stands down.
    private var openGeneration = 0
    /// A build was asked for while one ran; it follows when that one ends.
    private var compileQueued = false
    /// The project was closed; a build still running reports nothing.
    private var closed = false
    /// A save is waiting for the editor's text.
    private var readingText = false
    /// The editor's web process died holding edits not yet on disk.
    private var lostEdits = false
    /// Writes that reached the disk, and how many of them the PDF on screen
    /// was built from: equal, the files on disk are the PDF's.
    private var writes = 0
    private var builtWrites = 0

    init(id: String, editor: EditorBridge, app: AppModel) {
        self.id = id
        self.editor = editor
        self.app = app
    }

    var errorCount: Int { result?.errors.count ?? 0 }
    var warningCount: Int { result?.warnings.count ?? 0 }

    /// The one name for "no build yet", shared by the status bar, the
    /// inspector and the Issues tab so they can't drift: a PDF built before
    /// the project was opened (this run of the app or an earlier one) may be
    /// on screen, but its build's issues weren't kept.
    var noBuildTitle: String { pdfVersion > 0 ? "Not Built Since Opening" : "Not Compiled" }
    var texAvailable: Bool { app?.tex?.available ?? false }
    var autoCompile: Bool { app?.autoCompile ?? false }

    var status: String {
        if compiling { return "Compiling…" }
        if saving { return "Saving…" }
        if dirty { return "Edited" }
        return "Saved"
    }

    /// An alert titled with what couldn't be done, the error its message.
    private func report(_ error: Error, _ title: String) {
        app?.alert = AppAlert(title, error)
    }

    /// A project path's last component, for alert titles.
    private func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    // ---------- loading ----------

    func load() async {
        editor.onChanged = { [weak self] in self?.edited() }
        editor.onCursor = { [weak self] line in self?.cursorLine = line }
        editor.onScroll = { [weak self] line in self?.topLine = line }
        // A chord the editor handed back because the native menu owns it
        // (`MenuCommand.editorHostKeys`).
        editor.onCommand = { [weak self] id in
            if let command = MenuCommand(rawValue: id) { self?.app?.perform(command) }
        }
        editor.onFind = { [weak self] query in
            guard let self else { return }
            findQuery = query
            findShown = true
            findFocus += 1
        }
        editor.onFindClosed = { [weak self] in self?.findShown = false }
        editor.onFindMatches = { [weak self] matches in self?.findMatches = matches }
        editor.onCrash = { [weak self] in
            if let self, dirty || readingText { lostEdits = true }
        }
        editor.onRestart = { [weak self] in Task { await self?.editorRestarted() } }
        await editor.setHostKeys(MenuCommand.editorHostKeys)
        await editor.useHostFind()
        do {
            settings = try await core.call("get_settings", ["id": id], as: ProjectSettings.self)
            await reloadTree()
            await refreshSymbols()
            if let main = settings?.mainFile { await open(main) }
        } catch {
            report(error, "Couldn’t Open “\(id)”")
        }
        pdfURL = try? await pdfPath()
        if let pdfURL, FileManager.default.fileExists(atPath: pdfURL.path) {
            pdfVersion += 1
        } else if autoCompile {
            await compile(auto: true)
        }
    }

    func reloadTree() async {
        do {
            tree = try await core.call("file_tree", ["id": id], as: [TreeNode].self)
        } catch {
            report(error, "Couldn’t Read the Project’s Files")
        }
    }

    private func refreshSymbols() async {
        if let symbols = try? await core.call("scan_symbols", ["id": id], as: Symbols.self) {
            await editor.setSymbols(symbols)
        }
    }

    private func pdfPath() async throws -> URL {
        URL(fileURLWithPath: try await core.call("pdf_path", ["id": id], as: String.self))
    }

    /// Where a project path is on disk.
    private func fileURL(_ path: String) async -> URL? {
        (try? await core.call("raw_path", ["id": id, "path": path], as: String.self)).map(URL.init(fileURLWithPath:))
    }

    // ---------- editing ----------

    /// Open a file: text in the editor, anything else in its own app.
    /// Choosing in a sidebar list passes `focus: false`, so the arrow keys
    /// stay in the list, as Xcode's navigator keeps them.
    func open(_ path: String, line: Int? = nil, atTop: Bool = false, focus: Bool = true) async {
        guard isTextFile(path) else {
            if let url = await fileURL(path) { NSWorkspace.shared.open(url) }
            return
        }
        // Clicking one file and then another before the first has opened:
        // only the latest carries on, so the editor can't end up showing one
        // file while `openPath` — where autosave writes — names the other.
        openGeneration += 1
        let generation = openGeneration
        if path != openPath {
            guard await saveEdits(), generation == openGeneration else { return }
            do {
                let file = try await core.call("read_file", ["id": id, "path": path], as: FileText.self)
                guard generation == openGeneration else { return }
                openPath = path
                openURL = await fileURL(path)
                diskText = file.text
                watchOpenFile()
                analyze(file.text)
                await editor.open(path: "\(id)/\(path)", text: file.text, focus: focus)
                cursorLine = await editor.currentLine()
            } catch {
                report(error, "Couldn’t Open “\(name(path))”")
                return
            }
        }
        if let line, generation == openGeneration { await editor.reveal(line: line, atTop: atTop, focus: focus) }
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
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            if await self.save(), self.autoCompile { await self.compile(auto: true) }
        }
    }

    /// Write the editor's text to disk. False when it could not be saved.
    /// Saves run one at a time, in order (workspace.js `saveQueue`): one that
    /// returns true has reached the disk, and two writes never interleave.
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
        guard dirty, let path = openPath else { return true }
        // Not over another app's change until asked which to keep.
        guard diskConflict == nil else { return false }
        saving = true
        defer { saving = false }
        // Before the text is read: an edit that arrives while it is read or
        // written marks the document dirty again, and its own save follows.
        dirty = false
        let crashes = editor.crashes
        readingText = true
        let text = await editor.text()
        readingText = false
        guard let text else {
            // The web process died: these edits died with it, and the
            // restart says so. Nothing is left to save.
            if lostEdits || editor.crashes != crashes { return true }
            dirty = true
            app?.alert = AppAlert("“\(name(path))” Wasn’t Saved",
                                  "The editor’s text couldn’t be read. Your changes are still in the editor, and TeXLocal saves them again after your next edit.")
            return false
        }
        do {
            // Before the write, whose own change notice then matches it.
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

    /// The editor's web process died and its page came back empty: show the
    /// open file again as it is on disk. Edits not yet saved died with it.
    private func editorRestarted() async {
        let lost = lostEdits
        lostEdits = false
        guard let path = openPath else { return }
        saveTask?.cancel()
        dirty = false
        openPath = nil
        // A save in flight read its text before the crash and still lands:
        // it counts once it has.
        _ = await lastSave?.value
        // The editor shows the file as it is on disk again, which is what
        // the PDF was built from unless a save has landed since.
        if pdfFreshness == .edited, writes == builtWrites { pdfFreshness = nil }
        await open(path)
        if lost {
            app?.alert = AppAlert("Unsaved Changes Were Lost",
                                  "The editor stopped unexpectedly. Changes to \(path) since it was last saved were lost.")
        }
    }

    /// The outline, location row and word count read the open document; as in
    /// the web, only a .tex file has them.
    private func analyze(_ text: String) {
        guard openPath?.hasSuffix(".tex") == true else {
            outline = []
            counts = nil
            return
        }
        let doc = Outline.analyze(text)
        outline = doc.outline
        counts = (doc.words, doc.lines)
    }

    /// Save now, cancelling the pending autosave — before a file switch, a
    /// project close, or quit.
    func flush() async -> Bool {
        saveTask?.cancel()
        // Again while an edit arrived during the write (savequeue.js
        // flushUntilStable), so what a quit or a switch leaves is on disk.
        repeat {
            guard await save() else { return false }
        } while dirty && openPath != nil
        return true
    }

    /// Save now, and build what that saved when auto-compile is on: ⌘S, a
    /// file switch, a rename or a forward search cancel the autosave, and its
    /// build must not go with it (workspace.js `doSave`). Leaving the project
    /// flushes instead, which only saves.
    @discardableResult
    func saveEdits() async -> Bool {
        let edited = dirty
        guard await flush() else { return false }
        if edited, autoCompile { Task { await compile(auto: true) } }
        return true
    }

    // ---------- changes on disk ----------

    /// Watch the open file, so a change made by another app (an editor, a
    /// sync, git) shows here rather than being saved over.
    private func watchOpenFile() {
        guard let url = openURL else {
            watcher = nil
            return
        }
        watcher = FileWatcher(url: url) { [weak self] in self?.scheduleDiskCheck() }
    }

    /// Changes come in bursts (a write, then its size and date): read once
    /// they settle.
    private func scheduleDiskCheck() {
        diskCheck?.cancel()
        diskCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.checkDisk()
        }
    }

    /// Nothing unsaved: the editor takes the text on disk. Unsaved edits:
    /// ask which to keep.
    private func checkDisk() async {
        guard let path = openPath, !closed,
              let file = try? await core.call("read_file", ["id": id, "path": path], as: FileText.self),
              path == openPath, file.text != diskText
        else { return }
        diskText = file.text
        // The PDF no longer matches what is on disk.
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

    /// The editor shows the file as it is on disk, at the same place.
    private func showDiskText(_ text: String, of path: String) async {
        let top = topLine
        await editor.open(path: "\(id)/\(path)", text: text, focus: false)
        analyze(text)
        await editor.reveal(line: top, atTop: true, focus: false)
        cursorLine = await editor.currentLine()
    }

    /// Revert: the edits here give way to the file on disk.
    func revertToDisk() async {
        diskConflict = nil
        guard let path = openPath, let text = diskText else { return }
        saveTask?.cancel()
        _ = await lastSave?.value
        await showDiskText(text, of: path)
        // Written back, in case a save that was already under way when the
        // change came wrote these edits over it.
        dirty = true
        guard await save() else { return }
        if autoCompile { await compile(auto: true) }
    }

    /// Keep editing: the next save writes these edits over the other app's.
    func keepEdits() {
        diskConflict = nil
        // The autosave held off while asking.
        Task { await saveEdits() }
    }

    // ---------- compile ----------

    /// Build the PDF. Asked while a build runs, it queues one to follow, so
    /// edits saved meanwhile are built too (workspace.js `pendingCompile`).
    /// An automatic build keeps its failures to the log, rather than putting
    /// up an alert after every pause in typing.
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
                if result.ok {
                    pdfURL = try await pdfPath()
                    pdfVersion += 1
                    builtWrites = built
                    // Edits made while it built still aren't in it, nor may
                    // a save that landed meanwhile be.
                    pdfFreshness = dirty || writes != built ? .edited : nil
                } else {
                    if pdfVersion > 0 { pdfFreshness = .lastSuccessful }
                    if !result.errors.isEmpty { panelTab = .issues; showLogs = true }
                }
                notify(result)
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
        // macOS already names the app; the title says which project.
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
            try? await center.add(UNNotificationRequest(identifier: "compile", content: content, trigger: nil))
        }
    }

    /// The project is being left: a build still running reports nothing and
    /// queues nothing, so it cannot supersede the next project's.
    func close() {
        closed = true
        compileQueued = false
        watcher = nil
        diskCheck?.cancel()
    }

    /// Stop the build in progress (Xcode's Stop, ⌘.): its process group is
    /// killed and the compile returns failed.
    func stopCompile() {
        guard compiling else { return }
        compileQueued = false
        core.killAll()
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
        // A new engine only means something once a build uses it, so it
        // compiles whatever the auto-compile setting, as the web does.
        if await patchSettings(["engine": engine]) { await compile() }
    }

    func setShellEscape(_ on: Bool) async {
        await patchSettings(["shellEscape": on])
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
            await editor.rename(from: "\(id)/\(result.from)", to: "\(id)/\(result.to)")
            // The open file moves with its folder too. The editor keeps its
            // text; only where it is saved changes, so the next save cannot
            // bring the old path back.
            let wasOpen = openPath
            openPath = openPath.map { remapPath($0, from: result.from, to: result.to) }
            if let openPath, openPath != wasOpen {
                openURL = await fileURL(openPath)
                watchOpenFile()
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
        // Saved first, as the web saves before any path change (sidebar.js
        // `beforePathMutation`): the Trash gets the latest text, and no
        // pending autosave writes the file back after it.
        guard await saveEdits() else { return }
        do {
            try await core.perform("delete_entry", ["id": id, "path": path])
            await editor.forget(path: "\(id)/\(path)")
            if let open = openPath, open == path || open.hasPrefix(path + "/") {
                openPath = nil
                watcher = nil
                dirty = false
                outline = []
                counts = nil
            }
            await reloadTree()
        } catch {
            report(error, "Couldn’t Move “\(name(path))” to the Trash")
        }
    }

    /// The PDF is named after the main file, so a new main file means a new
    /// PDF: point Save PDF As at it, and build it, as the web does
    /// (sidebar.js `onMainFileChange`). The old one stays on screen until the
    /// build replaces it.
    private func mainFileChanged() async {
        if let url = try? await pdfPath(), FileManager.default.fileExists(atPath: url.path) {
            pdfURL = url
            pdfVersion += 1
        }
        await compile(auto: true)
    }

    func importFiles(_ urls: [URL]) async {
        do {
            try await core.perform("import_files", ["id": id, "dir": "", "paths": urls.map(\.path)])
        } catch {
            report(error, "Couldn’t Add the Files")
        }
        // After a failure too: the files copied before it are there.
        await reloadTree()
    }

    // ---------- export ----------

    func exportZip(to url: URL) async {
        do {
            try await core.perform("export_zip", ["id": id, "dest": url.path])
        } catch {
            report(error, "Couldn’t Export “\(id)”")
        }
    }

    func savePDF(to url: URL) async {
        guard let pdfURL, FileManager.default.fileExists(atPath: pdfURL.path) else {
            app?.alert = AppAlert("No PDF to Save", "Compile the project first to make its PDF.")
            return
        }
        let files = FileManager.default
        do {
            guard files.fileExists(atPath: url.path) else {
                try files.copyItem(at: pdfURL, to: url)
                return
            }
            // A copy beside it first, swapped in whole: a failed copy leaves
            // the file being replaced as it was.
            let scratch = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: url, create: true)
            defer { try? files.removeItem(at: scratch) }
            let copy = scratch.appendingPathComponent(url.lastPathComponent)
            try files.copyItem(at: pdfURL, to: copy)
            _ = try files.replaceItemAt(url, withItemAt: copy)
        } catch {
            report(error, "Couldn’t Save the PDF")
        }
    }

    // ---------- search ----------

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchHits = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let hits = (try? await self.core.call("search_project", ["id": self.id, "query": query], as: [SearchHit].self)) ?? []
            if !Task.isCancelled { self.searchHits = hits }
        }
    }

    // ---------- editor commands ----------

    func format(_ name: String, _ arg: String? = nil) {
        Task { await editor.command(name, arg) }
    }

    /// The find bar's next or previous match (⌘G, Return, the arrows).
    func findStep(_ delta: Int) {
        format(delta > 0 ? "findNext" : "findPrevious")
    }

    /// Replace the selected match and go to the next, or replace them all.
    func replace(all: Bool) {
        format(all ? "replaceAll" : "replaceNext")
    }

    /// Done or Escape: the matches are unmarked and typing goes back to the text.
    func closeFind() {
        findShown = false
        Task {
            await editor.closeFind()
            editor.focus()
        }
    }

    func reveal(line: Int) {
        Task { await editor.reveal(line: line) }
    }
}

/// Tells when a file changes on disk: written, or replaced (as editors
/// save, writing a new file and renaming it over the old one), in which
/// case it follows the new file at the same path.
@MainActor
final class FileWatcher {
    private let url: URL
    private let changed: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, changed: @escaping @MainActor () -> Void) {
        self.url = url
        self.changed = changed
        start()
    }

    isolated deinit {
        source?.cancel()
    }

    private func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    // The path now names another file (or none yet): watch
                    // that once it is there.
                    source.cancel()
                    self.source = nil
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(100))
                        self?.start()
                    }
                }
                self.changed()
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }
}

/// How the PDF on screen differs from the source.
enum PDFFreshness {
    /// The source has changed since it was built.
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
        case .edited: "clock.arrow.circlepath"
        case .lastSuccessful: "exclamationmark.triangle.fill"
        }
    }
}
