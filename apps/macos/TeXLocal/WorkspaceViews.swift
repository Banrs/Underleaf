import AppKit
import Observation

@Observable
final class WorkspaceViews: ProjectViews {
    let project: ProjectModel
    let editor = SourceEditor()
    let pdf = PDFController()
    @ObservationIgnored private(set) var liveReads: Task<Void, Never>?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var followsCaret = false
    @ObservationIgnored private var watches: [Task<Void, Never>] = []

    init(project: ProjectModel) {
        self.project = project
        project.views = self
        connect()
        watches = [
            track({ [weak project] in project.map { $0.closed || $0.isClosing } ?? true }) { [weak self] closing in
                self?.editor.textView.isEditable = !closing
            },
            track({ [weak project] in project?.closed ?? true }, initial: false) { [weak self] _ in
                self?.followTask?.cancel()
                self?.pdf.loading?.cancel()
            },
        ]
    }

    isolated deinit { watches.forEach { $0.cancel() } }

    private func connect() {
        editor.onCursor = { [weak self] line, column in
            guard let self else { return }
            project.cursorMoved(to: line, column: column, caret: editor.caret, in: editor.path)
        }
        editor.onEdit = { [weak self] in if let self, project.livePDF { followsCaret = true } }
        editor.onScroll = { [weak self] in self?.project.scrolled(to: $0) }
        editor.command = { [weak self] in if let project = self?.project { project.app?.perform($0, on: project) } }
        let text = editor.textView
        text.composing = { [weak self] in if let self { project.composing($0, in: editor.path) } }
        text.keyboardChanged = { [weak self] in self?.project.sourceHasKeyboard = $0 }
        text.fileDrop = { [weak self] in self?.dropped($0) }
        text.issues.clicked = { [weak self] in self?.issueClicked(at: $0) }
        text.headings = { [weak self] in
            guard let project = self?.project else { return [] }
            return project.outline.filter { $0.file == project.openPath }.map { ($0.line, $0.title) }
        }
        text.forwardSync = { [weak self] quietly in
            guard let project = self?.project, project.hasPDF, project.isLaTeX, !quietly || project.app?.showPDF == true else { return nil }
            return { Task { await project.forwardSync(quietly: quietly) } }
        }
        text.openDefinition = { [weak self] place in
            Task { await self?.project.open(place.file, line: place.line, column: place.column, length: place.length, jump: true) }
        }
        text.quickHelp = { [weak self] in self?.quickHelp(at: $0) }
        pdf.onVisiblePages = { [weak self] in self?.project.liveView($0) }
        pdf.view.onInverse = { [weak self] page, point, click, quietly in
            guard let project = self?.project, !quietly || project.app?.showSource == true else { return }
            Task { await project.inverseSync(page: page, x: point.x, y: point.y, click: click, quietly: quietly) }
        }
    }

    var hasPDF: Bool { pdf.pageCount > 0 }
    var zoom: Zoom { pdf.keptZoom }
    var shownVersion: Int { pdf.shownVersion }

    func heard(_ event: Event) {
        switch event {
        case .section(.openFile): showOpenFile()
        case .section(.build): showIssues()
        case .section(.live(let state)):
            if state.phase != .running { followsCaret = false }
            showIssues()
        case .section(.shownPdf): if project.session != nil { showPDF() }
        case .documentReload(let path): reload(path)
        case .documentRenamed(let renamed): if editor.path == renamed.from { editor.path = renamed.to }
        case .buildFinished(let finished): built(finished)
        case .liveDocument(let document): showLive(document)
        case .livePage(let page): showLive(page)
        default: break
        }
    }

    func opened(_ ui: UiState) -> Task<Void, Never>? {
        pdf.restoreZoom = ui.zoom
        return showPDF()
    }

    func reveal(_ path: String, line: Int?, column: Int?, length: Int?, atTop: Bool, focus: Bool) {
        guard editor.path == path else { return }
        editor.focusWhenShown = focus
        if let line { editor.reveal(line: line, column: column, length: length, atTop: atTop, focus: focus) } else if focus { editor.focus() }
    }

    func apply(_ edits: DocumentEdits, named name: String) -> Bool {
        guard edits.path == editor.path, editor.textView.document.version == edits.version else { return false }
        editor.textView.apply(edits.edits, named: name)
        return true
    }

    func moved(from: String, to: String) { editor.rename(from: from, to: to) }
    func trashed(_ path: String) { editor.forget(path: path) }
    func beep() { NSSound.beep() }
    func perform(_ command: EditorCommand) { editor.perform(command) }

    func perform(_ command: MenuCommand) {
        switch command {
        case .quickHelp: quickHelp(at: editor.caret)
        case .filePrint: pdf.print(title: project.name, file: project.livePDF ? project.buildPDF : nil)
        case .editShiftRight: editor.textView.shiftLines(1)
        case .editShiftLeft: editor.textView.shiftLines(-1)
        case .jumpToDefinition: editor.jumpToDefinition()
        case .findUsages: if let path = editor.path { Task { [caret = editor.caret] in await project.findUsages(in: path, at: caret) } }
        case .editRename: project.app?.prompt = editor.renamable.map(Prompt.rename)
        default: break
        }
    }

    func validates(_ command: MenuCommand) -> Bool {
        switch command {
        case .editRename: editor.renamable != nil
        case .viewZoomIn: pdf.canZoomIn
        case .viewZoomOut: pdf.canZoomOut
        default: true
        }
    }

    func perform(_ action: PDFAction, find: () -> Void) {
        guard hasPDF else { return }
        switch action {
        case .zoomIn: pdf.zoom(in: true)
        case .zoomOut: pdf.zoom(in: false)
        case .actualSize: pdf.setScale(1)
        case .fitWidth: pdf.fitWidth()
        case .fitPage: pdf.fitPage()
        case .goToPage(let page): pdf.go(toPage: page)
        case .find: find()
        case let .reveal(loc, source): pdf.reveal(loc, from: source)
        case .inverseFromView:
            if case let (page, point)? = pdf.sourcePoint() { Task { await project.inverseSync(page: page, x: point.x, y: point.y) } }
        }
    }

    var changes: Int { editor.changes.count }
    var selection: NSRange { editor.textView.selectedRange() }
    var lineCount: Int { editor.textView.document.lineCount }
    var textStyles: TextStyles { _ = changes; return editor.textStyles }
    func words(in selection: NSRange) -> Int { editor.textView.document.words(in: selection) }
    func focusEditor() { editor.focus() }

    private func showOpenFile() {
        guard let file = project.store.openFile, file.kind.isText, let session = project.session,
              editor.path != file.path || !editor.textView.document.editable,
              let source = SourceDocument(session: session, path: file.path) else { return }
        editor.open(path: file.path, source: source)
        showIssues()
    }

    private func showIssues() {
        guard let path = editor.path else { return }
        editor.textView.issues.lines = project.store.build?.lines[path]?.byLine ?? [:]
        editor.textView.issues.live = project.store.live?.lines[path]?.byLine ?? [:]
    }

    @discardableResult private func showPDF() -> Task<Void, Never>? {
        guard let shown = project.store.shownPdf, !shown.live else { return nil }
        return pdf.load(shown.path.map { URL(filePath: $0) })
    }

    private func reload(_ path: String) {
        guard editor.path == path, let session = project.session, let source = SourceDocument(session: session, path: path) else { return }
        editor.reload(source)
    }

    private func built(_ finished: BuildFinished) {
        guard let result = project.result else { return }
        if result.ok, !project.outdated, project.app?.showPDF == true, project.isLaTeX,
           UserDefaults.standard.bool(forKey: DefaultsKey.syncAfterCompile) {
            Task { [loading = pdf.loading, project] in
                await loading?.value
                await project.forwardSync(quietly: true)
            }
        }
        if !finished.auto, result.failed, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private var showsLive: Bool { !project.closed && project.texpresso.active && project.livePDF }

    private func showLive(_ live: LiveDocument) {
        _ = enqueue(&liveReads) { [self] in
            guard let document = await PDFController.loadDocument(URL(filePath: live.path)), showsLive else { return }
            pdf.show(document)
            if followsCaret { followCaret() }
        }
    }

    private func showLive(_ live: LivePage) {
        _ = enqueue(&liveReads) { [self] in
            guard let page = await PDFController.loadPage(live.pdf), showsLive else { return }
            pdf.show(page, at: live.page)
        }
    }

    private func followCaret() {
        guard let session = project.session, let path = project.openPath, project.isLaTeX else { return }
        let line = editor.currentLine
        _ = restart(&followTask) { [self] in
            guard let loc = try? await session.call(SynctexForward(file: path, line: line)), !Task.isCancelled, !project.closed,
                  project.livePDF, project.openPath == path else { return }
            followsCaret = false
            pdf.follow(loc)
        }
    }

    private func quickHelp(at offset: Int) {
        guard let path = editor.path else { return }
        Task {
            guard let help = await project.quickHelp(in: path, at: offset), editor.path == path else { return }
            editor.textView.showQuickHelp(help, at: offset)
        }
    }

    private func issueClicked(at line: Int) {
        if let index = editor.textView.issues.lines[line]?.index {
            project.panel.show(.issues)
            project.chooseIssue(index, focus: false, open: false)
        } else if editor.textView.issues.live[line] != nil {
            project.panel.show(.texpresso)
        }
    }

    private func dropped(_ url: URL) -> SourceTextView.FileDrop? {
        guard let path = project.projectPath(url) else {
            return project.includeGraphics(url.lastPathComponent) == nil ? nil : .copy { [project] in await project.copyFigure(url) }
        }
        guard project.tree.node(at: path) != nil else { return nil }
        if let insert = project.includeGraphics(path) { return .insert(insert) }
        return .open { [project] in Task { await project.open(path) } }
    }
}
