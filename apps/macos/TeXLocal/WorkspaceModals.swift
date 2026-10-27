import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceModals: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            .background {
                Color.clear
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
            .alert(project.importClash?.title ?? "", item: $project.importClash) { clash in
                Button("Keep Both") { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: .keepBoth) } }
                Button("Replace", role: .destructive) { Task { await project.importFiles(clash.urls, into: clash.dir, conflict: .replace) } }
                Button("Cancel", role: .cancel) {}
            } message: { clash in
                Text(clash.message)
            }
            .alert(project.missingFile.map { "“\($0.fileName)” Was Moved or Deleted" } ?? "",
                   item: $project.missingFile) { path in
                Button("Save Again") { project.answer(path, .save) }
                Button("Discard Changes", role: .destructive) { project.answer(path, .close) }
                Button("Cancel", role: .cancel) {
                    project.answer(path, .cancel, holding: String(localized: "Another app moved or deleted “\(path.fileName)”."))
                }
            } message: { path in
                Text("Another app moved or deleted “\(path)”, which has unsaved changes here.")
            }
            .sheet(item: $app.prompt) { prompt in
                switch prompt {
                case .gotoPage:
                    GoToSheet(noun: "Page", limit: { project.pdf.pageCount > 0 ? project.pdf.pageCount : nil }) {
                        app.requestPDF(.goToPage($0))
                    }
                case .gotoLine:
                    GoToSheet(noun: "Line", limit: { project.editor.textView.document.lineCount }) { line in
                        if let path = project.openPath { Task { await project.open(path, line: line, jump: true) } }
                    }
                case .rename(let symbol):
                    RenameSheet(name: symbol.name) { try await project.renameSymbol(symbol, to: $0) }
                case .saveVersion:
                    SaveVersionSheet(project: project)
                case .versionHistory:
                    VersionHistorySheet(project: project)
                }
            }
            .onChange(of: project.diskConflict) { _, path in if let path { askWhichVersion(of: path) } }
    }

    private func askWhichVersion(of path: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(path.fileName)” Changed on Disk")
        alert.informativeText = String(localized: "Another app changed “\(path)” while it has unsaved changes here.")
        alert.addButton(withTitle: String(localized: "Save Anyway")).keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Revert")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        let answered = { [project] (response: NSApplication.ModalResponse) in
            switch response {
            case .alertFirstButtonReturn: project.answer(path, .save)
            case .alertSecondButtonReturn: project.answer(path, .revert)
            default: project.answer(path, .cancel, holding: String(localized: "Another app changed “\(path.fileName)”."))
            }
        }
        if let window = project.editor.textView.window {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }
}

private struct GoToSheet: View {
    let noun: String
    let limit: () -> Int?
    let go: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

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

private struct RenameSheet: View {
    let name: String
    let rename: (String) async throws -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(name: String, rename: @escaping (String) async throws -> Void) {
        (self.name, self.rename) = (name, rename)
        _text = State(initialValue: name)
    }

    var body: some View {
        DialogSheet(title: "Rename “\(name)”", action: "Rename", enabled: !text.isEmpty && text != name,
                    failure: { "Couldn’t Rename “\(name)”" }) {
            try await rename(text)
        } fields: {
            TextField("New Name", text: $text)
                .focused($focused)
        }
        .defaultFocus($focused, true)
    }
}
