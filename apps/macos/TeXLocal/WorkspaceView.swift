import SwiftUI

/// An open project: sidebar | source | PDF, each column's tools in the toolbar over it.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: Binding(
            // With three columns, hiding the sidebar alone is "double column".
            get: { app.sidebarVisible ? .all : .doubleColumn },
            set: { app.sidebarVisible = $0 == .all }
        )) {
            NavigatorView(project: project)
                // Once per project: its panes keep the views they were made with.
                .id(ObjectIdentifier(project))
                .navigationSplitViewColumnWidth(min: ColumnMetrics.sidebarWidth.lowerBound,
                                                ideal: ColumnMetrics.sidebarIdeal,
                                                max: ColumnMetrics.sidebarWidth.upperBound)
        } content: {
            EditorArea(project: project)
                .id(ObjectIdentifier(project))
                .navigationSplitViewColumnWidth(min: ColumnMetrics.sourceMinimum, ideal: ColumnMetrics.ideal)
        } detail: {
            // Collapsed while hidden, never rebuilt (`PDFColumn`).
            PDFPane(project: project)
                .id(ObjectIdentifier(project))
                .navigationSplitViewColumnWidth(min: ColumnMetrics.pdfMinimum, ideal: ColumnMetrics.ideal)
        }
        .navigationTitle(project.openPath.map { ($0 as NSString).lastPathComponent } ?? project.id)
        .navigationSubtitle(project.openPath == nil ? "" : project.id)
        // From a background, so the workspace keeps its identity as the document comes and goes.
        .background {
            if let url = project.openURL { Color.clear.navigationDocument(url) }
        }
        .background { FindMenuTarget(project: project) }
        // At the root: the columns are hosted apart, each in the split's own controller.
        .focusedSceneValue(project)
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
        // Save PDF As… saves; a zip is exported.
        .fileExporterFilenameLabel(app.exporting?.type == .pdf ? "Save As:" : "Export As:")
        .fileDialogConfirmationLabel(app.exporting?.type == .pdf ? "Save" : "Export")
        .sheet(item: $app.prompt) { prompt in
            switch prompt {
            case .newFile: NewEntrySheet(project: project, directory: false)
            case .newFolder: NewEntrySheet(project: project, directory: true)
            case .gotoLine: GoToLineSheet(project: project)
            }
        }
        .alert(project.importClash?.title ?? "", item: $project.importClash) { clash in
            Button("Replace") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "replace") } }
                .keyboardShortcut(.defaultAction)
            Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "keepBoth") } }
            Button("Stop", role: .cancel) {}
        } message: { clash in
            Text(clash.message)
        }
        .alert(project.diskConflict.map { "“\(($0 as NSString).lastPathComponent)” Changed on Disk" } ?? "",
               item: $project.diskConflict) { _ in
            Button("Keep Editing", role: .cancel) { project.keepEdits() }
            // It discards the edits: never the default button.
            Button("Revert", role: .destructive) { Task { await project.revertToDisk() } }
        } message: { path in
            Text("Another app changed \(path) while it has unsaved changes here. Revert to the version on disk, or keep editing and save over it.")
        }
        .alert(project.missingFile.map { "“\(($0 as NSString).lastPathComponent)” Was Moved or Deleted" } ?? "",
               item: $project.missingFile) { _ in
            // The default button: Return keeps the edits.
            Button("Save Again") { project.saveMissingFile() }
            // It discards the edits: never the default button.
            Button("Close", role: .destructive) { project.closeMissingFile() }
        } message: { path in
            Text("Another app moved or deleted \(path), which has unsaved changes here. Save them to make the file again, or close it and discard them.")
        }
    }
}

/// Column widths. Each minimum is its content's: the toolbar is the system's to
/// fit, its tools crossing a divider or going into its overflow menu (as Mail's).
enum ColumnMetrics {
    static let sidebarWidth: ClosedRange<CGFloat> = 200...320
    /// UI kit: the window sidebar is 256 pt.
    static let sidebarIdeal: CGFloat = 256
    /// About 40 columns of the editor's default font.
    static let sourceMinimum: CGFloat = 320
    /// A page still legible, fitted to the width.
    static let pdfMinimum: CGFloat = 280
    /// The window's content at its narrowest (one pt per divider).
    static let contentMinimumWidth = sidebarWidth.lowerBound + sourceMinimum + pdfMinimum + 2
    /// Half each of the default window's room past the sidebar.
    static var ideal: CGFloat { (WindowMetrics.projectDefault.width - sidebarIdeal) / 2 }
}

extension NSView {
    /// The split item whose view controller holds this view; nil until it's in one.
    var splitViewItem: NSSplitViewItem? {
        let controller = sequence(first: self as NSResponder, next: \.nextResponder)
            .lazy.compactMap { $0 as? NSViewController }
            .first { $0.parent is NSSplitViewController }
        guard let controller, let split = controller.parent as? NSSplitViewController else { return nil }
        return split.splitViewItem(for: controller)
    }
}

/// File › New File… and New Folder…: a name, and the folder to make it in.
private struct NewEntrySheet: View {
    let project: ProjectModel
    let directory: Bool
    @State private var name: String
    @State private var folder: String
    @FocusState private var nameFocused: Bool
    @State private var selection: TextSelection?

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
            TextField("Name", text: $name, selection: $selection)
                .focused($nameFocused)
                .onChange(of: nameFocused) { _, now in
                    if now, !directory { selection = .baseName(of: name) }
                }
            Picker("Where", selection: $folder) {
                Label(project.id, systemImage: "folder").tag("")
                ForEach(project.tree.flattened.filter(\.isDirectory).map(\.path), id: \.self) { path in
                    Label(path, systemImage: "folder").tag(path)
                }
            }
        }
        .defaultFocus($nameFocused, true)
    }
}

/// Edit › Go to Line…
private struct GoToLineSheet: View {
    let project: ProjectModel
    @State private var text = ""
    @FocusState private var focused: Bool

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
                .focused($focused)
        }
        .defaultFocus($focused, true)
    }
}

/// Shows and hides the PDF. A document's symbol: the PDF is the source's peer,
/// not a sidebar or an inspector.
struct PDFToggle: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        let title = app.title(.viewTogglePdf, on: project)
        Button(title, systemImage: "doc.richtext") { app.perform(.viewTogglePdf, on: project) }
            .help(title)
    }
}

/// Opens the Project Settings popover; View › Show Project Settings does too.
struct ProjectSettingsButton: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel

    var body: some View {
        @Bindable var app = app
        Button("Project Settings", systemImage: "info.circle") { app.showProjectSettings.toggle() }
            .help("Project Settings")
            .popover(isPresented: $app.showProjectSettings, arrowEdge: .bottom) {
                ProjectSettingsView(project: project)
            }
    }
}

/// Edit › Find's items for the pane with the keyboard, else the source's. Its
/// own view, so a focus change redraws it alone.
private struct FindMenuTarget: View {
    let project: ProjectModel
    @FocusedValue(\.find) private var find

    var body: some View {
        FindMenuResponder(find: find ?? project.findAction)
    }
}

/// The project's build settings, then facts about the open file and the build.
struct ProjectSettingsView: View {
    @Bindable var project: ProjectModel

    /// Room for the pop-ups; the toggles' descriptions wrap.
    private static let width: CGFloat = 320

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: BarMetrics.groupSpacing,
             verticalSpacing: BarMetrics.groupSpacing) {
            header("Project")
            let texFiles = project.tree.flattened.filter { !$0.isDirectory && $0.path.hasSuffix(".tex") }.map(\.path)
            pickerRow("Main File", project.settings?.mainFile ?? "", texFiles.map { ($0, $0) }, set: project.setMainFile)
            pickerRow("Engine", project.settings?.engine ?? "", texEngines, set: project.setEngine)
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
        // Settings arrive from the core after the popover opens.
        .disabled(project.settings == nil)
        .monospacedDigit()
        .padding()
        .frame(width: Self.width, alignment: .leading)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Typography.groupTitle)
            .accessibilityAddTraits(.isHeader)
            .gridCellColumns(2)
    }

    private var separator: some View {
        Divider().gridCellColumns(2).padding(.vertical, BarMetrics.spacing)
    }

    /// Read out with its value or control, not as an element of its own.
    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .accessibilityHidden(true)
    }

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

    private func toggleRow(_ title: String, _ detail: String, _ isOn: Bool,
                           set: @escaping (Bool) async -> Void) -> some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Toggle(isOn: Binding(get: { isOn }, set: { on in Task { await set(on) } })) {
                Text(title)
                Text(detail)
            }
            // Wraps at the popover's width rather than truncating.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            label(name)
            Text(value)
                .textSelection(.enabled)
                .accessibilityLabel(name)
                .accessibilityValue(value)
        }
    }

    private func folder(of path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? project.id : dir
    }
}
