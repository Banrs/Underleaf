import SwiftUI

final class FieldHandle {
    weak var field: NSTextField?

    func focus() {
        guard let field, let window = field.window else { return }
        if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        field.currentEditor()?.selectAll(nil)
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var large = false
    var handle: FieldHandle?
    var step: (@MainActor (Int) -> Void)?
    var move: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?
    var options: [(title: String, isOn: Binding<Bool>)] = []
    /// The name the field keeps its past entries under, in its symbol's menu.
    var recents: String?

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: SearchField

        init(_ field: SearchField) { self.field = field }

        @objc func changed(_ sender: NSSearchField) { if field.text != sender.stringValue { field.text = sender.stringValue } }

        @objc func toggle(_ item: NSMenuItem) { field.options[item.tag].isOn.wrappedValue.toggle() }

        func controlTextDidEndEditing(_ note: Notification) { remember(note.object) }

        /// Adds the text to the field's recents, which a field sending each keystroke never does itself.
        private func remember(_ control: Any?) {
            guard field.recents != nil, let view = control as? NSSearchField, !view.stringValue.isEmpty else { return }
            view.recentSearches = Array(([view.stringValue] + view.recentSearches.filter { $0 != view.stringValue }).prefix(10))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                remember(control)
                guard let step = field.step else { return false }
                step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                guard let move = field.move else { return false }
                move(selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1)
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
        if large, let cell = view.cell as? NSSearchFieldCell {
            view.font = .systemFont(ofSize: 20)
            (view.isBezeled, view.drawsBackground, view.focusRingType) = (false, false, .none)
            (cell.searchButtonCell, cell.cancelButtonCell) = (nil, nil)
        }
        if let recents {
            view.recentsAutosaveName = recents
            let menu = NSMenu()
            for (title, tag) in [(String(localized: "Recent Searches"), NSSearchField.recentsTitleMenuItemTag), ("", NSSearchField.recentsMenuItemTag),
                                 (String(localized: "Clear Recents"), NSSearchField.clearRecentsMenuItemTag),
                                 (String(localized: "No Recent Searches"), NSSearchField.noRecentsMenuItemTag)] {
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "").tag = tag
            }
            view.searchMenuTemplate = menu
        }
        handle?.field = view
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        context.coordinator.field = self
        if !large, view.font?.pointSize != NSFont.systemFontSize(for: view.controlSize) {
            view.font = .systemFont(ofSize: NSFont.systemFontSize(for: view.controlSize))
        }
        view.placeholderString = prompt
        view.setAccessibilityLabel(prompt)
        if view.stringValue != text, (view.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            view.stringValue = text
        }
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
