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
    var handle: FieldHandle?
    var step: (@MainActor (Int) -> Void)?
    var move: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?
    var options: [(title: String, isOn: Binding<Bool>)] = []
    var status: String?
    /// The status as VoiceOver reads it, since the drawn one isn't in the accessibility tree.
    var spokenStatus: String?

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
        let view = status == nil ? NSSearchField() : StatusSearchField()
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
        if !large, view.font?.pointSize != NSFont.systemFontSize(for: view.controlSize) {
            view.font = .systemFont(ofSize: NSFont.systemFontSize(for: view.controlSize))
        }
        if let cell = view.cell as? StatusSearchField.Cell, cell.status != status ?? "" {
            cell.status = status ?? ""
            (view.needsLayout, view.needsDisplay) = (true, true)
        }
        view.placeholderString = prompt
        view.setAccessibilityLabel(spokenStatus.map { "\(prompt), \($0)" } ?? prompt)
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

/// A search field showing a status, a match count, as NSTextFinder's bar field shows it, read from that field's cell: its
/// right edge 1.5 pt into the clear button's rect, in the field's font with monospaced digits, the text stopping 11.5 pt
/// before it. Laying the field out again moves the field editor to follow it.
private final class StatusSearchField: NSSearchField {
    final class Cell: NSSearchFieldCell {
        var status = ""

        private var attributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.monospacedDigitSystemFont(ofSize: font?.pointSize ?? NSFont.smallSystemFontSize, weight: .regular),
             .foregroundColor: NSColor.secondaryLabelColor]
        }

        private func statusRect(forBounds rect: NSRect) -> NSRect {
            let width = status.isEmpty ? 0 : (status as NSString).size(withAttributes: attributes).width.rounded(.up)
            let text = super.searchTextRect(forBounds: rect)
            return NSRect(x: cancelButtonRect(forBounds: rect).minX + 1.5 - width, y: text.minY, width: width, height: text.height)
        }

        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            var text = super.searchTextRect(forBounds: rect)
            if !status.isEmpty { text.size.width = max(0, statusRect(forBounds: rect).minX - 11.5 - text.minX) }
            return text
        }

        override func drawInterior(withFrame frame: NSRect, in view: NSView) {
            super.drawInterior(withFrame: frame, in: view)
            (status as NSString).draw(in: statusRect(forBounds: frame), withAttributes: attributes)
        }
    }

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }
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
