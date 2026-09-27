import SwiftUI

/// An open project: files and outline in the sidebar; the source beside its
/// PDF, with a panel for the build below; and an inspector on the trailing
/// edge.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisible ? .all : .detailOnly },
            set: { app.sidebarVisible = $0 != .detailOnly }
        )) {
            NavigatorView(project: project)
                .navigationSplitViewColumnWidth(min: Metrics.sidebarWidth.lowerBound, ideal: Metrics.sidebarIdeal,
                                                max: Metrics.sidebarWidth.upperBound)
        } detail: {
            SplitController(app: app, axis: .horizontal, autosave: "InspectorSplit", panes: [
                SplitPane(minimum: Metrics.editorsMinWidth) { EditorArea(project: project) },
                SplitPane(minimum: Metrics.inspectorWidth.lowerBound, maximum: Metrics.inspectorWidth.upperBound,
                          fraction: 0.28, keepsSize: true, shown: app.showInspector) {
                    // On edge-to-edge system glass, as an inspector sits
                    // beside the content.
                    InspectorView(project: project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassEffect(.regular, in: .rect)
                },
            ])
            // Built once per project: its panes keep the views they were made with.
            .id(ObjectIdentifier(project))
            // Room for the inspector too, whether or not it shows: a minimum
            // that changed mid-layout crashed AppKit before. The height is the
            // window's minimum's (`WindowMetrics`).
            .frame(minWidth: Metrics.detailMinWidth)
            .onGeometryChange(for: RectangleCornerInsets.self) { $0.containerCornerInsets } action: {
                app.windowCorners = $0
            }
            // On the detail, as Apple's Landmarks sample has it: on the split
            // view itself the spacers were dropped and every item ran
            // together in one pill.
            .toolbar { toolbar }
            // No line under the toolbar, as Xcode has none over its jump
            // bar: the toolbar and the pane bars under it read as one strip,
            // and the system's automatic line came and went with resizes.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .navigationTitle(project.openPath.map { ($0 as NSString).lastPathComponent } ?? project.id)
        .navigationSubtitle(project.openPath == nil ? "" : project.id)
        // The open file as the window's represented document (proxy icon and
        // path menu), none rather than the disk's root while no file is open.
        // From a background, so the workspace keeps its identity (and its
        // panes) as the document comes and goes.
        .background {
            if let url = project.openURL { Color.clear.navigationDocument(url) }
        }
        .fileImporter(isPresented: $app.addingFiles, allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await project.importFiles(urls) }
            case .failure(let error): app.alert = AppAlert("Couldn’t Add the Files", error)
            }
        }
        .fileDialogConfirmationLabel("Add")
        .fileExporter(isPresented: Binding(presenting: $app.exporting), item: app.exporting,
                      contentTypes: app.exporting.map { [$0.type] } ?? [],
                      defaultFilename: app.exporting?.name) { [name = app.exporting?.name ?? ""] result in
            if case .failure(let error) = result { app.alert = AppAlert("Couldn’t Save “\(name)”", error) }
        }
        // Save PDF As… saves, as every Save As does; a zip is exported.
        .fileExporterFilenameLabel(app.exporting?.type == .pdf ? "Save As:" : "Export As:")
        .fileDialogConfirmationLabel(app.exporting?.type == .pdf ? "Save" : "Export")
        .sheet(item: $app.prompt) { prompt in
            switch prompt {
            case .newFile: NewEntrySheet(project: project, directory: false)
            case .newFolder: NewEntrySheet(project: project, directory: true)
            case .gotoLine: GoToLineSheet(project: project)
            }
        }
        // An import onto names already here: Finder's question and answers,
        // Replace the default.
        .alert(project.importClash?.title ?? "", isPresented: Binding(presenting: $project.importClash),
               presenting: project.importClash) { clash in
            Button("Replace") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "replace") } }
                .keyboardShortcut(.defaultAction)
            Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "keepBoth") } }
            Button("Stop", role: .cancel) {}
        } message: { clash in
            Text(clash.message)
        }
        // The open file changed on disk while it has edits here.
        .alert(project.diskConflict.map { "“\(($0 as NSString).lastPathComponent)” Changed on Disk" } ?? "",
               isPresented: Binding(presenting: $project.diskConflict), presenting: project.diskConflict) { _ in
            Button("Keep Editing", role: .cancel) { project.keepEdits() }
            // It discards the edits here: never the default button.
            Button("Revert", role: .destructive) { Task { await project.revertToDisk() } }
        } message: { path in
            Text("Another app changed \(path) while it has unsaved changes here. Revert to the version on disk, or keep editing and save over it.")
        }
        .task {
            for await note in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification) {
                // This window's only: closing Settings is no reason to save.
                guard (note.object as? NSWindow) === NSApp.projectWindow else { continue }
                // Its own task: the view's goes with the closing window.
                Task { await project.flush() }
            }
        }
    }

    /// The columns' widths. The sidebar's ideal is the UI kit's window
    /// sidebar; the window's own minimum (960 × 600) is set once, in the app.
    private enum Metrics {
        static let sidebarWidth: ClosedRange<CGFloat> = 200...320
        static let sidebarIdeal: CGFloat = 256
        /// The source and the PDF, side by side at their smallest.
        static let editorsMinWidth: CGFloat = 441
        static let inspectorWidth: ClosedRange<CGFloat> = 220...320
        /// The editors and the inspector at their smallest, and the
        /// divider between them.
        static let detailMinWidth = editorsMinWidth + 1 + inspectorWidth.lowerBound
    }

    // ---------- toolbar ----------

    /// Back and the file as the window's title at the leading edge, and the
    /// panes' toggles at the trailing. What acts on a pane sits over it
    /// instead: editing over the source (EditorView's `SourceBar`), compiling
    /// and sharing over the PDF (PDFPane's bar). Every item is in the menu
    /// bar too.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Back to the projects, as the web's and Windows' title bars lead
        // with it; otherwise only File › Close Project left a project.
        ToolbarItem(placement: .navigation) {
            Button { app.perform(.projectClose) } label: {
                Label("Projects", systemImage: "chevron.backward")
            }
            .help("Back to Projects")
        }

        // The panes' toggles, sharing one piece of glass as related buttons
        // do. Nothing here acts on the PDF alone: Share is the PDF bar's.
        ToolbarItem(placement: .primaryAction) { PDFToggle() }
        ToolbarItem(placement: .primaryAction) { InspectorToggle() }
    }
}

/// File › New File… and New Folder…: a name, and the folder to make it in
/// (the open file's to begin with), as a Save sheet asks.
private struct NewEntrySheet: View {
    let project: ProjectModel
    let directory: Bool
    @State private var name: String
    @State private var folder: String
    @FocusState private var nameFocused: Bool

    init(project: ProjectModel, directory: Bool) {
        self.project = project
        self.directory = directory
        _name = State(initialValue: directory ? "untitled folder" : "untitled.tex")
        _folder = State(initialValue: (project.openPath.map { ($0 as NSString).deletingLastPathComponent }) ?? "")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogSheet(title: directory ? "New Folder" : "New File", action: "Create",
                    enabled: !trimmed.isEmpty && !trimmed.hasPrefix("/")) {
            let path = folder.isEmpty ? trimmed : "\(folder)/\(trimmed)"
            Task { await project.createEntry(path, directory: directory) }
        } fields: {
            TextField("Name", text: $name)
                .focused($nameFocused)
            Picker("Where", selection: $folder) {
                Label(project.id, systemImage: "folder").tag("")
                ForEach(project.tree.flattened.filter(\.isDirectory).map(\.path), id: \.self) { path in
                    Label(path, systemImage: "folder").tag(path)
                }
            }
        }
        .onAppear { nameFocused = true }
    }
}

/// Edit › Go to Line…: a line of the open file.
private struct GoToLineSheet: View {
    let project: ProjectModel
    @State private var text = ""

    private var lines: Int? { project.counts?.lines }

    private var line: Int? {
        guard let line = Int(text.trimmingCharacters(in: .whitespaces)), line >= 1 else { return nil }
        return lines.map { min(line, $0) } ?? line
    }

    var body: some View {
        DialogSheet(title: "Go to Line", action: "Go", enabled: line != nil) {
            if let line { project.reveal(line: line) }
        } fields: {
            TextField("Line", text: $text, prompt: Text(lines.map { "1–\($0)" } ?? "Line number"))
        }
    }
}

/// Shows and hides the PDF, as View › Hide PDF does. A plain button whose
/// title says what it will do, as the sidebar's toggle and Xcode's
/// inspector button are: a toggle draws its on state accent-filled, which
/// made the two toggles the toolbar's loudest controls.
private struct PDFToggle: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let title = app.title(.viewTogglePdf)
        Button(title, systemImage: "doc.richtext") { app.perform(.viewTogglePdf) }
            .help(title)
    }
}

/// Shows and hides the inspector, as View › Hide Inspector does.
private struct InspectorToggle: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let title = app.showInspector ? "Hide Inspector" : "Show Inspector"
        Button(title, systemImage: "sidebar.trailing") { app.showInspector.toggle() }
            .help(title)
    }
}

/// The trailing inspector: the project's build settings, then facts about
/// the open file and the PDF — what the web kept in its settings popover and
/// status line, gathered where a Mac app keeps them.
struct InspectorView: View {
    @Bindable var project: ProjectModel

    var body: some View {
        // Label-and-value rows straight on the pane's glass, as Xcode's
        // inspector has them: a bold title per section, a hairline between
        // sections, labels right-aligned in one column. Grouped boxes read
        // as a layer of their own on glass.
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: BarMetrics.groupSpacing,
                 verticalSpacing: BarMetrics.groupSpacing) {
                header("Project")
                let texFiles = project.tree.flattened.filter { !$0.isDirectory && $0.path.hasSuffix(".tex") }.map(\.path)
                pickerRow("Main File", project.settings?.mainFile ?? "", texFiles.map { ($0, $0) }, set: project.setMainFile)
                pickerRow("Engine", project.settings?.engine ?? "pdflatex", texEngines, set: project.setEngine)
                toggleRow("Shell Escape", "Lets packages such as minted run programs. Only for projects you trust.",
                          project.settings?.shellEscape ?? false, set: project.setShellEscape)
                toggleRow("Stop on First Error", "Ends the build at its first error, rather than showing them all.",
                          project.settings?.stopOnFirstError ?? false, set: project.setStopOnFirstError)
                if let path = project.openPath {
                    separator
                    header("Document")
                    row("Name", (path as NSString).lastPathComponent)
                    row("Folder", folder(of: path))
                    if let counts = project.counts {
                        row("Words", counts.words.formatted())
                        row("Lines", counts.lines.formatted())
                    }
                    if !project.outline.isEmpty {
                        row("Sections", project.outline.count.formatted())
                    }
                }
                separator
                header("Build")
                if let result = project.result {
                    row("Last Build", result.stopped ? "Stopped" : result.ok ? "Succeeded" : "Failed")
                    row("Duration", result.durationText)
                    row("Errors", project.errorCount.formatted())
                    row("Warnings", project.warningCount.formatted())
                } else {
                    // The status bar's phrase, shortened to fit beside its
                    // label in a narrow inspector.
                    row("Last Build", project.pdfVersion > 0 ? "None Yet" : "None")
                }
                if let freshness = project.pdfFreshness {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Label(freshness.title, systemImage: freshness.systemImage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(project.settings == nil)
            .monospacedDigit()
            .padding(BarMetrics.inset * 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(Typography.groupTitle).gridCellColumns(2)
    }

    private var separator: some View {
        Divider().gridCellColumns(2).padding(.vertical, BarMetrics.spacing)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    /// A setting's pop-up at its own width, as Xcode's inspectors have them.
    private func pickerRow(_ title: String, _ value: String, _ options: [(String, String)],
                           set: @escaping (String) async -> Void) -> some View {
        GridRow {
            label(title)
            Picker(title, selection: Binding(get: { value }, set: { new in Task { await set(new) } })) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// A setting's checkbox under the pop-ups, its description beneath it.
    private func toggleRow(_ title: String, _ detail: String, _ isOn: Bool,
                           set: @escaping (Bool) async -> Void) -> some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Toggle(isOn: Binding(get: { isOn }, set: { on in Task { await set(on) } })) {
                Text(title)
                Text(detail)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            label(name)
            Text(value).textSelection(.enabled)
        }
    }

    private func folder(of path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? project.id : dir
    }
}
