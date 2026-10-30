import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceModals: ViewModifier {
    @Environment(WindowModel.self) private var window
    @Environment(WorkspaceViews.self) private var views
    @Bindable var project: ProjectModel

    func body(content: Content) -> some View {
        @Bindable var window = window
        content
            .background {
                Color.clear
                    .fileImporter(isPresented: Binding(get: { window.addingFiles && !project.closed }, set: { window.addingFiles = $0 }),
                                  allowedContentTypes: [.item, .folder],
                                  allowsMultipleSelection: true) { result in
                        switch result {
                        case .success(let urls): Task { await project.importFiles(urls) }
                        case .failure(let error): window.report("Couldn’t Add the Files", error)
                        }
                    }
                    .fileDialogConfirmationLabel("Add")
            }
            .background {
                Color.clear
                    .fileExporter(isPresented: Binding(get: { window.exporting != nil }, set: { if !$0 { window.exporting = nil } }),
                                  item: window.exporting,
                                  contentTypes: window.exporting.map { [$0.type] } ?? [],
                                  defaultFilename: window.exporting?.name) { [name = window.exporting?.name ?? ""] result in
                        if case .failure(let error) = result { window.report("Couldn’t Save “\(name)”", error) }
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
            .alert(project.conflicts.first.map { $0.kind == .changed ? "“\($0.path.fileName)” Changed on Disk"
                                                                     : "“\($0.path.fileName)” Was Moved or Deleted" } ?? "",
                   item: Binding(get: { project.conflicts.first }, set: { _ in })) { asked in
                switch asked.kind {
                case .changed:
                    Button("Save Anyway") { project.answer(asked.path, .save) }
                    Button("Revert", role: .destructive) { project.answer(asked.path, .revert) }
                case .gone:
                    Button("Save Again") { project.answer(asked.path, .save) }
                    Button("Discard Changes", role: .destructive) { project.answer(asked.path, .close) }
                }
                Button("Cancel", role: .cancel) { project.answer(asked.path, .cancel) }
            } message: { asked in
                Text(asked.kind == .changed ? "Another app changed “\(asked.path)” while it has unsaved changes here."
                     : "Another app moved or deleted “\(asked.path)”, which has unsaved changes here.")
            }
            .alert("Close “\(project.name)” Without Saving?", isPresented: Binding(get: { project.askingToDiscard != nil }, set: { _ in })) {
                Button("Close Without Saving", role: .destructive) { project.answerDiscard(true) }
                Button("Cancel", role: .cancel) { project.answerDiscard(false) }
            } message: {
                let files = (project.askingToDiscard ?? []).map { "“\($0.fileName)”" }.formatted(.list(type: .and))
                Text("TeXLocal stopped after an internal error and couldn’t save \(files). Copy out what you need first.")
            }
            .sheet(item: $window.prompt) { prompt in
                switch prompt {
                case .gotoPage:
                    GoToSheet(noun: "Page", limit: { views.pdf.pageCount > 0 ? views.pdf.pageCount : nil }) {
                        window.requestPDF(.goToPage($0))
                    }
                case .gotoLine:
                    GoToSheet(noun: "Line", limit: { views.lineCount }) { line in
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
            DialogField(label: noun, text: $text, prompt: limit().map { "1–\($0)" } ?? "\(noun) number", focus: $focused)
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
        DialogSheet(title: "Rename “\(name)”", action: "Rename", enabled: !text.isEmpty && text != name) {
            try await rename(text)
        } fields: {
            DialogField(label: "New Name", text: $text, focus: $focused)
        }
        .defaultFocus($focused, true)
    }
}
