import PDFKit
import SwiftUI

/// The sidebar's files and outline beside the source and its PDF. As the window narrows the sidebar folds over the
/// panes, then the source and PDF take turns in one pane (HIG, Layout, Split views): what each shows stays as it was.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    /// iPadOS's own choice at first, which floats the sidebar over the panes where they need the width; View ▸ Sidebar
    /// sets it.
    @State private var columns = NavigationSplitViewVisibility.automatic
    /// Where the split collapses to one column (a narrow window): the source and PDF, which the sidebar's back button
    /// leaves and a file or heading chosen there returns to.
    @State private var compactColumn = NavigationSplitViewColumn.detail

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            SidebarView(project: project) { compactColumn = .detail }
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
                // A share of the height, so the source keeps most of what the software keyboard leaves, but never less
                // than the panel's bar and two rows.
                BuildPanel(project: project).frame(height: min(240, max(140, size.height * 0.3)))
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
        let shows: SplitPanes<SourcePane, PDFPane>.Shown = !app.showPDF ? .leading : !app.showSource ? .trailing
            : sideBySide ? .both : pane == .pdf ? .trailing : .leading
        return SplitPanes(fraction: $fraction, minimum: paneMinimum, shown: shows) {
            SourcePane(project: project)
        } trailing: {
            PDFPane(project: project)
        }
    }

    /// A PDF command shows the PDF; from it, Go to Source shows the source.
    private func perform(_ action: PDFAction) {
        if !sideBySide { pane = action.isInverse ? .source : .pdf }
        project.perform(action) { project.pdf.view.findInteraction.presentFindNavigator(showingReplace: false) }
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
        if project.texpresso.phase != .stopped {
            // As the Mac's status bar: the engine whose breaks the pages show, when the compiled PDF's differ.
            return project.liveEngine.map { Text("\(Text(project.texpresso.title)) · \($0)") } ?? Text(project.texpresso.title)
        }
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
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some ToolbarContent {
        // Collapsed, the bar's back button is the sidebar's, which has this one.
        if sizeClass == .regular {
            ToolbarItem(placement: .topBarLeading) { CloseProjectButton() }
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            FormatMenu(project: project)
            Menu("Math", systemImage: "x.squareroot") {
                MathMenuItems(project: project) { app.perform(.editMath, on: project) }
            }
            .disabled(!project.sourceToolsEnabled)
            Menu("Insert", systemImage: "plus.square.on.square") { InsertMenuItems(project: project) }
                .disabled(!project.sourceToolsEnabled)
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
                Toggle("PDF", systemImage: "doc.richtext", isOn: Binding(get: { app.showPDF && (pane == .pdf || !app.showSource) }, set: { on in
                    pane = on ? .pdf : .source
                    if on, !app.showPDF { app.togglePDF() }
                    if !on, !app.showSource { app.toggleSource() }
                }))
            }
            Toggle("Inspector", systemImage: "info.circle", isOn: Bindable(app).inspectorVisible)
            CompileButton(project: project, wide: sideBySide)
        }
    }
}

/// Back to every project, closing this one.
struct CloseProjectButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Projects", systemImage: "chevron.backward") { Task { await app.close() } }
            .help("Close the project and show all projects")
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
        .disabled(!project.sourceToolsEnabled)
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
    @AppStorage(DefaultsKey.pdfPaper) private var paper = PDFPaper.white
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = paper.isDark(in: colorScheme)
        ZStack {
            // Inverted with its hues turned back, as the Mac's pages and Smart Invert, by SwiftUI as UIKit has no layer
            // filters; round the pages, the view's own colour is outside it.
            PDFRepresentable(project: project, darkPaper: dark)
                .contrast(dark ? -1 : 1)
                .hueRotation(.degrees(dark ? 180 : 0))
                .background(Color(uiColor: project.pdf.view.surround))
                .opacity(project.hasPDF ? 1 : 0)
            if !project.hasPDF {
                ContentUnavailableView {
                    Label("No PDF Yet", systemImage: "richtext.page")
                } description: {
                    Text(app.tex?.available == false ? "This build of TeXLocal doesn’t include TeX." : "Compile to preview your document.")
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

/// Two panes and the line between them, which a finger drags sideways from a 44 pt band: it stops at the even split, with
/// the alignment haptic, as the Mac's divider does. One pane alone takes the width, the other kept at none.
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
                if shown == .both {
                    Color.clear
                        .frame(width: 44)
                        .offset(x: total * share - 22)
                        .accessibilityRepresentation {
                            Slider(value: $fraction, in: limit...(1 - limit)) { Text("Source and PDF Divider") }
                        }
                }
            }
            .gesture(DividerPan(x: shown == .both ? total * share : nil) { moved in
                guard let moved else { start = nil; return }
                let from = start ?? fraction
                start = from
                var next = min(max(from + moved / total, limit), 1 - limit)
                let even = abs(next - 0.5) * total < 12
                if even { next = 0.5 }
                snapped = even
                fraction = next
            })
            .sensoryFeedback(.alignment, trigger: snapped) { _, now in now }
        }
    }
}

/// A pan across the divider's band that begins only sideways, so taps, scrolls and selections there stay the panes'.
private struct DividerPan: UIGestureRecognizerRepresentable {
    let x: CGFloat?
    /// The distance dragged, then nil at the end.
    let moved: (CGFloat?) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Band { Band(converter: converter) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) { context.coordinator.x = x }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .changed: moved(context.converter.localTranslation?.x ?? 0)
        case .ended, .cancelled: moved(nil)
        default: break
        }
    }

    final class Band: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var x: CGFloat?

        init(converter: CoordinateSpaceConverter) { self.converter = converter }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let x, let velocity = converter.localVelocity else { return false }
            let start = converter.localLocation.x - (converter.localTranslation?.x ?? 0)
            return abs(start - x) <= 22 && abs(velocity.x) > abs(velocity.y)
        }

        // A pane's scrolling waits for the band, which decides as soon as the finger moves; nothing that waits for a
        // still finger, such as selection's long press, does.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            (other.view as? UIScrollView)?.panGestureRecognizer === other
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
            .modifier(ProjectDialogs(project: project))
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
            .alert(project.diskConflict.map { "“\($0.fileName)” Changed on Disk" } ?? "", item: $project.diskConflict) { path in
                Button("Save Anyway") { project.answer(path, "save") }
                Button("Revert", role: .destructive) { project.answer(path, "revert") }
                Button("Cancel", role: .cancel) {
                    project.answer(path, "cancel", holding: String(localized: "Another app changed “\(path.fileName)”."))
                }
            } message: { path in
                Text("Another app changed “\(path)” while it has unsaved changes here.")
            }
    }

    private var promptTitle: String {
        switch app.prompt {
        case .gotoLine: String(localized: "Go to Line")
        case .gotoPage: String(localized: "Go to Page")
        case .rename(let symbol): String(localized: "Rename “\(symbol.name)”")
        case .saveVersion: String(localized: "Save Version")
        case nil: ""
        }
    }

    private func promptField(_ prompt: Prompt) -> String {
        switch prompt {
        case .gotoLine: String(localized: "Line number")
        case .gotoPage: project.pdf.pageCount > 0 ? "1–\(project.pdf.pageCount)" : String(localized: "Page number")
        case .rename: String(localized: "New Name")
        case .saveVersion: String(localized: "Name")
        }
    }

    private func promptAction(_ prompt: Prompt) -> String {
        switch prompt {
        case .rename: String(localized: "Rename")
        case .saveVersion: String(localized: "Save")
        case .gotoLine, .gotoPage: String(localized: "Go")
        }
    }

    private func answer(_ prompt: Prompt) {
        let text = promptText.trimmingCharacters(in: .whitespaces)
        switch prompt {
        case .gotoLine:
            guard let line = Int(text), line >= 1 else { return }
            app.showSource = true
            project.editor.reveal(line: min(line, project.editor.textView.document.lineCount))
        case .gotoPage:
            if let page = Int(text), page >= 1 { app.requestPDF(.goToPage(page)) }
        case .rename(let symbol):
            guard !text.isEmpty, text != symbol.name else { return }
            Task { await project.alerting("Couldn’t Rename “\(symbol.name)”") { try await project.renameSymbol(symbol, to: text) } }
        case .saveVersion:
            guard !text.isEmpty else { return }
            Task { await project.alerting("Couldn’t Save the Version") { try await project.saveVersion(named: text) } }
        }
    }
}
