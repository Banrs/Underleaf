import SwiftUI

/// The in-window bars' metrics, from the macOS 27 UI kit.
enum BarMetrics {
    /// UI kit, Unified Compact toolbar: items 8 pt from its top, bottom and ends.
    static let inset: CGFloat = 8
    /// UI kit: a symbol and its words 4 pt apart.
    static let spacing: CGFloat = 4
    /// The status bar and the folded File Outline header share this height, so the
    /// hairlines over them run on as one (Xcode's status bar).
    static let secondaryBarHeight: CGFloat = 36
    /// UI kit, Unified Compact toolbar: items 12 pt apart.
    static let itemSpacing: CGFloat = 12
    /// Design: the least room a find query needs, and the widest a filter grows
    /// (UI kit search fields are drawn 120 pt).
    static let fieldMinWidth: CGFloat = 100
    static let fieldMaxWidth: CGFloat = 180
}

/// The app's text roles, each a system text style, so a role reads the same
/// everywhere.
enum Typography {
    static let itemTitle: Font = .headline
    /// Secondary rows and captions: the size `.small` controls use.
    static let secondary: Font = .subheadline
    /// UI kit, form rows: the description 2 pt under the title.
    static let subtitleSpacing: CGFloat = 2
}

extension View {
    /// A column's colour under the toolbar, in a scroll view: AppKit draws a column's
    /// scroll edge effect only from one, and joins the columns' into one band where
    /// the toolbar's sections meet. The content keeps below the toolbar, the PDF's as
    /// the source's must: a web view under it draws WebKit's own effect, in the
    /// page's colour, which never joins.
    func columnSurface(_ color: NSColor) -> some View {
        background {
            ScrollView {}
                .background(Color(nsColor: color))
                .accessibilityHidden(true)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    /// An accessory bar's controls, inset from the pane's edges.
    func paneBarControls() -> some View {
        lineLimit(1)
            .padding(.horizontal, BarMetrics.inset)
            .frame(maxWidth: .infinity)
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
        Grid(alignment: .leading, verticalSpacing: BarMetrics.inset) {
            GridRow {
                SearchField(text: $query, prompt: prompt, handle: field, options: options, step: step, close: close)
                    .frame(minWidth: BarMetrics.fieldMinWidth, maxWidth: .infinity)
                HStack {
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
                .gridColumnAlignment(.trailing)
            }
            replace
        }
        .padding(.vertical, BarMetrics.inset)
        .paneBarControls()
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
        view.placeholderString = prompt
        // VoiceOver's name: the placeholder goes once there's text.
        view.setAccessibilityLabel(prompt)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BarMetrics.spacing) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(Typography.secondary)
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

/// A project's or a file's own actions: its context menu's, and File's for the
/// chosen item of the list with the keyboard (`offersActions`).
struct ItemActions {
    let rename: () -> Void
    let showInFinder: () -> Void
    let moveToTrash: () -> Void
}

/// Move to Trash apart from the rest.
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
        content
            .onChange(of: id, initial: true) { _, id in app.chosenItem = id.flatMap(actions) }
            .onDisappear { app.chosenItem = nil }
    }
}

/// A name edited in place: Return or clicking away commits, Escape cancels.
/// A file's name starts selected up to its extension, so typing replaces the name
/// and keeps the file's type.
struct RenameField: View {
    @Binding var text: String
    var isFile = false
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
            searched: query, step: { _ in }, close: {}) {}
        .frame(width: 480)
}
