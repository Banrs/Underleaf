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
    /// Words and lines in the open .tex file, for the word-count pill.
    var counts: (words: Int, lines: Int)?
    var cursorLine = 1

    var dirty = false
    var saving = false
    var compiling = false
    var result: CompileResult?
    /// Bumped whenever a new PDF is on disk, so the viewer reloads.
    var pdfVersion = 0
    var pdfURL: URL?
    /// The latest forward-search target, with a counter so the same spot can
    /// be flashed twice.
    var highlight: (loc: ForwardLoc, token: Int)?
    var showLogs = false
    /// Remembered across projects and launches, like the web's.
    var showPDF = UserDefaults.standard.object(forKey: "showPDF") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPDF, forKey: "showPDF") }
    }

    var searchQuery = "" { didSet { scheduleSearch() } }
    var searchHits: [SearchHit] = []

    private let editor: EditorBridge
    private weak var app: AppModel?
    private let core = Core.shared
    private var saveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var highlightToken = 0

    init(id: String, editor: EditorBridge, app: AppModel) {
        self.id = id
        self.editor = editor
        self.app = app
    }

    var errorCount: Int { result?.errors.count ?? 0 }
    var warningCount: Int { result?.warnings.count ?? 0 }
    var texAvailable: Bool { app?.tex?.available ?? false }
    var autoCompile: Bool { app?.autoCompile ?? false }

    var status: String {
        if compiling { return "Compiling…" }
        if saving { return "Saving…" }
        if dirty { return "Edited" }
        return "Saved"
    }

    private func report(_ error: Error) {
        app?.alert = error.localizedDescription
    }

    // ---------- loading ----------

    func load() async {
        editor.onChanged = { [weak self] in self?.edited() }
        editor.onCursor = { [weak self] line in self?.cursorLine = line }
        editor.onCommand = { [weak self] id in self?.run(id) }
        await editor.setHostKeys(MenuCommand.editorHostKeys)
        do {
            settings = try await core.call("get_settings", ["id": id], as: ProjectSettings.self)
            await reloadTree()
            await refreshSymbols()
            if let main = settings?.mainFile { await open(main) }
        } catch {
            report(error)
        }
        pdfURL = try? await pdfPath()
        if let pdfURL, FileManager.default.fileExists(atPath: pdfURL.path) {
            pdfVersion += 1
        } else if autoCompile && texAvailable {
            await compile()
        }
    }

    func reloadTree() async {
        do {
            tree = try await core.call("file_tree", ["id": id], as: [TreeNode].self)
        } catch {
            report(error)
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

    // ---------- editing ----------

    /// Open a file: text in the editor, anything else in its own app.
    func open(_ path: String, line: Int? = nil) async {
        guard isTextFile(path) else {
            if let abs = try? await core.call("raw_path", ["id": id, "path": path], as: String.self) {
                NSWorkspace.shared.open(URL(fileURLWithPath: abs))
            }
            return
        }
        if path != openPath {
            guard await flush() else { return }
            do {
                let file = try await core.call("read_file", ["id": id, "path": path], as: FileText.self)
                openPath = path
                analyze(file.text)
                await editor.open(path: "\(id)/\(path)", text: file.text)
                cursorLine = await editor.currentLine()
            } catch {
                report(error)
                return
            }
        }
        if let line { await editor.reveal(line: line) }
    }

    private func edited() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            if await self.save(), self.autoCompile, self.texAvailable { await self.compile() }
        }
    }

    /// Write the editor's text to disk. False when it could not be saved.
    @discardableResult
    func save() async -> Bool {
        guard dirty, let path = openPath else { return true }
        guard let text = await editor.text() else { return false }
        saving = true
        defer { saving = false }
        do {
            // An edit made while this write is in flight marks the document
            // dirty again, and its own save follows.
            dirty = false
            try await core.perform("write_file", ["id": id, "path": path, "text": text])
            analyze(text)
            await refreshSymbols()
            return true
        } catch {
            dirty = true
            report(error)
            return false
        }
    }

    /// The outline, breadcrumb and word count read the open document; as in
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

    /// File › section › subsection at the cursor (web/src/workspace.js
    /// `renderCrumbs`).
    var breadcrumb: [String] {
        guard let path = openPath else { return [] }
        return [(path as NSString).lastPathComponent] + Outline.chain(outline, at: cursorLine).map(\.title)
    }

    /// Save now, cancelling the pending autosave — before a file switch, a
    /// project close, or quit.
    func flush() async -> Bool {
        saveTask?.cancel()
        return await save()
    }

    // ---------- compile ----------

    func compile() async {
        guard !compiling, texAvailable else { return }
        guard await flush() else { return }
        compiling = true
        defer { compiling = false }
        do {
            let result = try await core.call("compile", ["id": id], as: CompileResult.self)
            self.result = result
            if result.ok {
                pdfURL = try await pdfPath()
                pdfVersion += 1
            } else if !result.errors.isEmpty {
                showLogs = true
            }
            notify(result)
        } catch {
            report(error)
        }
    }

    private func notify(_ result: CompileResult) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "TeXLocal"
        content.body = switch (result.ok, result.errors.count) {
        case (true, _): String(format: "Compiled in %.1fs", Double(result.durationMs) / 1000)
        case (false, 0): "Compile failed"
        case (false, 1): "Compile failed — 1 error"
        case (false, let n): "Compile failed — \(n) errors"
        }
        let center = UNUserNotificationCenter.current()
        Task {
            _ = try? await center.requestAuthorization(options: [.alert])
            try? await center.add(UNNotificationRequest(identifier: "compile", content: content, trigger: nil))
        }
    }

    func setEngine(_ engine: String) async {
        do {
            settings = try await core.call("set_settings", ["id": id, "patch": ["engine": engine]], as: ProjectSettings.self)
            // A new engine only means something once a build uses it, so it
            // compiles whatever the auto-compile setting, as the web does.
            await compile()
        } catch {
            report(error)
        }
    }

    // ---------- SyncTeX ----------

    func forwardSync() async {
        guard let path = openPath else { return }
        guard await flush() else { return }
        let line = await editor.currentLine()
        do {
            let loc = try await core.call("synctex_forward", ["id": id, "file": path, "line": line], as: ForwardLoc.self)
            highlightToken += 1
            highlight = (loc, highlightToken)
            showLogs = false
            showPDF = true
        } catch {
            report(error)
        }
    }

    func inverseSync(page: Int, x: Double, y: Double) async {
        do {
            let loc = try await core.call("synctex_inverse", ["id": id, "page": page, "x": x, "y": y], as: InverseLoc.self)
            await open(loc.file, line: loc.line)
            editor.focus()
        } catch {
            report(error)
        }
    }

    // ---------- files ----------

    func createEntry(_ path: String, directory: Bool) async {
        do {
            try await core.perform("create_entry", ["id": id, "path": path, "dir": directory])
            await reloadTree()
            if !directory { await open(path) }
        } catch {
            report(error)
        }
    }

    func renameEntry(_ from: String, to: String) async {
        guard to != from else { return }
        guard await flush() else { return }
        do {
            let result = try await core.call("rename_entry", ["id": id, "from": from, "to": to], as: RenameResult.self)
            await editor.forget(path: "\(id)/\(result.from)")
            // The open file moves with its folder too. The editor keeps its
            // text; only where it is saved changes, so the next save cannot
            // bring the old path back.
            openPath = openPath.map { remapPath($0, from: result.from, to: result.to) }
            settings = try? await core.call("get_settings", ["id": id], as: ProjectSettings.self)
            await reloadTree()
        } catch {
            report(error)
        }
    }

    func deleteEntry(_ path: String) async {
        do {
            try await core.perform("delete_entry", ["id": id, "path": path])
            await editor.forget(path: "\(id)/\(path)")
            if let open = openPath, open == path || open.hasPrefix(path + "/") {
                openPath = nil
                dirty = false
            }
            await reloadTree()
        } catch {
            report(error)
        }
    }

    func setMainFile(_ path: String) async {
        do {
            settings = try await core.call("set_settings", ["id": id, "patch": ["mainFile": path]], as: ProjectSettings.self)
        } catch {
            report(error)
        }
    }

    func importFiles(_ urls: [URL], into dir: String = "") async {
        do {
            _ = try await core.call("import_files", ["id": id, "dir": dir, "paths": urls.map(\.path)], as: Saved.self)
            await reloadTree()
        } catch {
            report(error)
        }
    }

    // ---------- export ----------

    func exportZip(to url: URL) async {
        do {
            try await core.perform("export_zip", ["id": id, "dest": url.path])
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            report(error)
        }
    }

    func savePDF(to url: URL) async {
        guard let pdfURL else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: pdfURL, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            report(error)
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

    func reveal(line: Int) {
        Task { await editor.reveal(line: line) }
    }

    /// A command the editor handed back because the native menu owns its
    /// shortcut (see `MenuCommand.editorHostKeys`).
    func run(_ commandID: String) {
        guard let command = MenuCommand(rawValue: commandID) else { return }
        app?.perform(command)
    }
}
