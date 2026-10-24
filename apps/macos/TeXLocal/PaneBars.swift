import SwiftUI

final class FieldHandle {
    fileprivate(set) weak var field: NSTextField?

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

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var symbol: String?
    var handle: FieldHandle?
    var step: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?
    /// In the magnifier's menu, as Mail's.
    var options: [(title: String, isOn: Binding<Bool>)] = []

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: SearchField

        init(_ field: SearchField) { self.field = field }

        @objc func changed(_ sender: NSSearchField) { if field.text != sender.stringValue { field.text = sender.stringValue } }

        @objc func toggle(_ item: NSMenuItem) { field.options[item.tag].isOn.wrappedValue.toggle() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // The input method's Return and Escape first.
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
        // For VoiceOver, as the placeholder goes once there's text.
        view.setAccessibilityLabel(prompt)
        // Not during input-method composition, whose marked text it would discard.
        if view.stringValue != text, (view.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            view.stringValue = text
        }
        // The cell copies the template, so its ticks are set afresh.
        if !options.isEmpty, let cell = view.cell as? NSSearchFieldCell {
            let menu = NSMenu()
            for (tag, option) in options.enumerated() {
                let item = menu.addItem(withTitle: option.title, action: #selector(Coordinator.toggle(_:)), keyEquivalent: "")
                (item.target, item.tag, item.state) = (context.coordinator, tag, option.isOn.wrappedValue ? .on : .off)
            }
            cell.searchMenuTemplate = menu
        }
    }
}

final class FindPassingTextView: NSTextView {
    private static let find = #selector(NSTextView.performFindPanelAction(_:))

    override func performFindPanelAction(_ sender: Any?) { nextResponder?.tryToPerform(Self.find, with: sender) }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == Self.find else { return super.validateMenuItem(item) }
        // From the next responder: NSApp.target(forAction:) starts at this editor.
        let target = nextResponder.flatMap { first in sequence(first: first, next: \.nextResponder).first { $0.responds(to: Self.find) } }
        return target.map { ($0 as? any NSMenuItemValidation)?.validateMenuItem(item) ?? true } ?? false
    }
}

struct DialogSheet<Fields: View>: View {
    let title: String
    var message: String?
    let action: String
    let enabled: Bool
    /// Read when it fails: the toolbar keeps the button's action from its last change of state.
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
            // The grouped form's inset, so the title lines up with its sections.
            .scenePadding([.horizontal, .top])
            // Its own background leaves seams in Dark.
            Form { fields }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 390)
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

/// A group has icons for all its items or none (HIG, Menus).
struct ItemMenuItems: View {
    let actions: ItemActions?
    var trashShortcut: KeyboardShortcut?

    var body: some View {
        Button { actions?.rename?() } label: { Label("Rename", systemImage: "pencil") }
            .disabled(actions?.rename == nil)
        Button { actions?.showInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
            .disabled(actions == nil)
        Divider()
        Button { actions?.moveToTrash?() } label: { Label("Move to Trash", systemImage: "trash") }
            .keyboardShortcut(trashShortcut)
            .disabled(actions?.moveToTrash == nil)
    }
}

extension View {
    /// Through `AppModel`: a focused value doesn't reach the menus from an AppKit window's hosting views.
    func offersActions<ID: Hashable>(for id: ID?, _ actions: @escaping (ID) -> ItemActions?) -> some View {
        modifier(ActionsOffer(id: id, actions: actions))
    }
}

private struct ActionsOffer<ID: Hashable>: ViewModifier {
    @Environment(AppModel.self) private var app
    let id: ID?
    let actions: (ID) -> ItemActions?

    func body(content: Content) -> some View {
        // Only while its item exists.
        let present = id.flatMap { actions($0) == nil ? nil : $0 }
        content
            .onChange(of: present, initial: true) { _, id in app.chosenItem = id.flatMap(actions) }
            .onDisappear { app.chosenItem = nil }
    }
}
