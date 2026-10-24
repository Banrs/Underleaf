import AppKit
import SwiftUI

struct WorkspaceModals: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            .modifier(ProjectDialogs(project: project))
            .sheet(item: $app.prompt) { prompt in
                switch prompt {
                case .gotoPage:
                    GoToSheet(noun: "Page", limit: { project.pdf.pageCount > 0 ? project.pdf.pageCount : nil }) {
                        app.requestPDF(.goToPage($0))
                    }
                case .gotoLine:
                    // A jump, as Xcode's, which Go Back returns from.
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

    /// No default button, as either answer loses a version (HIG, Alerts): AppKit's, as SwiftUI's alert always has one.
    private func askWhichVersion(of path: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(path.fileName)” Changed on Disk")
        alert.informativeText = String(localized: "Another app changed “\(path)” while it has unsaved changes here.")
        // The first button has Return until it gives it up; Cancel has Escape.
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

    /// From the text as typed: a number field tells its binding only as editing ends.
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

/// As Xcode's Refactor ▸ Rename, for a label or a citation in every file. The field's text is selected as it takes the focus.
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
