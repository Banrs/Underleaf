import SwiftUI
import UniformTypeIdentifiers

/// What the project asks alike on both: files to add or a place to export to, files added over others of their names,
/// and a file with unsaved edits moved or deleted by another app.
struct ProjectDialogs: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            // Each file dialog in a host of its own, which keeps its labels.
            .background {
                Color.clear
                    // Not from a project left for another, still showing while the next loads.
                    .fileImporter(isPresented: Binding(get: { app.addingFiles && !project.closed }, set: { app.addingFiles = $0 }),
                                  allowedContentTypes: [.item, .folder],
                                  allowsMultipleSelection: true) { result in
                        switch result {
                        case .success(let urls): Task { await project.importFiles(urls) }
                        case .failure(let error): app.alert = AppAlert("Couldn’t Add the Files", error)
                        }
                    }
                    #if os(macOS)
                    .fileDialogConfirmationLabel("Add")
                    #endif
            }
            .background {
                Color.clear
                    .fileExporter(isPresented: Binding(get: { app.exporting != nil }, set: { if !$0 { app.exporting = nil } }),
                                  item: app.exporting,
                                  contentTypes: app.exporting.map { [$0.type] } ?? [],
                                  defaultFilename: app.exporting?.name) { [name = app.exporting?.name ?? ""] result in
                        if case .failure(let error) = result { app.alert = AppAlert("Couldn’t Save “\(name)”", error) }
                    }
                    #if os(macOS)
                    .fileExporterFilenameLabel("Export As:")
                    .fileDialogConfirmationLabel("Export")
                    #endif
            }
            .alert(project.importClash?.title ?? "", item: $project.importClash) { clash in
                // Keep Both, which loses nothing, is the default, as in Finder's.
                Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "keepBoth") } }
                Button("Replace", role: .destructive) { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "replace") } }
                Button("Cancel", role: .cancel) {}
            } message: { clash in
                Text(clash.message)
            }
            .alert(project.missingFile.map { "“\($0.fileName)” Was Moved or Deleted" } ?? "",
                   item: $project.missingFile) { path in
                // Return saves: the button that discards the edits is never the default.
                Button("Save Again") { project.answer(path, "save") }
                Button("Discard Changes", role: .destructive) { project.answer(path, "close") }
                Button("Cancel", role: .cancel) {
                    project.answer(path, "cancel", holding: String(localized: "Another app moved or deleted “\(path.fileName)”."))
                }
            } message: { path in
                Text("Another app moved or deleted “\(path)”, which has unsaved changes here.")
            }
    }
}
