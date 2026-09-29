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
                    .fileExporter(isPresented: Binding(get: { app.exporting != nil }, set: { if !$0 { app.exporting = nil } }),
                                  item: app.exporting,
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
                case .newFile(let folder): NewEntrySheet(project: project, directory: false, folder: folder)
                case .newFolder(let folder): NewEntrySheet(project: project, directory: true, folder: folder)
                case .gotoLine: GoToSheet(noun: "Line", limit: { project.counts?.lines }) { project.reveal(line: $0) }
                case .gotoPage:
                    GoToSheet(noun: "Page", limit: { project.pdfPageCount > 0 ? project.pdfPageCount : nil }) {
                        app.requestPDF(.goToPage($0))
                    }
                }
            }
            .alert(project.importClash?.title ?? "", item: $project.importClash) { clash in
                Button("Replace") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "replace") } }
                    .keyboardShortcut(.defaultAction)
                Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "keepBoth") } }
                Button("Cancel", role: .cancel) {}
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

    init(project: ProjectModel, directory: Bool, folder: String?) {
        self.project = project
        self.directory = directory
        _name = State(initialValue: directory ? "untitled folder" : "untitled.tex")
        _folder = State(initialValue: folder ?? project.openPath.map { ($0 as NSString).deletingLastPathComponent } ?? "")
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

/// Edit › Go to Line… and Go to Page…; the page also from the status bar.
/// `limit` is read as the sheet draws, so a build finishing meanwhile counts.
private struct GoToSheet: View {
    let noun: String
    let limit: () -> Int?
    let go: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var number: Int? {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)), number >= 1 else { return nil }
        return limit().map { min(number, $0) } ?? number
    }

    var body: some View {
        DialogSheet(title: "Go to \(noun)", action: "Go", enabled: number != nil) {
            if let number { go(number) }
        } fields: {
            TextField(noun, text: $text, prompt: Text(limit().map { "1–\($0)" } ?? "\(noun) number"))
                .focused($focused)
        }
        .defaultFocus($focused, true)
    }
}
