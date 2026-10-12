import SwiftUI

/// A field the window can focus after AppKit creates it.
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
        let view = NSSearchField()
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

/// Pass Edit › Find from the PDF find field's editor to the window, which routes it to the PDF.
final class FindPassingTextView: NSTextView {
    override func performFindPanelAction(_ sender: Any?) {
        nextResponder?.tryToPerform(#selector(NSTextView.performFindPanelAction(_:)), with: sender)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, action == #selector(NSTextView.performFindPanelAction(_:)) else {
            return super.validateMenuItem(item)
        }
        // The chain from the next responder; NSApp.target(forAction:) starts
        // at the first responder, which is this editor.
        let target = nextResponder.flatMap { first in
            sequence(first: first, next: \.nextResponder).first { $0.responds(to: action) }
        }
        guard let target else { return false }
        return (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
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
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A grouped form's own inset, so the title lines up with its sections.
            .scenePadding([.horizontal, .top])
            // The grouped form's background differs in dark mode, leaving seams.
            Form { fields }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
        }
        // The form size is wider (about 560 pt); the UI kit's dialog is 390.
        .frame(width: 390)
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

/// The same items in File and in the context menus, dimmed with no item. All three have an icon,
/// as a group has icons for all its items or none (HIG, Menus): "folder" stands for Show in
/// Finder's file-system location, which has no icon of its own.
struct ItemMenuItems: View {
    let actions: ItemActions?
    var trashShortcut: KeyboardShortcut?

    var body: some View {
        // The standard icons (HIG, Icons), which show where the menu's label style has them: File's.
        Button { actions?.rename() } label: { Label("Rename", systemImage: "pencil") }
            .disabled(actions == nil)
        Button { actions?.showInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
            .disabled(actions == nil)
        Divider()
        Button { actions?.moveToTrash() } label: { Label("Move to Trash", systemImage: "trash") }
            .keyboardShortcut(trashShortcut)
            .disabled(actions == nil)
    }
}

extension View {
    /// The chosen item's actions for File's items, none while its name is edited
    /// (where ⌘⌫ edits the name). Through `AppModel`: a focused value doesn't
    /// reach the menus from an AppKit window's hosting views.
    func offersActions<ID: Hashable>(for id: ID?, _ actions: @escaping (ID) -> ItemActions?) -> some View {
        modifier(ActionsOffer(id: id, actions: actions))
    }
}

private struct ActionsOffer<ID: Hashable>: ViewModifier {
    @Environment(AppModel.self) private var app
    let id: ID?
    let actions: (ID) -> ItemActions?

    func body(content: Content) -> some View {
        // Only while its item exists: one trashed or renamed away, here or by
        // another app, takes its actions with it.
        let present = id.flatMap { actions($0) == nil ? nil : $0 }
        content
            .onChange(of: present, initial: true) { _, id in app.chosenItem = id.flatMap(actions) }
            .onDisappear { app.chosenItem = nil }
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
