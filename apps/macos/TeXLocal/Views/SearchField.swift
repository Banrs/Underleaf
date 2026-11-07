import SwiftUI

extension CGFloat {
    /// Rounds up to a whole pixel at a backing scale: a half point stays put at 2x and moves to the next point at 1x.
    func pixelCeiling(_ scale: CGFloat) -> CGFloat { (self * scale).rounded(.up) / scale }
}

extension NSSearchFieldCell {
    /// Shows a symbol in place of the magnifier, scaled to the magnifier's height so the cell's insets fit it (the filter
    /// symbol is 2 pt wider than a small field's magnifier and ran into the text).
    func showSearchSymbol(_ symbol: NSImage) {
        guard let button = searchButtonCell, button.image !== symbol else { return }
        if let magnifier = button.image { symbol.size = NSSize(width: symbol.size.width * magnifier.size.height / symbol.size.height, height: magnifier.size.height) }
        showSearchImage(symbol)
    }

    /// Sets the search button's image for both states: AppKit keeps its magnifier as the pressed image, which flashed on
    /// a click.
    func showSearchImage(_ image: NSImage?) {
        guard let button = searchButtonCell else { return }
        (button.image, button.alternateImage) = (image, image)
    }
}

/// A symbol followed by the chevron a search field shows after its magnifier when it has a menu, which AppKit leaves out
/// beside any other symbol. The chevron is cut from a stock field's image, so it stays crisp at 1x, and sits 11 pt after
/// the symbol's centre, as in Xcode. The button shows a clear placeholder as wide as both, so a click on either opens the
/// menu, and copies of its cell draw the two so they keep its tint and highlight.
final class MenuSymbol {
    let symbol: NSImage
    let placeholder: NSImage
    private var cells: (symbol: NSButtonCell, chevron: NSButtonCell)?
    private static let stock: NSImage? = {
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        guard let cell = NSSearchField().cell as? NSSearchFieldCell else { return nil }
        cell.searchMenuTemplate = menu
        return cell.searchButtonCell?.image
    }()

    init(_ symbol: NSImage) {
        self.symbol = symbol
        placeholder = NSImage(size: NSSize(width: symbol.size.width + 8, height: symbol.size.height))
    }

    func draw(for button: NSButtonCell, in rect: NSRect, of view: NSView) {
        if cells == nil, let copy = button.copy() as? NSButtonCell, let other = button.copy() as? NSButtonCell {
            (copy.image, other.image) = (symbol, Self.stock)
            cells = (copy, other)
        }
        guard let cells, let stock = Self.stock else { return }
        for cell in [cells.symbol, cells.chevron] {
            if cell.isEnabled != button.isEnabled { cell.isEnabled = button.isEnabled }
            if cell.isHighlighted != button.isHighlighted { cell.isHighlighted = button.isHighlighted }
        }
        let origin = NSPoint(x: rect.midX - placeholder.size.width / 2, y: rect.midY - placeholder.size.height / 2)
        let symbolRect = NSRect(origin: origin, size: symbol.size)
        // The stock chevron is centred 16 pt into its image, after a magnifier that ends before 12 pt and a handle below 10.
        // It starts on a whole pixel, rounding down, as Xcode's does at 1x.
        let scale = view.window?.backingScaleFactor ?? 2
        let stockRect = NSRect(x: symbolRect.minX + ((symbol.size.width / 2 + 11 - 16) * scale).rounded(.down) / scale,
                               y: symbolRect.minY, width: stock.size.width, height: stock.size.height)
        // Unaligned, so the cell rounds it to pixels as it rounds its own image.
        cells.symbol.draw(withFrame: symbolRect, in: view)
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: stockRect.minX + 12, y: stockRect.minY + 5, width: stockRect.width - 12, height: 5).clip()
        cells.chevron.draw(withFrame: stockRect, in: view)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A stock search field showing a symbol in place of the magnifier and, with a menu, the menu chevron.
final class FilterSearchField: NSSearchField {
    final class Cell: NSSearchFieldCell {
        /// Drawn in the search button's place when the field has a menu.
        var menuSymbol: MenuSymbol?

        /// Centres the symbol on the field, like Xcode's console filter, an eighth of a point low so that at 1x it rounds down a
        /// pixel as Xcode's does. AppKit's own rect sits a point below the middle, with the symbol half a point below that.
        override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
            let button = super.searchButtonRect(forBounds: rect)
            return NSRect(x: button.minX, y: rect.midY - 7.875, width: button.width, height: 15)
        }

        override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            if searchMenuTemplate != nil, let menuSymbol, let button = searchButtonCell {
                menuSymbol.draw(for: button, in: searchButtonRect(forBounds: cellFrame), of: controlView)
            }
        }
    }

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }
}

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
    var symbol: String?
    var large = false
    /// The text's size, when it isn't the field's.
    var textSize: NSControl.ControlSize?
    var handle: FieldHandle?
    var step: (@MainActor (Int) -> Void)?
    var move: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?
    var optionsTitle: String?
    var options: [(title: String, isOn: Binding<Bool>)] = []

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: SearchField
        lazy var symbol = field.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        lazy var menuSymbol = symbol.map { MenuSymbol($0) }

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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let view = symbol == nil ? NSSearchField() : FilterSearchField()
        (view.cell as? FilterSearchField.Cell)?.menuSymbol = context.coordinator.menuSymbol
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
        if !options.isEmpty, let cell = view.cell as? NSSearchFieldCell {
            let menu = NSMenu()
            if let optionsTitle { menu.addItem(.sectionHeader(title: optionsTitle)) }
            for (tag, option) in options.enumerated() {
                let item = menu.addItem(withTitle: option.title, action: #selector(Coordinator.toggle(_:)), keyEquivalent: "")
                (item.target, item.tag, item.state) = (context.coordinator, tag, option.isOn.wrappedValue ? .on : .off)
            }
            cell.searchMenuTemplate = menu
        }
        // The cell restores its magnifier whenever its control size or menu changes, which SwiftUI's environment does after
        // makeNSView.
        if let symbol = context.coordinator.symbol, let cell = view.cell as? NSSearchFieldCell {
            cell.showSearchSymbol(options.isEmpty ? symbol : context.coordinator.menuSymbol?.placeholder ?? symbol)
        }
        let size = NSFont.systemFontSize(for: textSize ?? view.controlSize)
        if !large, view.font?.pointSize != size { view.font = .systemFont(ofSize: size) }
        view.placeholderString = prompt
        view.setAccessibilityLabel(prompt)
        if view.stringValue != text, (view.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            view.stringValue = text
        }
    }
}
