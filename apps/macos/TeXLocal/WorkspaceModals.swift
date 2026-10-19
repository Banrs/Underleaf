import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceModals: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            // Separate hosts keep each file dialog's labels with its own panel.
            .background {
                Color.clear
                    // Not from a project left for another, which still shows while the next loads.
                    .fileImporter(isPresented: Binding(get: { app.addingFiles && !project.closed }, set: { app.addingFiles = $0 }),
                                  allowedContentTypes: [.item, .folder],
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
                    .fileExporterFilenameLabel("Export As:")
                    .fileDialogConfirmationLabel("Export")
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
                // Keep Both, which loses nothing, is the default, as in Finder's copy alert.
                Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "keepBoth") } }
                Button("Replace", role: .destructive) { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: "replace") } }
                Button("Cancel", role: .cancel) {}
            } message: { clash in
                Text(clash.message)
            }
            .onChange(of: project.diskConflict) { _, path in if let path { askWhichVersion(of: path) } }
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

    /// The Changed on Disk alert, where either answer loses a version, has no default button, so that Return chooses neither
    /// unread (HIG, Alerts). It is AppKit's own: SwiftUI's alert can move its default button but has no way to have none.
    private func askWhichVersion(of path: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(path.fileName)” Changed on Disk")
        alert.informativeText = String(localized: "Another app changed “\(path)” while it has unsaved changes here.")
        // An alert's first button has Return until it gives it up; one titled Cancel has Escape.
        alert.addButton(withTitle: String(localized: "Save Anyway")).keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Revert")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        let answered = { [project] (response: NSApplication.ModalResponse) in
            switch response {
            case .alertFirstButtonReturn: project.answer(path, "save")
            case .alertSecondButtonReturn: project.answer(path, "revert")
            default: project.answer(path, "cancel", holding: String(localized: "Another app changed “\(path.fileName)”."))
            }
        }
        if let window = project.editor.textView.window {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }
}

/// `limit` is read as the sheet draws, so a build finishing meanwhile counts.
private struct GoToSheet: View {
    let noun: String
    let limit: () -> Int?
    let go: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    /// Read from the text as it is typed: a field of a number's own tells its binding only as editing ends, and Go would wait for a first Return.
    private var number: Int? {
        guard let number = try? Int(text.trimmingCharacters(in: .whitespaces), format: .number.grouping(.never)),
              number >= 1 else { return nil }
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
