import Accessibility
import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

@Observable
final class ProjectModel {
    let id: String
    var settings: ProjectSettings?
    let tree: FileTree
    private(set) var initialLoadComplete = false
    var openPath: String?
    var outline: [OutlineItem] = []
    var documentClass: DocumentClass?
    @ObservationIgnored private var classFile: String?
    var words: Int?
    var cursorLine = 1
    var cursorColumn = 0
    @ObservationIgnored var topLine = 1
    private(set) var topHeading: Int?

    var dirty = false
    private(set) var saveFailure: String?
    private(set) var pdfOutdated = false
    @ObservationIgnored private var edits = 0
    @ObservationIgnored private var lastEdit: [String: Int] = [:]
    @ObservationIgnored private var resultEdits = 0
    var compiling = false
    var result: CompileResult?
    private(set) var chosenIssue: Int?
    nonisolated enum ShownPDF: Equatable { case none, build(URL), live(URL) }
    var shown = ShownPDF.none
    var hasPDF: Bool { shown != .none }
    var livePDF: Bool { if case .live = shown { true } else { false } }
    private(set) var buildPDF: URL?
    let pdf = PDFController()
    let panel: BuildPanelModel
    let texpresso: TeXpressoSession
    @ObservationIgnored private var liveRestartTask: Task<Void, Never>?
    @ObservationIgnored private var liveDiskTask: Task<Void, Never>?
    @ObservationIgnored private var liveDiskPaths = Set<String>()
    @ObservationIgnored private var liveIntent = 0
    @ObservationIgnored private var liveChanges = 0

    var issues: [LogItem] { (result?.errors ?? []) + (result?.warnings ?? []) }

    func chooseIssue(_ place: Int?, focus: Bool) {
        chosenIssue = place
        let issues = issues
        guard let place, issues.indices.contains(place), let file = issues[place].file else { return }
        Task { await open(file, line: issues[place].line, focus: focus) }
    }

    func goToIssue(next: Bool) {
        let issues = issues, places = issues.indices.filter { issues[$0].file != nil }
        guard let first = places.first, let last = places.last else { return }
        let place = if let chosenIssue {
            next ? places.first { $0 > chosenIssue } ?? first : places.last { $0 < chosenIssue } ?? last
        } else {
            next ? first : last
        }
        panel.show(.issues)
        chooseIssue(place, focus: true)
    }

    private func markIssues() {
        var lines: [Int: SourceTextView.LineIssue] = [:]
        if let openPath, lastEdit[openPath, default: 0] <= resultEdits {
            for item in issues.reversed() where item.file == openPath {
                guard let line = item.line else { continue }
                let others = lines[line].map { [$0.message] + $0.others } ?? []
                lines[line] = .init(isError: item.isError, message: item.message, others: others)
            }
        }
        editor.textView.issueLines = lines
    }

    var openURL: URL? { openPath.flatMap(url) }
    var diskConflict: String?
    var missingFile: String?
    /// Cancel leaves it, and no save writes over the other app's change, or puts the file back, unasked.
    @ObservationIgnored private var changedFile: String?
    @ObservationIgnored private var goneFile: String?
    private(set) var previewVersion = 0
    @ObservationIgnored private var diskText: String?
    /// While a stat still gives it, a change told of the file is our own save's, or no change, and the file isn't read again.
    @ObservationIgnored private var diskStamp: FileStamp?
    private var folderWatcher: FolderWatcher?

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
    @ObservationIgnored private(set) var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastMutation: Task<Bool, Never>?
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private var symbolsTask: Task<Void, Never>?
    // Each of these is cancelled by the next request of its kind, which then has the editor or viewer.
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var pdfLoad: Task<Bool, Never>?
    @ObservationIgnored private var compileQueued: Bool?
    @ObservationIgnored private var stopRequested = false
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
        let core = Core.shared
        texpresso = TeXpressoSession(id: id, calls: .init(
            status: { try await core.call($0, $1, as: TeXpressoStatus.self) },
            update: { try await core.perform("texpresso_update", $0) },
            now: { try core.now($0, $1) },
            wait: core.waiting("texpresso_wait", as: TeXpressoEvents.self)))
        panel = BuildPanelModel(texpresso: texpresso)
        texpresso.onFailure = { [weak self] in self?.panel.show(.texpresso) }
        texpresso.onOwnershipLost = { [weak self] in self?.cancelTeXpressoWork() }
        tree.onChange = { [weak self] in self?.filesChanged() }
        texpresso.showDocument = { [weak self] in self?.showLive($0) }
        texpresso.showPage = { [weak self] page, index in
            if self?.livePDF == true { self?.pdf.showLive(page, at: index) }
        }
        texpresso.shownPages = { [weak self] in self?.pdf.view.document?.pageCount ?? 0 }
        pdf.onVisiblePages = { [weak self] in self?.texpresso.view($0) }
        pdf.buildBehindLive = { [weak self] in self.flatMap { $0.livePDF ? $0.buildPDF : nil } }
        texpresso.onEnded = { [weak self] restartable in
            guard let self else { return }
            if restartable, !closed {
                texpresso.restart(liveStart)
                if texpresso.active { return notices.note(String(localized: "Live Preview Restarted")) }
            }
            Task { await self.endLivePDF() }
            if autoCompile { Task { await self.compile(auto: true) } }
        }
    }

    var isLaTeX: Bool { openPath.map(isLaTeXFile) ?? false }
    var headingStyles: HeadingStyles {
        HeadingStyles(documentClass: documentClass, hasChapters: outline.contains { $0.level == 1 })
    }

    var headingLevel: HeadingLevel {
        outline.first { $0.file == openPath && $0.line == cursorLine }.flatMap { HeadingLevel.atDepth($0.level) } ?? .normalText
    }
    var editsText: Bool { openPath.map(isTextFile) ?? false }
    var hasUnsavedText: Bool { dirty && openPath != nil && editor.path == openPath }

    var errorCount: Int { result?.errors.count ?? 0 }
    var warningCount: Int { result?.warnings.count ?? 0 }

    var showsLastSuccessfulBuild: Bool { hasPDF && result?.failed == true && result?.pdf == nil }
    var texAvailable: Bool { app?.tex?.available ?? false }
    var autoCompile: Bool { app?.autoCompile ?? false }

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
        editor.onChanged = { [weak self] in self?.edited() }
        editor.onCursor = { [weak self] line, column in
            guard let self else { return }
            cursorLine = line
            cursorColumn = column
            if texpresso.active, let path = editor.path { texpresso.caretMoved(path, editor.textView.selectedRange().location) }
        }
        editor.textView.textEdited = { [weak self] range, text in
            guard let self, texpresso.active, let path = editor.path else { return }
            texpresso.edit(path, range, text) { self.editor.textView.string }
        }
        editor.onScroll = { [weak self] line in
            guard let self else { return }
            topLine = line
            topHeading = Outline.current(outline, file: openPath, line: line)
        }
        editor.textView.fileDrop = { [weak self] in self?.dropped($0) }
        editor.textView.issueClicked = { [weak self] line in
            guard let self, let place = issues.firstIndex(where: { $0.file == self.openPath && $0.line == line }) else { return }
            panel.show(.issues)
            chosenIssue = place
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
            try await tree.read()
            let root = try await core.call("project_root", ["id": id], as: String.self)
            guard !closed else { return }
            folderWatcher = FolderWatcher(folder: URL(filePath: root, directoryHint: .isDirectory)) { [weak self] in self?.folderChanged($0) }
            refreshSymbols()
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
        let hasPDF = await pdfShown
        guard !closed else { return }
        initialLoadComplete = true
        if !hasPDF, autoCompile { await compile(auto: true) }
    }

    private func filesChanged() {
        analyze()
        // TeXpresso keeps the texts it was sent through a rescan, so only a new session drops one whose file has gone or moved.
        if initialLoadComplete, texpresso.active {
            let paths = Set(tree.nodes.flattened.map(\.path))
            if texpresso.files.isSubset(of: paths) { texpresso.rescan() } else { restartTeXpresso() }
        }
    }

    private func refreshSymbols(delayed: Bool = false) {
        restart(&symbolsTask, after: delayed ? .milliseconds(150) : .zero) { [weak self] in
            guard let self, let symbols = try? await core.call("scan_symbols", ["id": id], as: Symbols.self),
                  !Task.isCancelled, !closed else { return }
            editor.textView.symbols = symbols
        }
    }

    /// A no-op build's PDF is already shown: reopening every page would lose PDFKit's state.
    @discardableResult private func showPDFOnDisk(reloadIfUnchanged: Bool = true, replacingLive: Bool = false) async -> Bool {
        await restart(&pdfLoad) { [self] in
            guard !closed, let path = try? await core.call("pdf_path", ["id": id], as: String.self),
                  !Task.isCancelled, !closed else { return false }
            let url = URL(filePath: path)
            var live: Bool { replacingLive ? livePreviewing : livePDF }
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
        guard livePDF, !livePreviewing, !(await showPDFOnDisk(replacingLive: true)), livePDF, !livePreviewing, !closed else { return }
        shown = .none
        pdf.clear()
    }

    private func showLive(_ live: LiveDocument) {
        guard texpresso.active, !closed else { return }
        if !livePDF, app?.showPDF == false { app?.showPDF = true }
        shown = .live(live.url)
        pdf.showLive(live.document, changed: live.changed, complete: live.complete)
    }

    // MARK: - Editing

    /// Only the latest open carries on, so the editor can't show one file while `openPath`, where autosave writes, names another.
    func open(_ path: String, line: Int? = nil, column: Int? = nil, atTop: Bool = false, focus: Bool = true) async {
        await restart(&openTask) { [self] in
            if path != openPath {
                do {
                    // Read first and saved last, with nothing awaited between the save and the switch: a key typed while the next file is read is still the open file's.
                    let read = isTextFile(path) ? try await readDisk(path) : nil
                    guard await saveEdits(), !Task.isCancelled, !closed else { return }
                    openPath = path
                    (diskText, diskStamp) = (read?.text, read?.stamp)
                    analyze()
                    if let text = read?.text {
                        editor.open(path: path, text: text, focus: focus)
                        cursorLine = editor.currentLine
                        markIssues()
                        // Its text as the editor has it, so the first key there is an edit of a text TeXpresso has.
                        texpresso.update(TeXpressoFile(path: path, text: editor.textView.string))
                    }
                } catch {
                    if !Task.isCancelled, !closed { report(error, "Couldn’t Open “\(path.fileName)”") }
                    return
                }
            }
            if let line, editsText, !Task.isCancelled, !closed { editor.reveal(line: line, column: column, atTop: atTop, focus: focus) }
        }.value
    }

    private func readText(_ path: String) async throws -> String {
        try await core.call("read_file", ["id": id, "path": path], as: FileText.self).text
    }

    /// Its stamp is from before the read: a file changed meanwhile has another stamp by the next check, which reads it again.
    private func readDisk(_ path: String) async throws -> (text: String, stamp: FileStamp?) {
        let stamp = url(path).flatMap(FileStamp.init(of:))
        return (try await readText(path), stamp)
    }

    func url(_ path: String) -> URL? {
        folderWatcher.map { URL(filePath: $0.folder).appending(path: path) }
    }

    func projectPath(_ url: URL) -> String? {
        folderWatcher?.relativePath(FolderWatcher.realPath(url))
    }

    private func dropped(_ url: URL) -> SourceTextView.FileDrop? {
        guard let path = projectPath(url), tree.node(at: path)?.isDirectory == false else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        if isLaTeX, type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true {
            return .insert("\\includegraphics{\(path)}")
        }
        return .open { [weak self] in Task { await self?.open(path) } }
    }

    func showInFinder(_ path: String) {
        if let url = self.url(path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func edited() {
        dirty = true
        edits += 1
        if let openPath { lastEdit[openPath] = edits }
        if !editor.textView.issueLines.isEmpty { editor.textView.issueLines = [:] }
        if hasPDF { pdfOutdated = true }
        restart(&saveTask, after: .milliseconds(700)) { [weak self] in
            guard let self, await save(reporting: false), !Task.isCancelled else { return }
            // In a task of its own: this one is cancelled by the next key, and by the build's own save.
            if autoCompile { Task { await self.compile(auto: true) } }
        }
    }

    /// A failure is an alert only when `reporting`; an autosave's stays in the status bar, where it doesn't come back at every pause in typing.
    func save(reporting: Bool = true) async -> Bool {
        await mutate { await $0.write(reporting: reporting) }
    }

    private func write(reporting: Bool = true) async -> Bool {
        guard hasUnsavedText, let document = editor.document else { return true }
        guard diskConflict == nil, missingFile == nil else { return false }
        // The editor's text, which is the open file's: they change together.
        let (path, text) = document
        // Nor after the alert's Cancel: a save someone asked for asks again.
        if goneFile == path {
            if reporting { missingFile = path }
            return false
        }
        if changedFile == path {
            if reporting { diskConflict = path }
            return false
        }
        // An edit during the write marks it dirty again, and its own save follows.
        dirty = false
        let previous = diskText
        do {
            // Before the write, so its own change event matches.
            diskText = text
            diskStamp = try await core.call("write_file", ["id": id, "path": path, "text": text], as: FileStamp.self)
            saveFailure = nil
            analyze()
            refreshSymbols(delayed: true)
            return true
        } catch {
            // The disk still has what it had, so a later change event isn't taken for another app's.
            if diskText == text { diskText = previous }
            dirty = true
            let title = String(localized: "“\(path.fileName)” Wasn’t Saved")
            if saveFailure == nil { notices.announce(title) }
            saveFailure = error.localizedDescription
            if reporting { report(error, title) }
            return false
        }
    }

    private func analyze() {
        analysis?.cancel()
        guard isLaTeX, let path = openPath else {
            outline = []
            words = nil
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
            words = doc.words
            // The class changes with the main file only.
            guard let main = settings?.mainFile, main == path || main != classFile,
                  let text = main == path ? editor.document?.text
                    : try? await readText(main),
                  !Task.isCancelled else { return }
            documentClass = DocumentClass(in: text)
            classFile = main
        }
    }

    func flush(reporting: Bool = true) async -> Bool {
        saveTask?.cancel()
        repeat {
            guard await save(reporting: reporting) else { return false }
        } while hasUnsavedText
        return true
    }

    @discardableResult
    func saveEdits(reporting: Bool = true) async -> Bool {
        let edited = dirty
        guard await flush(reporting: reporting) else { return false }
        if edited, autoCompile { Task { await compile(auto: true) } }
        return true
    }

    // MARK: - Changes on disk

    private func folderChanged(_ changes: [FolderWatcher.Change]) {
        guard let watcher = folderWatcher else { return }
        let entries = tree.nodes.flattened
        let folders = Set(entries.filter(\.isDirectory).map(\.path))
        let files = Set(entries.filter { !$0.isDirectory }.map(\.path))
        let previewed = texpresso.active ? Set(entries.map(\.path)) : []
        // A save, ours or another app's, renames a new file over a listed one, which leaves the tree as it was; nor does the core list a hidden file.
        func listedAsBefore(_ path: String) -> Bool {
            path.fileName.hasPrefix(".") || files.contains(path) && watcher.hasFile(path)
        }
        var openFileChanged = false, treeChanged = false
        for change in changes {
            guard let path = watcher.relativePath(change.path) else {
                // The folder itself: moved, or FSEvents lost count of it, so the open file may have changed unseen too.
                let folder = change.path == watcher.folder || change.path == watcher.folder + "/"
                treeChanged = treeChanged || change.structural && folder
                openFileChanged = openFileChanged || change.structural && folder && openPath != nil
                continue
            }
            openFileChanged = openFileChanged || path == openPath
                || change.structural && openPath?.hasPrefix(path + "/") == true
            let parent = path.parentFolder
            treeChanged = treeChanged || change.structural && (parent.isEmpty || folders.contains(parent)) && !listedAsBefore(path)
            if previewed.contains(path) { liveDiskPaths.insert(path) }
        }
        if openFileChanged {
            // In the mutation lane, so our own rename or write is never read as another app's change.
            Task { [weak self] in
                guard let self, await mutate(nil, { await $0.checkDisk() }), autoCompile else { return }
                await compile(auto: true)
            }
        }
        if treeChanged { tree.reloadSoon() }
        if texpresso.active, !liveDiskPaths.isEmpty { refreshTeXpressoDisk() }
    }

    private func checkDisk() async -> Bool {
        guard let path = openPath else { return false }
        if let url = openURL, !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            fileGone(path)
            return false
        }
        goneFile = nil
        guard editsText else {
            previewVersion += 1
            return false
        }
        // Our own save's change, or the folder's, leaves the file as it was read or written.
        if let diskStamp, diskStamp.exact, openURL.flatMap(FileStamp.init(of:)) == diskStamp { return false }
        guard let (text, stamp) = try? await readDisk(path), path == openPath, !closed else { return false }
        diskStamp = stamp
        guard text != diskText else { return false }
        diskText = text
        guard !dirty else {
            saveTask?.cancel()
            // Asked once: after Cancel, at the next save someone asks for.
            if changedFile != path { diskConflict = path }
            changedFile = path
            return false
        }
        showDiskText(text, of: path)
        return true
    }

    /// Unsaved edits are asked about and not saved meanwhile, which would put the file back unasked.
    private func fileGone(_ path: String) {
        saveTask?.cancel()
        changedFile = nil
        if hasUnsavedText {
            if goneFile != path { missingFile = path }
            goneFile = path
        } else {
            clearOpenFile()
        }
    }

    func saveMissingFile() {
        (missingFile, goneFile) = (nil, nil)
        Task { await saveEdits() }
    }

    func closeMissingFile() {
        (missingFile, goneFile) = (nil, nil)
        clearOpenFile()
    }

    private func showDiskText(_ text: String, of path: String) {
        let top = topLine
        // The last build's lines were the replaced text's: they go as on an edit, and stay gone until a build has read it.
        edits += 1
        lastEdit[path] = edits
        if !editor.textView.issueLines.isEmpty { editor.textView.issueLines = [:] }
        editor.open(path: path, text: text, focus: false)
        analyze()
        editor.reveal(line: top, atTop: true, focus: false)
        cursorLine = editor.currentLine
        texpresso.update(TeXpressoFile(path: path, text: text))
    }

    /// Written back in case a save under way when the change came wrote the edits over it.
    func revertToDisk(_ path: String) async {
        (diskConflict, changedFile) = (nil, nil)
        saveTask?.cancel()
        let reverted = await mutate { model in
            guard model.openPath == path, let text = model.diskText else { return false }
            model.showDiskText(text, of: path)
            model.dirty = true
            return await model.write()
        }
        if reverted, autoCompile { await compile(auto: true) }
    }

    func leaveUnsaved(_ reason: String) {
        (diskConflict, missingFile) = (nil, nil)
        saveFailure = reason
    }

    func keepEdits() {
        (diskConflict, changedFile) = (nil, nil)
        // The autosave was cancelled while asking, or the edits were already saved before the other app's change: either way they're written again.
        dirty = true
        Task { await saveEdits() }
    }

    // MARK: - Compile

    /// A request during a build queues one follow-up. An automatic build changes the status bar and the gutter alone, and waits while TeXpresso previews, without changing the preference.
    func compile(auto: Bool = false) async {
        guard texAvailable, !closed, !auto || !livePreviewing else { return }
        if compiling {
            compileQueued = (compileQueued ?? true) && auto
            return
        }
        // Before the save, so a second request queues instead of racing this one.
        compiling = true
        stopRequested = false
        let saved = await flush(reporting: !auto)
        let built = edits
        if saved, !stopRequested, !closed, !auto || !livePreviewing {
            // Not through `notices.announce`: the result of a short build isn't held back for it.
            if !auto { AccessibilityNotification.Announcement(String(localized: "Compiling")).post() }
            let result: CompileResult
            do {
                result = try await core.call("compile", ["id": id], as: CompileResult.self)
            } catch {
                let issue = LogItem(type: "error", file: nil, line: nil, message: error.localizedDescription)
                result = CompileResult(ok: false, stopped: false, pdf: nil, pdfChanged: false, durationMs: 0,
                                       errors: [issue], warnings: [], log: "")
            }
            // The PDF is the main file's now: a main-file change stopped any build of the old one.
            if result.pdf != nil, !closed {
                await showPDFOnDisk(reloadIfUnchanged: result.pdfChanged)
                pdfOutdated = edits != built
                // Not after typing through the build: the PDF hasn't the caret's text yet, and the sync would save it mid-word and start the next build at once.
                if result.ok, !pdfOutdated, app?.showPDF == true, isLaTeX, UserDefaults.standard.bool(forKey: DefaultsKey.syncAfterCompile) {
                    Task { await forwardSync(quietly: true) }
                }
            }
            if !closed {
                let errors = errorCount
                self.result = result
                resultEdits = built
                chosenIssue = nil
                markIssues()
                if !auto {
                    finishedManualBuild(result)
                } else if errorCount != errors {
                    announceResult(result, queued: true)
                }
            }
        }
        compiling = false
        // After a failed save the queued build would only build stale text.
        let again = saved && !closed ? compileQueued : nil
        compileQueued = nil
        if let again { await compile(auto: again) }
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

    func close() {
        guard !closed else { return }
        stopCompile()
        closed = true
        // The old workspace can remain visible while a live start drains.
        editor.textView.isEditable = false
        cancelTeXpressoWork()
        texpresso.close()
        // Its renames and its files' moves to the Trash can't be undone once it's closed; the window's stack outlives it.
        let undo = app?.undoManager
        undo?.removeAllActions(withTarget: self)
        for item in trashed { undo?.removeAllActions(withTarget: item) }
        trashed = []
        folderWatcher = nil
        removeExport()
        notices.cancel()
        saveTask?.cancel()
        analysis?.cancel()
        symbolsTask?.cancel()
        tree.close()
        openTask?.cancel()
        syncTask?.cancel()
        pdfLoad?.cancel()
    }

    func stopCompile() {
        guard compiling else { return }
        compileQueued = nil
        stopRequested = true
        Task { try? await core.perform("stop_compile", ["id": id]) }
    }

    // MARK: - Settings

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

    func patchSettings(_ change: SettingsChange) async -> Bool {
        let before = settings
        settings?.apply(change)
        let done = await mutate("Couldn’t Change the Project’s Settings") { model in
            let updated = try await model.core.call("set_settings", ["id": model.id, "patch": change.patch], as: ProjectSettings.self)
            guard !model.closed else { return false }
            model.settings = updated
            return true
        }
        if !done, !closed { settings = before }
        return done
    }

    func setBuildOption(_ change: SettingsChange) async {
        if await patchSettings(change), autoCompile { await compile(auto: true) }
    }

    func cleanBuildFolder() async {
        guard !closed else { return }
        stopCompile()
        for await building in Observations({ self.compiling }) where !building { break }
        let cleaned = await keepingLive {
            do {
                try await core.perform("clean_build", ["id": id])
                return true
            } catch {
                if !closed { report(error, "Couldn’t Clean the Build Folder") }
                return false
            }
        }
        guard cleaned, !closed else { return }
        pdfLoad?.cancel()
        buildPDF = nil
        if !livePDF {
            shown = .none
            pdf.clear()
        }
        result = nil
        chosenIssue = nil
        pdfOutdated = false
        markIssues()
        if autoCompile { await compile(auto: true) }
    }

    func setMainFile(_ path: String) async {
        if await keepingLive({ await patchSettings(.mainFile(path)) }), !closed { await mainFileChanged() }
    }

    // MARK: - TeXpresso live preview

    private var livePreviewing: Bool { texpresso.active || liveRestartTask != nil || liveChanges > 0 }

    /// The core ends a live session when a rename or a new main file changes what it previews; one live before starts again after, unless stopped or started meanwhile.
    @discardableResult
    private func keepingLive(_ change: () async -> Bool) async -> Bool {
        guard texpresso.active else { return await change() }
        let live = liveIntent
        liveChanges += 1
        let changed = await change()
        liveChanges -= 1
        if changed, live == liveIntent, !closed { restartTeXpresso() } else { await endLivePDF() }
        return changed
    }

    private var liveStart: TeXpressoSession.Start {
        guard editsText, let path = editor.path, path == openPath else { return .init(files: []) }
        return .init(files: [TeXpressoFile(path: path, text: editor.textView.string)],
                     caret: TeXpressoCaret(path: path, offset: editor.textView.selectedRange().location))
    }

    func startTeXpresso() {
        guard !closed, texpresso.canStart else { return }
        liveIntent += 1
        if let pages = pdf.visiblePages { texpresso.view(pages) }
        texpresso.start(liveStart)
    }

    func stopTeXpresso() {
        cancelTeXpressoWork()
        texpresso.stop()
        // Its pages go now, not as its stop ends: one stopped already, while it was to start again, ends nothing.
        Task { await endLivePDF() }
    }

    private func cancelTeXpressoWork() {
        liveIntent += 1
        liveRestartTask?.cancel()
        liveRestartTask = nil
        liveDiskTask?.cancel()
        liveDiskPaths.removeAll()
    }

    private func restartTeXpresso() {
        restart(&liveRestartTask, after: .milliseconds(180)) { [weak self] in
            guard let self, !closed else { return }
            texpresso.restart(liveStart)
            liveRestartTask = nil
            // Not started after all: another window has the project's session.
            if !texpresso.active { await endLivePDF() }
        }
    }

    private func refreshTeXpressoDisk() {
        restart(&liveDiskTask, after: .milliseconds(180)) { [weak self] in
            guard let self else { return }
            // Our own save of the open file isn't news to TeXpresso: a rescan then, landing as it typesets the edit, stalled it (TeXpresso e8df770).
            var others = false
            for path in liveDiskPaths {
                guard !closed, !Task.isCancelled, texpresso.active else { return }
                if path != openPath { others = true }
                if path != openPath, isTextFile(path) {
                    guard let text = try? await readText(path), !Task.isCancelled, path != openPath else { continue }
                    texpresso.update(TeXpressoFile(path: path, text: text))
                }
                liveDiskPaths.remove(path)
            }
            guard others, !closed, !Task.isCancelled else { return }
            texpresso.rescan()
        }
    }

    // MARK: - SyncTeX

    func forwardSync(quietly: Bool = false) async {
        guard let path = openPath else { return }
        let (line, column, word) = (editor.currentLine, editor.currentColumn, editor.currentSyncWord)
        let live = livePDF, args = syncArguments(["id": id, "file": path, "line": line, "column": column])
        await restart(&syncTask) { [self] in
            guard await saveEdits(reporting: !quietly), !Task.isCancelled, !closed, openPath == path else { return }
            // Only on the pages it was found in: a rebuild may have moved it.
            let shown = pdf.shownVersion
            do {
                let loc = try await core.call("synctex_forward", args, as: ForwardLoc.self)
                guard !Task.isCancelled, !closed, openPath == path, pdf.shownVersion == shown, livePDF == live else { return }
                app?.requestPDF(.reveal(loc, word))
            } catch {
                if !quietly, !Task.isCancelled, !closed { reportSync(error, "Couldn’t Find This Line in the PDF") }
            }
        }.value
    }

    private func syncArguments(_ arguments: [String: any Sendable]) -> [String: any Sendable] {
        guard livePDF, let owner = texpresso.owner else { return arguments }
        return arguments.merging(["live": true, "session": owner]) { $1 }
    }

    func inverseSync(page: Int, x: Double, y: Double, word: SyncTeXWord? = nil) async {
        await restart(&syncTask) { [self] in
            do {
                // A nil word bridges as null, which the core reads as none.
                let args = syncArguments(["id": id, "page": page, "x": x, "y": y, "word": word?.text, "offset": word?.offset,
                                          "context": word?.context, "contextOffset": word?.contextOffset])
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

    private func performRename(_ from: String, to: String) async -> RenameResult? {
        guard to != from, await saveEdits() else { return nil }
        var reopen: String?
        var mainChanged = false
        var renamed: RenameResult?
        await keepingLive {
            let renaming = await mutate("Couldn’t Rename “\(from.fileName)”") { model in
                let result = try await model.core.call("rename_entry", ["id": model.id, "from": from, "to": to], as: RenameResult.self)
                guard !model.closed else { return false }
                renamed = result
                model.editor.rename(from: result.from, to: result.to)
                // The editor keeps its text; only the save path changes, so the old path can't return.
                if let was = model.openPath, case let now = remapPath(was, from: result.from, to: result.to), now != was {
                    model.openPath = now
                    if isTextFile(now) != isTextFile(was) || isLaTeXFile(now) != isLaTeXFile(was) { reopen = now }
                }
                mainChanged = result.mainFile != model.settings?.mainFile
                model.settings?.mainFile = result.mainFile
                return true
            }
            // Opening flushes edits, so it must run after this mutation releases the queue.
            guard !closed else { return false }
            if let reopen, openPath == reopen, await flush(), !closed, openPath == reopen {
                clearOpenFile()
                await open(reopen, focus: false)
            }
            await tree.reload()
            return renaming
        }
        guard !closed else { return nil }
        if mainChanged { await mainFileChanged() }
        return renamed
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

    private func clearOpenFile() {
        openPath = nil
        (diskText, diskStamp) = (nil, nil)
        dirty = false
        saveFailure = nil
        analyze()
    }

    private func mainFileChanged() async {
        analyze()
        let building = compiling
        stopCompile()
        if texpresso.active { restartTeXpresso() }
        await showPDFOnDisk()
        if !closed, autoCompile || building { await compile(auto: autoCompile) }
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

    /// The core archives the files on disk, so the open file's edits are saved first: an archive without them would be a stale copy reported as a good one.
    func exportZip() async throws -> URL {
        guard await saveEdits() else {
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

/// A stat that gives the same is of the same file, not written since (`atomic::Stamp`).
nonisolated struct FileStamp: Decodable, Equatable {
    let inode: UInt64
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    init?(of url: URL) {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        (inode, size, seconds, nanoseconds) = (info.st_ino, info.st_size, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec)
    }

    /// A volume that keeps whole seconds only (HFS+, FAT) could give the same stamp for another app's same-length write in the same second: there, every change is read.
    var exact: Bool { nanoseconds != 0 }
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
