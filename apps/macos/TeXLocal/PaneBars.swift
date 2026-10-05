import SwiftUI

/// The PDF's find bar, its field taking the keyboard as it appears.
struct FindBar: View {
    @Binding var query: String
    let prompt: String
    let field: FieldHandle
    /// Where the field passes Edit › Find's items (`FindPassingTextView`).
    var findTarget: SyncPDFView?
    let matches: FindMatches
    /// The query the matches are for, which the count reads.
    let searched: String
    let step: @MainActor (Int) -> Void
    let close: @MainActor () -> Void

    var body: some View {
        HStack {
            SearchField(text: $query, prompt: prompt, handle: field, findTarget: findTarget, step: step, close: close)
                .frame(minWidth: 100, maxWidth: .infinity)
            ControlGroup {
                Button("Previous Match", systemImage: "chevron.backward") { step(-1) }
                    .help("Previous Match")
                Button("Next Match", systemImage: "chevron.forward") { step(1) }
                    .help("Next Match")
            }
            .disabled(matches.total == 0)
            .fixedSize()
            // The first to give way in a narrow pane.
            Text(matches.label(for: searched))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .layoutPriority(-1)
            Button("Done") { close() }
        }
        .lineLimit(1)
        // A turn later, once AppKit has made the field.
        .onAppear { Task { field.focus() } }
    }
}

/// Match index starts at 1 (0 for no selected match); `limited` means more exist.
struct FindMatches: Equatable {
    var index = 0
    var total = 0
    var limited = false

    func label(for query: String) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return String(localized: "Not found") }
        let count = "\(total.formatted())\(limited ? "+" : "")"
        if index > 0 { return String(localized: "\(index) of \(count)") }
        if limited { return String(localized: "\(count) matches") }
        return String(AttributedString(localized: "^[\(total) match](inflect: true)").characters)
    }
}

/// A field to focus once AppKit has made it.
final class FieldHandle {
    fileprivate(set) weak var field: NSTextField?

    /// With its text selected, to type over.
    func focus() {
        guard let field, let window = field.window else { return }
        if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        field.currentEditor()?.selectAll(nil)
    }

    var hasFocus: Bool {
        guard let field, let first = field.window?.firstResponder else { return false }
        return first === field || first === field.currentEditor()
    }
}

/// A native search field with optional Return and Escape actions.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    /// In the magnifying glass's place: a filter's, as Xcode's filter fields.
    var symbol: String?
    var handle: FieldHandle?
    var findTarget: SyncPDFView?
    var step: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: SearchField

        init(_ field: SearchField) { self.field = field }

        // Typing and the native clear button both send the action.
        @objc func changed(_ sender: NSSearchField) {
            if field.text != sender.stringValue { field.text = sender.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Let the input method commit or cancel marked text before the find
            // bar treats Return and Escape as navigation commands.
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard let step = field.step else { return false }
                step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let close = field.close else { return false }
                close()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let view = findTarget == nil ? NSSearchField() : FindField()
        view.sendsSearchStringImmediately = true
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.action = #selector(Coordinator.changed(_:))
        if let symbol, let cell = view.cell as? NSSearchFieldCell {
            cell.searchButtonCell?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        handle?.field = view
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        context.coordinator.field = self
        (view.cell as? FindFieldCell)?.editor.pdf = findTarget
        view.placeholderString = prompt
        // VoiceOver's name: the placeholder goes once there's text.
        view.setAccessibilityLabel(prompt)
        // A SwiftUI update can arrive during input-method composition; writing
        // the bound query back then would discard the marked characters.
        if view.stringValue != text, (view.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            view.stringValue = text
        }
    }
}

/// The PDF find bar's field, whose editor passes Edit › Find's items to the PDF.
private final class FindField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { FindFieldCell.self }
        set {}
    }
}

private final class FindFieldCell: NSSearchFieldCell {
    let editor: FindPassingTextView = {
        let editor = FindPassingTextView()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/// A field editor that passes Edit › Find to the PDF: the field isn't inside the PDF view,
/// so the responder chain wouldn't reach it, and a text view would answer itself.
final class FindPassingTextView: NSTextView {
    weak var pdf: SyncPDFView?

    override func performFindPanelAction(_ sender: Any?) {
        pdf?.performFindPanelAction(sender)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(NSTextView.performFindPanelAction(_:)) else { return super.validateMenuItem(item) }
        return pdf?.validatesFind(item) ?? false
    }
}

struct DialogSheet<Fields: View>: View {
    let title: String
    var message: String?
    let action: String
    let enabled: Bool
    /// The alert's title if `submit` throws: the sheet stays, with what was typed. Read
    /// then: the toolbar keeps the button's action from its last change of state.
    var failure: () -> String = { "" }
    let submit: () async throws -> Void
    @ViewBuilder var fields: Fields
    @Environment(\.dismiss) private var dismiss
    @State private var submitting = false
    @State private var alert: AppAlert?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A grouped form's own inset, so the title lines up with its sections
            // (UI kit Dialogs: content 20 pt from every edge).
            .padding([.horizontal, .top], 20)
            // The grouped form's background differs in dark mode, leaving seams.
            Form { fields }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 390) // UI kit Dialogs
        // macOS 27 resets the control size in sheets: set it here.
        .controlSize(.regular)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(submitting) }
            ToolbarItem(placement: .confirmationAction) {
                Button(action) {
                    submitting = true
                    Task {
                        do { try await submit(); dismiss() } catch { alert = AppAlert(failure(), error) }
                        submitting = false
                    }
                }
                .disabled(!enabled || submitting)
            }
        }
        .alert($alert)
    }
}

/// A list's rename state; observation redraws only the editing row.
@Observable
final class InPlaceRename<ID: Hashable> {
    private(set) var id: ID?
    var name = ""

    func begin(_ id: ID, name: String) {
        self.name = name
        self.id = id
    }

    func cancel() { id = nil }

    func end(_ id: ID, from old: String) -> String? {
        guard self.id == id else { return nil }
        self.id = nil
        let new = name.trimmingCharacters(in: .whitespaces)
        return new.isEmpty || new == old ? nil : new
    }
}

/// A project's or a file's own actions: its context menu's, and File's for the
/// chosen item of the list with the keyboard (`offersActions`).
struct ItemActions {
    let rename: () -> Void
    let showInFinder: () -> Void
    let moveToTrash: () -> Void
}

struct ItemMenuItems: View {
    let actions: ItemActions

    var body: some View {
        RenameButton().renameAction(actions.rename)
        Button("Show in Finder", action: actions.showInFinder)
        Divider()
        Button("Move to Trash", action: actions.moveToTrash)
    }
}

extension View {
    /// The chosen item's actions for File's items while the list has the keyboard, none while
    /// its name is edited (where ⌘⌫ edits the name). Only while its item exists: one trashed
    /// or renamed away, here or by another app, takes its actions with it.
    func offersActions<ID: Hashable>(for id: ID?, _ actions: (ID) -> ItemActions?) -> some View {
        focusedValue(\.itemActions, id.flatMap(actions))
    }
}

/// Return or losing focus commits, Escape cancels; file selection preserves the extension.
struct RenameField: View {
    @Binding var text: String
    var isFile = false
    /// A character a name can't hold: refused as it's typed or pasted, with the alert sound,
    /// rather than after the name is committed.
    var forbidden: Character?
    /// Return or Escape ended it: the list takes the keyboard back, as Finder's does.
    let ended: () -> Void
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        TextField("Name", text: $text, selection: $selection)
            .labelsHidden()
            .focused($focused)
            .onSubmit { commit(); ended() }
            .onExitCommand { cancel(); ended() }
            .onChange(of: text) { _, new in
                if let forbidden, new.contains(forbidden) {
                    text = new.filter { $0 != forbidden }
                    NSSound.beep()
                }
            }
            .onChange(of: focused) { was, now in
                if now, isFile { selection = .baseName(of: text) }
                if was, !now { commit() }
            }
            // Taken from wherever it is, such as the editor: a default focus would leave it there.
            .onAppear { focused = true }
    }
}

extension TextSelection {
    /// A file name up to its extension; all of a name without one, or a dot file's.
    static func baseName(of name: String) -> TextSelection {
        let dot = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? $0 : nil }
        return TextSelection(range: name.startIndex..<(dot ?? name.endIndex))
    }
}

#Preview("Find bar") {
    @Previewable @State var query = "theorem"
    FindBar(query: $query, prompt: "Find", field: FieldHandle(), matches: FindMatches(index: 3, total: 12),
            searched: query, step: { _ in }, close: {})
        .frame(width: 480)
}
