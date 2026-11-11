import SwiftUI

/// A filter's text in a glass capsule, after the filter symbol, which opens the filter's menu when it has options, and
/// before its toggles.
struct FilterField<Toggles: View>: View {
    @Environment(\.controlSize) private var controlSize
    @Binding var text: String
    var help = ""
    var options: [(title: String, isOn: Binding<Bool>)] = []
    var hasActiveOptions = false
    @ViewBuilder var toggles: Toggles

    var body: some View {
        let large = controlSize == .large
        let active = !text.isEmpty || hasActiveOptions
        let symbol = Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            .font(large ? nil : .subheadline)
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.filterSymbol))
        HStack(spacing: 4) {
            if options.isEmpty {
                symbol.accessibilityHidden(true)
            } else {
                Menu {
                    Section("Show") { ForEach(options.indices, id: \.self) { Toggle(options[$0].title, isOn: options[$0].isOn) } }
                } label: {
                    // A plain menu button draws no indicator of its own.
                    HStack(spacing: -1) {
                        symbol
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    }
                    .padding(.trailing, -1)
                    .foregroundStyle(.filterSymbol)
                    .accessibilityLabel("Filter Options")
                }
                .accessibilityValue("Active", isEnabled: hasActiveOptions)
                .fixedSize()
            }
            TextField("Filter", text: $text).textFieldStyle(.plain).help(help)
            if !text.isEmpty { Button("Clear", systemImage: "xmark.circle.fill") { text = "" }.foregroundStyle(.filterSymbol) }
            toggles
        }
        .padding(.horizontal, 7)
        // AppKit's heights for a large and a regular field.
        .frame(height: large ? 28 : 24)
        .glassEffect(.regular.interactive(), in: .capsule)
        .buttonStyle(.plain)
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
    }
}

/// A toggle beside a filter's text, filled and in the accent colour while on.
struct FilterToggle: View {
    let symbol: String
    let label: LocalizedStringKey, help: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, systemImage: symbol, isOn: $isOn)
            .symbolVariant(isOn ? .fill : .none)
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.filterSymbol))
            .help(help)
    }
}

private extension ShapeStyle where Self == Color {
    /// The label colour AppKit gives a field's symbols, which a hierarchical style over glass comes out lighter than.
    static var filterSymbol: Color { Color(nsColor: .secondaryLabelColor) }
}

extension NSSearchField {
    /// Adds the field's text to its recents, which a field sending each keystroke never does itself.
    func remember() {
        guard !stringValue.isEmpty else { return }
        recentSearches = Array(([stringValue] + recentSearches.filter { $0 != stringValue }).prefix(10))
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
    var large = false
    /// A symbol to show in place of the magnifier.
    var symbol: String?
    var handle: FieldHandle?
    /// The name its recent searches are kept under and listed in its menu by.
    var recents: String?
    var step: (@MainActor (Int) -> Void)?
    var move: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?
    var optionsTitle: String?
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
                if field.recents != nil { (control as? NSSearchField)?.remember() }
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
        view.recentsAutosaveName = recents
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
        // A field that leaves the screen while it has the keyboard would keep taking what's typed.
        if !context.environment.isEnabled, view.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
        if !options.isEmpty || recents != nil, let cell = view.cell as? NSSearchFieldCell {
            let menu = NSMenu()
            if let optionsTitle { menu.addItem(.sectionHeader(title: optionsTitle)) }
            for (tag, option) in options.enumerated() {
                let item = menu.addItem(withTitle: option.title, action: #selector(Coordinator.toggle(_:)), keyEquivalent: "")
                (item.target, item.tag, item.state) = (context.coordinator, tag, option.isOn.wrappedValue ? .on : .off)
            }
            if recents != nil {
                if !options.isEmpty { menu.addItem(.separator()) }
                for (title, tag) in [(String(localized: "Recent Searches"), NSSearchField.recentsTitleMenuItemTag), ("", NSSearchField.recentsMenuItemTag),
                                     (String(localized: "Clear Recents"), NSSearchField.clearRecentsMenuItemTag),
                                     (String(localized: "No Recent Searches"), NSSearchField.noRecentsMenuItemTag)] {
                    menu.addItem(withTitle: title, action: nil, keyEquivalent: "").tag = tag
                }
            }
            cell.searchMenuTemplate = menu
        }
        // The cell restores its magnifier whenever its control size changes, which SwiftUI's environment does after makeNSView.
        if let symbol = context.coordinator.symbol, let button = (view.cell as? NSSearchFieldCell)?.searchButtonCell, button.image !== symbol {
            (button.image, button.alternateImage) = (symbol, symbol)
        }
        let size = NSFont.systemFontSize(for: view.controlSize)
        if !large, view.font?.pointSize != size { view.font = .systemFont(ofSize: size) }
        view.placeholderString = prompt
        view.setAccessibilityLabel(prompt)
        if view.stringValue != text, (view.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            view.stringValue = text
        }
    }
}
