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

extension NSImage {
    /// The symbol followed by the chevron a search field shows after its magnifier when it has a menu, which AppKit leaves
    /// out beside any other symbol: one template image, so the search button tints and highlights both as its own. The
    /// chevron is cut from a stock field's image, where Xcode's console filter draws its own: like Xcode's, it isn't
    /// moved onto whole pixels.
    func withMenuChevron() -> NSImage {
        let stock = Self.stockMenuImage
        let image = NSImage(size: NSSize(width: size.width + 8, height: size.height), flipped: false) { [self] _ in
            draw(in: NSRect(origin: .zero, size: size))
            guard let stock else { return true }
            // The stock image starts 5.3 pt left of the symbol's centre and 7.25 pt below it, which puts its chevron within a
            // quarter pixel of Xcode's at 2x, fitted against captures of Xcode's console and navigator filters. The chevron
            // is the strip from 12 pt across and 5 to 10 pt up, clear of the magnifier and its handle.
            let origin = NSPoint(x: size.width / 2 - 5.3, y: size.height / 2 - 7.25)
            NSRect(x: origin.x + 12, y: origin.y + 5, width: stock.size.width - 12, height: 5).clip()
            stock.draw(in: NSRect(origin: origin, size: stock.size))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let stockMenuImage: NSImage? = {
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        guard let cell = NSSearchField().cell as? NSSearchFieldCell else { return nil }
        cell.searchMenuTemplate = menu
        return cell.searchButtonCell?.image
    }()
}

/// A stock search field showing a symbol in place of the magnifier and, with a menu, the menu chevron.
final class FilterSearchField: NSSearchField {
    final class Cell: NSSearchFieldCell {
        /// Centres the 15 pt symbol on the field, on whole pixels, as Xcode's console filter does. AppKit's own rect sits a
        /// point below the middle, with the symbol half a point below that.
        override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
            let button = super.searchButtonRect(forBounds: rect)
            let scale = controlView?.window?.backingScaleFactor ?? 2
            return NSRect(x: button.minX, y: (rect.midY - 7.5).pixelCeiling(scale), width: button.width, height: 15)
        }

        /// Sets the text's capitals on the field's middle, level with the symbol and the bar's labels; AppKit moves the rect
        /// 2 pt down for text smaller than the field's own, which set it a point low.
        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            var text = super.searchTextRect(forBounds: rect)
            guard let font else { return text }
            let scale = controlView?.window?.backingScaleFactor ?? 2
            text.origin.y = (rect.midY + font.capHeight / 2 - Self.layout.defaultBaselineOffset(for: font)).pixelCeiling(scale)
            return text
        }

        private static let layout = NSLayoutManager()
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
        lazy var menuSymbol = symbol?.withMenuChevron()

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
            cell.showSearchSymbol(options.isEmpty ? symbol : context.coordinator.menuSymbol ?? symbol)
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
