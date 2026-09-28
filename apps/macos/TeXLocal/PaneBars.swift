import SwiftUI

/// The in-window bars' metrics, from the macOS 27 UI kit.
enum BarMetrics {
    static let controlSize: ControlSize = .regular
    /// UI kit: small controls (buttons, pop-ups, fields) are 20 pt high.
    static let secondaryControlHeight: CGFloat = 20
    /// UI kit, Unified Compact toolbar: items 8 pt from its top, bottom and ends.
    static let inset: CGFloat = 8
    /// UI kit: a symbol and its words 4 pt apart.
    static let spacing: CGFloat = 4
    /// The status bar and the folded outline share this height, so the hairlines
    /// over them run on as one.
    static var secondaryBarHeight: CGFloat { secondaryControlHeight + 2 * spacing }
    /// UI kit, Unified Compact toolbar: items 12 pt apart.
    static let itemSpacing: CGFloat = 12
    /// UI kit, Unified toolbar: items 8 pt apart.
    static let groupSpacing: CGFloat = 8
    /// Design: the least room a find query needs, and the widest a filter grows
    /// (UI kit search fields are drawn 120 pt).
    static let fieldMinWidth: CGFloat = 100
    static let fieldMaxWidth: CGFloat = 180
}

/// The app's text roles, each a system text style, so a role reads the same
/// everywhere.
enum Typography {
    static let sectionTitle: Font = .title3.weight(.semibold)
    static let groupTitle: Font = .headline
    static let itemTitle: Font = .headline
    /// Secondary rows and captions: the size `.small` controls use.
    static let secondary: Font = .subheadline
    /// UI kit, form rows: the description 2 pt under the title.
    static let subtitleSpacing: CGFloat = 2
    static let secondaryControlSize: ControlSize = .small
    /// SF Mono at the secondary size, for AppKit text (the build log).
    static var secondaryMono: NSFont {
        .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
    }
}

extension View {
    /// An accessory bar's controls, inset from the pane's edges.
    func paneBarControls() -> some View {
        controlSize(BarMetrics.controlSize)
            .lineLimit(1)
            .padding(.horizontal, BarMetrics.inset)
            .frame(maxWidth: .infinity)
    }
}

/// An accessory bar over a view's content (the build panel's header).
struct PaneBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack { content }
            .padding(.vertical, BarMetrics.inset)
            .paneBarControls()
    }
}

/// The window's status along its foot, at the secondary text style and control size.
/// Its host keeps its ends clear of the window's rounded corners (AppKit's
/// corner-adapted safe area: SwiftUI's container corner insets are zero in an
/// AppKit split item's accessory).
struct SecondaryBar<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
            .font(Typography.secondary)
            .controlSize(Typography.secondaryControlSize)
            .lineLimit(1)
            .padding(.horizontal, BarMetrics.inset)
            .frame(height: BarMetrics.secondaryBarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// NSSegmentedControl (.tabs role): SwiftUI's tabs picker moved its thumb on hover (27.2).
struct TabsControl<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: options.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.role = .tabs
        control.setAccessibilityLabel(title)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.select = { index in selection = options[index].value }
        control.controlSize = NSControl.ControlSize(context.environment.controlSize) ?? .regular
        if let index = options.firstIndex(where: { $0.value == selection }), control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    final class Coordinator: NSObject {
        var select: (Int) -> Void = { _ in }

        @objc func changed(_ control: NSSegmentedControl) {
            select(control.selectedSegment)
        }
    }
}

/// The source's and the PDF's find bar, with the source's replace row under it.
/// Return and Shift-Return step, Escape closes. It lives in its pane's top
/// accessory, which keeps it in the window while hidden, so `field` can take the
/// keyboard at once.
struct FindBar<Replace: View>: View {
    @Binding var query: String
    let prompt: String
    let field: FieldHandle
    var options: [SearchOption] = []
    let matches: FindMatches
    /// The query the matches are for, which the count reads.
    let searched: String
    let step: @MainActor (Int) -> Void
    let close: @MainActor () -> Void
    /// The replace row's cells, a `GridRow`: its field, then its buttons.
    @ViewBuilder var replace: Replace

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: BarMetrics.groupSpacing, verticalSpacing: BarMetrics.inset) {
            GridRow {
                SearchField(text: $query, prompt: prompt, handle: field, options: options, step: step, close: close)
                    .frame(minWidth: BarMetrics.fieldMinWidth, maxWidth: .infinity)
                HStack(spacing: BarMetrics.groupSpacing) {
                    ControlGroup {
                        Button("Previous Match", systemImage: "chevron.up") { step(-1) }
                            .help("Previous Match")
                        Button("Next Match", systemImage: "chevron.down") { step(1) }
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
                .gridColumnAlignment(.trailing)
            }
            replace
        }
        .padding(.vertical, BarMetrics.inset)
        .paneBarControls()
    }
}

extension FindBar where Replace == EmptyView {
    init(query: Binding<String>, prompt: String, field: FieldHandle, matches: FindMatches, searched: String,
         step: @escaping @MainActor (Int) -> Void, close: @escaping @MainActor () -> Void) {
        self.init(query: query, prompt: prompt, field: field, matches: matches, searched: searched,
                  step: step, close: close) { EmptyView() }
    }
}

/// A choice in a search field's own menu (Match Case, Whole Words…).
struct SearchOption {
    let title: String
    let isOn: Binding<Bool>
}

/// A search field the window can give the keyboard to: the field registers
/// itself here as it's made.
final class FieldHandle {
    fileprivate(set) weak var field: NSSearchField?

    /// Takes the keyboard, its text selected, so typing replaces the query.
    func focus() {
        guard let field, let window = field.window else { return }
        if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        field.currentEditor()?.selectAll(nil)
    }

    /// Whether it, or its field editor, has the keyboard.
    var hasFocus: Bool {
        guard let field, let first = field.window?.firstResponder else { return false }
        return first === field || first === field.currentEditor()
    }
}

/// NSSearchField in a bar: SwiftUI has search fields only as `.searchable`.
/// Return steps (Shift-Return back) and Escape closes when `step`/`close` are set.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var handle: FieldHandle?
    var options: [SearchOption] = []
    var step: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: SearchField
        /// The options' states the field's menu was last made with.
        var optionStates: [Bool]?

        init(_ field: SearchField) { self.field = field }

        // Typing, and the field's clear button, both send the action.
        @objc func search(_ sender: NSSearchField) {
            field.text = sender.stringValue
        }

        @objc func toggleOption(_ sender: NSMenuItem) {
            guard field.options.indices.contains(sender.tag) else { return }
            field.options[sender.tag].isOn.wrappedValue.toggle()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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
        // A find bar's: its field editor passes Edit › Find's items on
        // (`FindFieldEditor`); a filter has no matches to step.
        view.sendsSearchStringImmediately = true
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.action = #selector(Coordinator.search(_:))
        handle?.field = view
        return view
    }

    /// As wide as offered: the frame around it sets its least and ideal widths.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = self
        handle?.field = view
        view.placeholderString = prompt
        // VoiceOver's name: the placeholder goes once there's text.
        view.setAccessibilityLabel(prompt)
        view.controlSize = NSControl.ControlSize(context.environment.controlSize) ?? .regular
        view.font = .systemFont(ofSize: NSFont.systemFontSize(for: view.controlSize))
        if view.stringValue != text { view.stringValue = text }
        // The field copies its menu, so it is made again when a state changes.
        let states = options.map(\.isOn.wrappedValue)
        if !options.isEmpty, coordinator.optionStates != states {
            coordinator.optionStates = states
            let menu = NSMenu(title: "Find Options")
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option.title, action: #selector(Coordinator.toggleOption(_:)), keyEquivalent: "")
                item.target = coordinator
                item.tag = index
                item.state = option.isOn.wrappedValue ? .on : .off
                menu.addItem(item)
            }
            view.searchMenuTemplate = menu
        }
    }
}

/// A find bar's field editor, which the window hands its find fields: it passes
/// Edit › Find's items on to the window (`MainWindowController`), where the shared
/// field editor would answer them itself and turn them off.
final class FindFieldEditor: NSTextView {
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

/// A small sheet that asks for a few values: a title and message over a grouped
/// form. Not an alert with fields: the HIG keeps alerts for important information.
struct DialogSheet<Fields: View>: View {
    let title: String
    var message: String?
    let action: String
    let enabled: Bool
    let submit: () -> Void
    @ViewBuilder var fields: Fields
    @Environment(\.dismiss) private var dismiss

    /// A grouped form's own inset, so the title lines up with its sections
    /// (UI kit Dialogs: content 20 pt from every edge).
    private static var formInset: CGFloat { 20 }
    private static var width: CGFloat { 390 } // UI kit Dialogs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BarMetrics.spacing) {
                Text(title)
                    .font(Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], Self.formInset)
            // The grouped form's background differs in dark mode, leaving seams.
            Form { fields }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.width)
        // macOS 27 resets the control size in sheets: set it here.
        .controlSize(.regular)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action) {
                    dismiss()
                    submit()
                }
                .disabled(!enabled)
            }
        }
    }
}

/// A list's rename in place. Observable, so typing redraws only the row with
/// the field, not every row that checks `id`.
@Observable
final class InPlaceRename<ID: Hashable> {
    private(set) var id: ID?
    var name = ""

    func begin(_ id: ID, name: String) {
        self.name = name
        self.id = id
    }

    func cancel() { id = nil }

    /// Ends `id`'s rename: the new name, trimmed, or nil when the rename
    /// had already ended or left the name empty or as it was.
    func end(_ id: ID, from old: String) -> String? {
        guard self.id == id else { return nil }
        self.id = nil
        let new = name.trimmingCharacters(in: .whitespaces)
        return new.isEmpty || new == old ? nil : new
    }
}

/// An item's own actions; Move to Trash apart from the rest.
struct ItemMenuItems: View {
    let rename: () -> Void
    let showInFinder: () -> Void
    let moveToTrash: () -> Void

    var body: some View {
        RenameButton().renameAction(rename)
        Button("Show in Finder", action: showInFinder)
        Divider()
        Button("Move to Trash", action: moveToTrash)
    }
}

/// A name edited in place: Return or clicking away commits, Escape cancels.
/// A file's name starts selected up to its extension, as in Finder.
struct RenameField: View {
    @Binding var text: String
    var isFile = false
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        TextField("Name", text: $text, selection: $selection)
            .labelsHidden()
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
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

#Preview("Secondary bar") {
    SecondaryBar(spacing: BarMetrics.itemSpacing) {
        Text("Compiled in 1.2 s")
        Spacer(minLength: 0)
        Text("1,204 words").monospacedDigit()
        Text("Page 2 of 5").monospacedDigit()
    }
    .frame(width: 480)
}
