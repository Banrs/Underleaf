import SwiftUI

extension View {
    /// The open project's sheets, alerts and file dialogs, on the source column:
    /// the one pane that always shows.
    func workspaceModals(_ project: ProjectModel) -> some View {
        modifier(WorkspaceModals(project: project))
    }
}

private struct WorkspaceModals: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            // Each file dialog on a view of its own: a dialog's labels reach every
            // dialog presented from the view they're set on.
            .background {
                Color.clear
                    .fileImporter(isPresented: $app.addingFiles, allowedContentTypes: [.item, .folder],
                                  allowsMultipleSelection: true) { result in
                        switch result {
                        case .success(let urls): Task { await project.importFiles(urls) }
                        case .failure(let error): app.alert = AppAlert("Couldn’t Add the Files", error)
                        }
                    }
                    .fileDialogConfirmationLabel("Add")
            }
            .background {
                Color.clear
                    .fileExporter(isPresented: Binding(presenting: $app.exporting), item: app.exporting,
                                  contentTypes: app.exporting.map { [$0.type] } ?? [],
                                  defaultFilename: app.exporting?.name) { [name = app.exporting?.name ?? ""] result in
                        if case .failure(let error) = result { app.alert = AppAlert("Couldn’t Save “\(name)”", error) }
                    }
                    // Save PDF As… saves; a zip is exported.
                    .fileExporterFilenameLabel(app.exporting?.type == .pdf ? "Save As:" : "Export As:")
                    .fileDialogConfirmationLabel(app.exporting?.type == .pdf ? "Save" : "Export")
            }
            .sheet(item: $app.prompt) { prompt in
                switch prompt {
                case .newFile: NewEntrySheet(project: project, directory: false)
                case .newFolder: NewEntrySheet(project: project, directory: true)
                case .gotoLine: GoToLineSheet(project: project)
                case .gotoPage: GoToPageSheet(project: project)
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

/// Edit › Go to Page…, and the page in the PDF's status bar.
private struct GoToPageSheet: View {
    @Environment(AppModel.self) private var app
    let project: ProjectModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var pages: Int? { project.pdfPageCount > 0 ? project.pdfPageCount : nil }

    private var page: Int? {
        guard let page = Int(text.trimmingCharacters(in: .whitespaces)), page >= 1 else { return nil }
        return pages.map { min(page, $0) } ?? page
    }

    var body: some View {
        DialogSheet(title: "Go to Page", action: "Go", enabled: page != nil) {
            if let page { app.requestPDF(.goToPage(page)) }
        } fields: {
            TextField("Page", text: $text, prompt: Text(pages.map { "1–\($0)" } ?? "Page number"))
                .focused($focused)
        }
        .defaultFocus($focused, true)
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
