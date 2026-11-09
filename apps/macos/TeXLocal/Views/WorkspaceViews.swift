import AppKit
import Observation
import PDFKit

@Observable
final class WorkspaceViews: ProjectViews {
    let project: ProjectModel
    let editor = SourceEditor()
    let pdf = PDFController()
    var inspectorShown = false
    @ObservationIgnored private var watches: [Task<Void, Never>] = []

    init(project: ProjectModel) {
        self.project = project
        project.views = self
        connect()
        watches = [
            track({ [weak project] in project?.isOpen != true }) { [weak self] closing in
                self?.editor.textView.isEditable = !closing
            },
            track({ [weak project] in project?.closed ?? true }, initial: false) { [weak self] _ in
                self?.pdf.stopLive()
                self?.pdf.loading?.cancel()
            },
            track({ [weak project] in project?.window?.app.paper ?? .white }) { [weak self] in self?.pdf.view.paper = $0 },
            track({ [weak project] in project?.navigator.hiddenIssueKinds.contains(.badBox) == true }) { [weak self] in
                self?.pdf.view.showsBadBoxes = !$0
            },
        ]
    }

    isolated deinit { watches.forEach { $0.cancel() } }

    private func connect() {
        editor.onCursor = { [weak self] line, column, shown in self?.project.cursorMoved(to: line, column: column, shownColumn: shown) }
        editor.onScroll = { [weak self] in self?.project.scrolled(to: $0) }
        editor.onChange = { [weak self] in self?.changes += 1 }
        editor.command = { [weak self] in if let project = self?.project { project.window?.perform($0, on: project) } }
        let text = editor.textView
        text.isContinuousSpellCheckingEnabled = project.window?.app.spellCheck ?? true
        text.spellCheckToggled = { [weak self] in self?.project.window?.app.spellCheck = $0 }
        text.keyboardChanged = { [weak self] in self?.project.sourceHasKeyboard = $0 }
        text.fileDrop = { [weak self] url in
            guard let project = self?.project else { return nil }
            return switch project.dropAction(for: url) {
            case .insert(let text)?: .insert(text)
            case .copy?: .copy { await project.copyFigure(url) }
            case .open(let path)?: .open { project.session.task { await project.open(path) } }
            case nil: nil
            }
        }
        text.issues.clicked = { [weak self] line in
            if let self, let path = editor.path { project.issueClicked(atLine: line, in: path) }
        }
        text.headings = { [weak self] in
            guard let project = self?.project else { return [] }
            return project.outline.filter { project.isOpenFile($0.file) }.map { ($0.line, $0.title) }
        }
        text.forwardSync = { [weak self] quietly in
            guard let project = self?.project, project.canSyncForward(quietly: quietly) else { return nil }
            return { project.session.task { await project.forwardSync(quietly: quietly, wordOnly: quietly) } }
        }
        text.openDefinition = { [weak self] place in
            guard let project = self?.project else { return }
            project.session.task { await project.open(place.file, line: place.line, column: place.column, length: place.length, jump: true) }
        }
        text.quickHelp = { [weak self] in self?.quickHelp(at: $0, hovering: $1) }
        pdf.onVisiblePages = { [weak self] in self?.project.liveView($0) }
        pdf.view.onInverse = { [weak self] page, point, click, quietly in
            guard let project = self?.project else { return }
            project.session.task { await project.inverseSync(page: page, x: point.x, y: point.y, click: click, quietly: quietly) }
        }
    }

    var hasPDF: Bool { pdf.pageCount > 0 }
    var zoom: Zoom { pdf.keptZoom }
    var pdfPlace: PdfPlace? { pdf.keptPlace }
    var shownPDF: AnyObject? { pdf.view.document }
    var pdfLoading: Task<Void, Never>? { pdf.loading }

    func heard(_ event: Event) {
        switch event {
        case .section(.openFile): showOpenFile()
        case .section(.build), .section(.live):
            showIssues()
            if pdf.isLoading == false, project.store.build?.result?.badBoxes != markedBadBoxes { project.session.task { await self.markBadBoxes() } }
        case .section(.shownPdf): showPDF()
        case .reload(let edits): reload(edits)
        case .renamed(let renamed): editor.rename(from: renamed.from, to: renamed.to)
        case .liveDocument(let document): if project.showsLive { pdf.showLive(document) }
        case .livePage(let page): if project.showsLive { pdf.showLive(page) }
        case .liveFollow(let loc): if project.showsLive { pdf.follow(loc) }
        default: break
        }
    }

    func opened(_ ui: UiState) { pdf.restore = ui.zoom.map { ($0, ui.pdfPlace) } }

    func reveal(_ path: String, line: Int?, column: Int?, length: Int?, atTop: Bool, focus: Bool) {
        guard editor.path == path else { return }
        editor.focusWhenShown = focus
        if let line { editor.reveal(line: line, column: column, length: length, atTop: atTop, focus: focus) } else if focus { editor.focus() }
    }

    func apply(_ edits: DocumentEdits, named name: String) -> Bool {
        guard edits.path == editor.path, editor.textView.document.version == edits.version else { return false }
        return editor.textView.apply(edits.edits, named: name)
    }

    func replace(_ hit: SearchHit, with text: String) -> Bool {
        guard hit.file == editor.path else { return false }
        let found = editor.revealed(line: hit.line, column: hit.column, length: hit.length).found
        guard found.length == hit.length, (editor.textView.string as NSString).substring(with: found) == hit.match else { return false }
        return editor.textView.apply([TextEdit(start: found.location, length: found.length, text: text)], named: String(localized: "Replace"))
    }

    func trashed(_ path: String) { editor.forget(path: path) }
    func beep() { NSSound.beep() }
    func requestAttention() { if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) } }
    func perform(_ command: EditorCommand) { editor.perform(command) }

    func perform(_ command: MenuCommand) {
        switch command {
        case .quickHelp: quickHelp(at: editor.caret, hovering: false)
        case .filePrint: pdf.print(title: project.name, file: project.livePDF ? project.buildPDF : nil)
        case .editShiftRight: editor.textView.shiftLines(1)
        case .editShiftLeft: editor.textView.shiftLines(-1)
        case .jumpToDefinition: editor.jumpToDefinition()
        case .findUsages:
            if let path = editor.path { project.session.task { [project, caret = editor.caret] in await project.findUsages(in: path, at: caret) } }
        case .editRename: project.window?.prompt = renamable.map(Prompt.rename)
        case .editPasteTable:
            if !editor.textView.pasteTable(booktabs: project.store.outline?.packages.contains("booktabs") == true) { beep() }
        // The PDF view stays in this project's window whichever panes show.
        case .openQuickly: OpenQuickly.show(for: project, over: pdf.view.window)
        case .pdfOpen: if let url = project.buildPDF { NSWorkspace.shared.open(url) }
        case .viewToggleInspector: NSApp.sendAction(#selector(NSSplitViewController.toggleInspector(_:)), to: nil, from: nil)
        default: break
        }
    }

    func validates(_ command: MenuCommand) -> Bool {
        switch command {
        case .editRename: renamable != nil
        case .editPasteTable: pastesTable
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
            guard case let (page, point)? = pdf.sourcePoint() else { return }
            project.session.task { [project] in await project.inverseSync(page: page, x: point.x, y: point.y) }
        }
    }

    private(set) var changes = 0
    var selection: NSRange { editor.textView.selectedRange() }
    var lineCount: Int { editor.textView.document.lineCount }
    var textStyles: TextStyles { _ = changes; return editor.textStyles }
    private var renamable: SymbolName? { _ = changes; return editor.renamable }
    private var pastesTable: Bool { _ = changes; return editor.textView.canPasteTable }
    func words(in selection: NSRange) -> Int { editor.textView.document.words(in: selection) }
    func focusEditor() { editor.focus() }

    private func showOpenFile() {
        guard let file = project.store.openFile, file.text, editor.path != file.path || !editor.textView.document.editable,
              let source = SourceDocument(session: project.session, path: file.path) else { return }
        editor.open(path: file.path, source: source)
        showIssues()
    }

    private func showIssues() {
        guard let path = editor.path else { return }
        editor.textView.issues.lines = project.store.build?.lines[path]?.byLine ?? [:]
        editor.textView.issues.live = project.store.live?.lines[path]?.byLine ?? [:]
    }

    private func showPDF() {
        guard let shown = project.store.shownPdf, !shown.live else { return }
        let loading = pdf.load(shown.path.map { URL(filePath: $0) })
        project.session.task { [self] in
            await loading.value
            await markBadBoxes()
        }
    }

    @ObservationIgnored private var markedBadBoxes: [LogItem]?

    /// Marks the last build's bad boxes in the PDF shown, once it has loaded, and again when a build reports others.
    private func markBadBoxes() async {
        let badBoxes = project.store.build?.result?.badBoxes ?? []
        guard let document = pdf.view.document else { return }
        markedBadBoxes = badBoxes
        if badBoxes.isEmpty { return pdf.view.clearBadBoxes() }
        // A PDF that started loading meanwhile is the build's own, and is marked once it has loaded.
        guard let areas = try? await project.session.call(BadBoxAreas()),
              pdf.view.document === document, !pdf.isLoading, markedBadBoxes == badBoxes else { return }
        pdf.view.mark(Dictionary(grouping: areas) { Int($0.area.page) - 1 }) { [weak self] badBox in
            guard let project = self?.project else { return }
            project.session.task { await project.open(badBox.file, line: Int(badBox.line), jump: true) }
        }
    }

    /// Takes the disk's text through an undoable edit, which an edit made since the session asked refuses.
    private func reload(_ edits: DocumentEdits) {
        let top = editor.textView.shownTop
        if apply(edits, named: String(localized: "Reload")) { top.map(editor.textView.scroll(toShownTop:)) }
    }

    /// Hovering, only a reference or citation has help worth showing unasked.
    private func quickHelp(at offset: Int, hovering: Bool) {
        guard let path = editor.path else { return }
        project.session.task { [self] in
            guard let help = await project.quickHelp(in: path, at: offset), editor.path == path,
                  !hovering || [.label, .citation].contains(help.kind) else { return }
            let scale = editor.textView.window?.backingScaleFactor ?? 2
            let picture = help.shown.flatMap { pdf.picture(of: $0, scale: scale) }
            editor.textView.showQuickHelp(help, picture: picture, at: offset, hovering: hovering)
        }
    }
}
