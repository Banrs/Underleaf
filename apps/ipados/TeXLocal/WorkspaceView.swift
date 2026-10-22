import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's files and outline beside the source and its PDF. As the window narrows the sidebar folds over the
/// panes, then the source and PDF take turns in one pane (HIG, Layout, Split views): what each shows stays as it was.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    /// iPadOS's own choice at first, which floats the sidebar over the panes where they need the width; View ▸ Sidebar
    /// sets it.
    @State private var columns = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(project: project)
        } detail: {
            DetailView(project: project)
        }
        .onChange(of: app.sidebarShown) { _, shown in columns = shown ? .all : .detailOnly }
        .modifier(WorkspaceModals(project: project))
    }
}

/// The two panes side by side need this much each; below it they take turns.
private let paneMinimum: CGFloat = 320

private enum Pane: String { case source, pdf }

private struct DetailView: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    /// The source's share of the panes side by side.
    @AppStorage("sourceFraction") private var fraction = 0.5
    /// Which of the two shows while they take turns.
    @SceneStorage("pane") private var pane = Pane.source
    @State private var size = CGSize.zero

    private var sideBySide: Bool { size.width >= 2 * paneMinimum }
    /// The build panel stays under the panes where there's height and width for both; otherwise it is a sheet.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var panelBelow: Bool { sizeClass == .regular && verticalSizeClass == .regular }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            panes
            if project.panel.shown, panelBelow {
                Divider()
                // A share of the height, so the source keeps most of what the software keyboard leaves.
                BuildPanel(project: project).frame(height: min(240, size.height * 0.3))
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .navigationTitle(project.openPath?.fileName ?? project.name)
        .navigationSubtitle(BuildStatus(project: project, app: app).text)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar { WorkspaceToolbar(project: project, sideBySide: sideBySide, pane: $pane) }
        .toolbarTitleMenu { TitleMenu(project: project) }
        .inspector(isPresented: $app.inspectorVisible) {
            InspectorView(project: project)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .sheet(isPresented: Binding(get: { project.panel.shown && !panelBelow }, set: { project.panel.shown = $0 })) {
            BuildPanel(project: project)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onAppear { app.performPDF = { perform($0) } }
        .onDisappear { app.performPDF = nil }
    }

    /// Both panes always, so the source's text view keeps its host and the PDF its place; the one not shown is 0 wide.
    private var panes: some View {
        let shows: SplitPanes<SourcePane, PDFPane>.Shown = !app.showPDF ? .leading : sideBySide ? .both : pane == .pdf ? .trailing : .leading
        return SplitPanes(fraction: $fraction, minimum: paneMinimum, shown: shows) {
            SourcePane(project: project)
        } trailing: {
            PDFPane(project: project)
        }
    }

    /// A PDF command shows the PDF; from it, Go to Source shows the source.
    private func perform(_ action: PDFAction) {
        let pdf = project.pdf
        if !sideBySide { pane = action.isInverse ? .source : .pdf }
        guard project.hasPDF else { return }
        switch action {
        case .zoomIn: pdf.zoom(in: true)
        case .zoomOut: pdf.zoom(in: false)
        case .actualSize: pdf.setScale(1)
        case .fitWidth: pdf.fitWidth()
        case .fitPage: pdf.fitPage()
        case .goToPage(let page): pdf.go(toPage: page)
        case .find: pdf.view.findInteraction.presentFindNavigator(showingReplace: false)
        case let .reveal(loc, source): pdf.reveal(loc, from: source)
        case .inverseFromView:
            if case let (page, point)? = pdf.sourcePoint() { Task { await project.inverseSync(page: page, x: point.x, y: point.y) } }
        }
    }
}

private extension PDFAction {
    var isInverse: Bool { if case .inverseFromView = self { true } else { false } }
}

/// The build's state under the file's name, where a moved window can't take it off screen as it can a bottom bar's.
private struct BuildStatus {
    let project: ProjectModel
    let app: AppModel

    var text: Text {
        if project.saveFailure != nil { return Text("Not Saved") }
        if project.compiling { return Text("Compiling…") }
        if project.texpresso.phase != .stopped { return Text(project.texpresso.title) }
        guard let result = project.result else { return Text(app.tex?.available == false ? "TeX Not Found" : "No Build Yet") }
        if result.stopped { return Text("Build Stopped") }
        if result.ok {
            return project.warningCount > 0
                ? Text("Build Succeeded · ^[\(project.warningCount) Warning](inflect: true)")
                : Text("Build Succeeded · \(result.durationText)")
        }
        return project.errorCount == 0 ? Text("Build Failed") : Text("Build Failed · ^[\(project.errorCount) Error](inflect: true)")
    }
}

/// The title's menu: where the Mac's status bar has the place, the words and the pages, and the project's own commands.
private struct TitleMenu: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        if let reason = project.saveFailure {
            Button("Save Again", systemImage: "exclamationmark.triangle") { Task { await project.save() } }
            Text(reason)
            Divider()
        }
        if project.editsText {
            Button("Line \(project.cursorLine), Column \(project.cursorColumn + 1)", systemImage: "arrow.down.to.line") {
                app.perform(.editGotoLine, on: project)
            }
            if let words = project.words { Text("^[\(words) word](inflect: true)") }
        }
        if project.hasPDF, project.pdf.pageCount > 0 {
            Button("Page \(project.pdf.page) of \(project.pdf.pageCount)", systemImage: "doc.text") { app.perform(.pdfGotoPage, on: project) }
        }
        Divider()
        Button("Export as PDF…", systemImage: "square.and.arrow.up") { app.perform(.pdfSave, on: project) }
            .disabled(!app.isEnabled(.pdfSave, on: project))
        Button("Export Project as ZIP…", systemImage: "doc.zipper") { app.perform(.projectExport, on: project) }
        Button("Print…", systemImage: "printer") { app.perform(.filePrint, on: project) }
            .disabled(!app.isEnabled(.filePrint, on: project))
    }
}

private struct WorkspaceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    let sideBySide: Bool
    @Binding var pane: Pane

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Projects", systemImage: "chevron.backward") { Task { await app.close() } }
                .help("Close the project and show all projects")
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            FormatMenu(project: project)
            Menu("Math", systemImage: "x.squareroot") {
                MathMenuItems(project: project) { app.perform(.editMath, on: project) }
            }
            .disabled(!project.isLaTeX)
            Menu("Insert", systemImage: "plus.square.on.square") { InsertMenuItems(project: project) }
                .disabled(!project.isLaTeX)
            Toggle("Live Preview", systemImage: "bolt", isOn: Bindable(project).livePreview)
                .disabled(!project.canSwitchLivePreview)
            Button(app.title(.viewToggleLogs, on: project), systemImage: "list.bullet.rectangle") { project.panel.shown.toggle() }
                .badge(project.errorCount)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if sideBySide {
                Toggle("PDF", systemImage: "rectangle.righthalf.inset.filled", isOn: Binding(get: { app.showPDF }, set: { _ in app.togglePDF() }))
            } else {
                // One pane at a time: the PDF in the source's place, and back.
                Toggle("PDF", systemImage: "doc.richtext", isOn: Binding(get: { app.showPDF && pane == .pdf }, set: { on in
                    pane = on ? .pdf : .source
                    if on, !app.showPDF { app.togglePDF() }
                }))
            }
            Toggle("Inspector", systemImage: "info.circle", isOn: Bindable(app).inspectorVisible)
            CompileButton(project: project, wide: sideBySide)
        }
    }
}

/// The one prominent item: Compile, or Stop with the build's spinner.
private struct CompileButton: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    /// The word where there's room, as the Mac's; its symbol where there isn't.
    let wide: Bool

    var body: some View {
        if project.compiling {
            Button { app.perform(.compileStop, on: project) } label: {
                Label { Text("Stop") } icon: { ProgressView() }
            }
            .help("Stop the build")
        } else {
            Button { app.perform(.compileRun, on: project) } label: {
                if wide { Text("Compile") } else { Label("Compile", systemImage: "play.fill") }
            }
                .buttonStyle(.borderedProminent)
                .disabled(!app.isEnabled(.compileRun, on: project))
                .help("Compile the project")
        }
    }
}

/// Aa: the selection's text styles and its section level, as Notes' format menu.
private struct FormatMenu: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        Menu("Format", systemImage: "textformat") {
            ControlGroup {
                ForEach([MenuCommand.editBold, .editItalic, .editUnderline], id: \.self) { command in
                    Button(command.title, systemImage: command.style?.symbol ?? "") { app.perform(command, on: project) }
                }
            }
            .controlGroupStyle(.palette)
            Section("Section Level") { SectionLevelItems(project: project) }
        }
        .disabled(!project.isLaTeX)
    }
}

/// The source, or what the file shown is when it isn't text.
private struct SourcePane: View {
    let project: ProjectModel

    var body: some View {
        ZStack {
            EditorView(editor: project.editor, shown: project.editsText)
            if let path = project.openPath, !project.editsText, let url = project.url(path) {
                FilePreview(url: url, kind: project.openKind, version: project.previewVersion)
            } else if project.openPath == nil, project.initialLoadComplete {
                ContentUnavailableView("No File Open", systemImage: "text.document", description: Text("Choose a file in the sidebar."))
            }
        }
    }
}

/// An image or PDF in the project, shown as Quick Look would.
private struct FilePreview: View {
    let url: URL
    let kind: FileKind?
    let version: Int

    var body: some View {
        Group {
            if kind == .image, let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                Image(uiImage: image).resizable().scaledToFit().padding()
            } else if kind == .pdf {
                PDFFileView(url: url)
            } else {
                ContentUnavailableView("No Preview", systemImage: "doc", description: Text(url.lastPathComponent))
            }
        }
        .id(version)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct PDFFileView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

private struct PDFPane: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        ZStack {
            PDFRepresentable(project: project)
                .opacity(project.hasPDF ? 1 : 0)
            if !project.hasPDF {
                ContentUnavailableView {
                    Label("No PDF Yet", systemImage: "richtext.page")
                } description: {
                    Text(app.tex?.available == false ? "TeX isn’t available on this iPad yet." : "Compile to preview your document.")
                } actions: {
                    Button("Compile") { app.perform(.compileRun, on: project) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!app.isEnabled(.compileRun, on: project))
                }
            }
        }
        .contextMenu {
            Button(MenuCommand.syncInverse.title, systemImage: "arrow.left.square") { app.perform(.syncInverse, on: project) }
                .disabled(!app.isEnabled(.syncInverse, on: project))
            Button(MenuCommand.pdfGotoPage.title, systemImage: "arrow.down.doc") { app.perform(.pdfGotoPage, on: project) }
                .disabled(!app.isEnabled(.pdfGotoPage, on: project))
        }
    }
}

/// Two panes and the line between them, which a finger drags from a 44 pt band: it stops at the even split, with the
/// alignment haptic, as the Mac's divider does. One pane alone takes the width, the other kept at none.
private struct SplitPanes<Leading: View, Trailing: View>: View {
    enum Shown { case leading, trailing, both }

    @Binding var fraction: Double
    let minimum: CGFloat
    let shown: Shown
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var start: Double?
    @State private var snapped = false

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let limit = min(0.5, Double(minimum / max(total, 1)))
            let share = switch shown {
            case .leading: 1.0
            case .trailing: 0.0
            case .both: min(max(fraction, limit), 1 - limit)
            }
            HStack(spacing: 0) {
                leading.frame(width: total * share).hidden(share == 0)
                if shown == .both { Divider() }
                trailing.frame(maxWidth: .infinity).hidden(share == 1)
            }
            .overlay(alignment: .leading) {
                if shown == .both { divider(at: total * share, total: total, limit: limit) }
            }
            .sensoryFeedback(.alignment, trigger: snapped) { _, now in now }
        }
    }

    private func divider(at x: CGFloat, total: CGFloat, limit: Double) -> some View {
        Color.clear
            .frame(width: 44)
            .contentShape(.rect)
            .hoverEffect(.highlight)
            .offset(x: x - 22)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { drag in
                let from = start ?? fraction
                start = from
                var next = min(max(from + drag.translation.width / total, limit), 1 - limit)
                let even = abs(next - 0.5) * total < 12
                if even { next = 0.5 }
                snapped = even
                fraction = next
            }.onEnded { _ in start = nil })
            .accessibilityRepresentation {
                Slider(value: $fraction, in: limit...(1 - limit)) { Text("Source and PDF Divider") }
            }
    }
}

private extension View {
    /// Out of sight, touch and VoiceOver, but still in the hierarchy.
    func hidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }
}

/// The prompts, file dialogs and alerts of the project, as the Mac's modals in iPadOS's own.
private struct WorkspaceModals: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var promptText = ""

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            .fileImporter(isPresented: Binding(get: { app.addingFiles && !project.closed }, set: { app.addingFiles = $0 }),
                          allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await project.importFiles(urls) }
                case .failure(let error): app.alert = AppAlert("Couldn’t Add the Files", error)
                }
            }
            .fileExporter(isPresented: Binding(get: { app.exporting != nil }, set: { if !$0 { app.exporting = nil } }),
                          item: app.exporting, contentTypes: app.exporting.map { [$0.type] } ?? [],
                          defaultFilename: app.exporting?.name) { [name = app.exporting?.name ?? ""] result in
                if case .failure(let error) = result { app.alert = AppAlert("Couldn’t Save “\(name)”", error) }
            }
            .alert(promptTitle, isPresented: Binding(get: { app.prompt != nil }, set: { if !$0 { app.prompt = nil } }),
                   presenting: app.prompt) { prompt in
                TextField(promptField(prompt), text: $promptText)
                    .keyboardType(prompt == .gotoLine || prompt == .gotoPage ? .numberPad : .default)
                Button("Cancel", role: .cancel) {}
                Button(promptAction(prompt)) { answer(prompt) }
            }
            .onChange(of: app.prompt) { _, prompt in
                if case .rename(let symbol)? = prompt { promptText = symbol.name } else { promptText = "" }
            }
            .alert(project.importClash?.title ?? "", item: $project.importClash) { clash in
                Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "keepBoth") } }
                Button("Replace", role: .destructive) { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "replace") } }
                Button("Cancel", role: .cancel) {}
            } message: { clash in
                Text(clash.message)
            }
            .alert(project.diskConflict.map { "“\($0.fileName)” Changed on Disk" } ?? "", item: $project.diskConflict) { path in
                Button("Save Anyway") { project.answer(path, "save") }
                Button("Revert", role: .destructive) { project.answer(path, "revert") }
                Button("Cancel", role: .cancel) {
                    project.answer(path, "cancel", holding: String(localized: "Another app changed “\(path.fileName)”."))
                }
            } message: { path in
                Text("Another app changed “\(path)” while it has unsaved changes here.")
            }
            .alert(project.missingFile.map { "“\($0.fileName)” Was Moved or Deleted" } ?? "", item: $project.missingFile) { path in
                Button("Save Again") { project.answer(path, "save") }
                Button("Discard Changes", role: .destructive) { project.answer(path, "close") }
                Button("Cancel", role: .cancel) {
                    project.answer(path, "cancel", holding: String(localized: "Another app moved or deleted “\(path.fileName)”."))
                }
            } message: { path in
                Text("Another app moved or deleted “\(path)”, which has unsaved changes here.")
            }
    }

    private var promptTitle: String {
        switch app.prompt {
        case .gotoLine: String(localized: "Go to Line")
        case .gotoPage: String(localized: "Go to Page")
        case .rename(let symbol): String(localized: "Rename “\(symbol.name)”")
        case nil: ""
        }
    }

    private func promptField(_ prompt: Prompt) -> String {
        switch prompt {
        case .gotoLine: String(localized: "Line number")
        case .gotoPage: project.pdf.pageCount > 0 ? "1–\(project.pdf.pageCount)" : String(localized: "Page number")
        case .rename: String(localized: "New Name")
        }
    }

    private func promptAction(_ prompt: Prompt) -> String {
        if case .rename = prompt { String(localized: "Rename") } else { String(localized: "Go") }
    }

    private func answer(_ prompt: Prompt) {
        let text = promptText.trimmingCharacters(in: .whitespaces)
        switch prompt {
        case .gotoLine:
            if let line = Int(text), line >= 1 { project.editor.reveal(line: min(line, project.editor.textView.document.lineCount)) }
        case .gotoPage:
            if let page = Int(text), page >= 1 { app.requestPDF(.goToPage(page)) }
        case .rename(let symbol):
            guard !text.isEmpty, text != symbol.name else { return }
            Task { await project.alerting("Couldn’t Rename “\(symbol.name)”") { try await project.renameSymbol(symbol, to: text) } }
        }
    }
}
