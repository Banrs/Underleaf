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
    var large = false
    var trailingRoom: CGFloat = 0
    var handle: FieldHandle?
    var step: (@MainActor (Int) -> Void)?
    var move: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?
    var options: [(title: String, isOn: Binding<Bool>)] = []

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: SearchField
        lazy var symbol = field.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }

        init(_ field: SearchField) { self.field = field }

        @objc func changed(_ sender: NSSearchField) { if field.text != sender.stringValue { field.text = sender.stringValue } }

        @objc func toggle(_ item: NSMenuItem) { field.options[item.tag].isOn.wrappedValue.toggle() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
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

    static let filterSymbol = "line.3.horizontal.decrease.circle"

    static func filter(_ text: Binding<String>) -> SearchField {
        SearchField(text: text, prompt: String(localized: "Filter"), symbol: filterSymbol)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let view = RoomySearchField()
        (view.cell as? RoomySearchField.Cell)?.room = trailingRoom
        view.sendsSearchStringImmediately = true
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.action = #selector(Coordinator.changed(_:))
        if large, let cell = view.cell as? NSSearchFieldCell {
            view.font = .systemFont(ofSize: 20)
            (view.isBezeled, view.drawsBackground, view.focusRingType) = (false, false, .none)
            (cell.searchButtonCell, cell.cancelButtonCell) = (nil, nil)
        }
        handle?.field = view
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        context.coordinator.field = self
        // The cell puts its magnifier back whenever its control size changes, as SwiftUI's environment does after makeNSView.
        if let symbol = context.coordinator.symbol, let button = (view.cell as? NSSearchFieldCell)?.searchButtonCell, button.image !== symbol {
            button.image = symbol
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

/// Keeps the text and the clear button clear of a control laid over the field's trailing end.
final class RoomySearchField: NSSearchField {
    final class Cell: NSSearchFieldCell {
        var room: CGFloat = 0

        override func searchTextRect(forBounds rect: NSRect) -> NSRect { super.searchTextRect(forBounds: rect.insetBy(trailing: room)) }
        override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { super.cancelButtonRect(forBounds: rect.insetBy(trailing: room)) }
    }

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }
}

private extension NSRect {
    func insetBy(trailing: CGFloat) -> NSRect { NSRect(x: minX, y: minY, width: width - trailing, height: height) }
}

final class FindPassingTextView: NSTextView {
    private static let find = #selector(NSTextView.performFindPanelAction(_:))

    override func performFindPanelAction(_ sender: Any?) { nextResponder?.tryToPerform(Self.find, with: sender) }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == Self.find else { return super.validateMenuItem(item) }
        let target = nextResponder.flatMap { first in sequence(first: first, next: \.nextResponder).first { $0.responds(to: Self.find) } }
        return target.map { ($0 as? any NSMenuItemValidation)?.validateMenuItem(item) ?? true } ?? false
    }
}
