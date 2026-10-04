import SwiftUI

/// Workspace sheets, alerts, and file dialogs on the always-visible source column.
struct WorkspaceModals: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            // Separate hosts keep each file dialog's labels with its own panel.
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
                case .gotoPage:
                    GoToSheet(noun: "Page", limit: { project.pdf.pageCount > 0 ? project.pdf.pageCount : nil }) {
                        app.requestPDF(.goToPage($0))
                    }
                case .gotoLine:
                    GoToSheet(noun: "Line", limit: { project.editor.textView.document.lineCount }) {
                        project.editor.reveal(line: $0)
                    }
                }
            }
            .alert(project.importClash?.title ?? "", item: $project.importClash) { clash in
                // Keep Both, which loses nothing, is the default, as in Finder's copy alert;
                // Replace trashes the item here.
                Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "keepBoth") } }
                Button("Replace", role: .destructive) { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "replace") } }
                Button("Cancel", role: .cancel) {}
            } message: { clash in
                Text(clash.message)
            }
            .alert(project.diskConflict.map { "“\($0.fileName)” Changed on Disk" } ?? "",
                   item: $project.diskConflict) { path in
                // In both alerts, the button that discards the edits is never the default: Return keeps them.
                Button("Keep Editing", role: .cancel) { project.keepEdits() }
                Button("Revert", role: .destructive) { Task { await project.revertToDisk(path) } }
            } message: { path in
                Text("Another app changed \(path) while it has unsaved changes here. Revert to the version on disk, or keep editing and save over it.")
            }
            .alert(project.missingFile.map { "“\($0.fileName)” Was Moved or Deleted" } ?? "",
                   item: $project.missingFile) { _ in
                Button("Save Again") { project.saveMissingFile() }
                Button("Discard Changes", role: .destructive) { project.closeMissingFile() }
            } message: { path in
                Text("Another app moved or deleted \(path), which has unsaved changes here. Save them to make the file again, or discard them and close it.")
            }
    }
}

/// Go to Line… and Go to Page…, also from the status bar: a sheet, as Preview's Go to
/// Page. A number past the end goes to the last. `limit` is read as the sheet draws, so
/// a build finishing meanwhile counts.
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
