import SwiftUI

/// The one set of metrics every in-window bar shares, from the UI kit's
/// macOS 27 toolbars and controls. Two heights: the bars of actions under
/// the window toolbar (the source's, the PDF's, the find bars, the build
/// panel's header) at the regular control size, and the secondary rows
/// (the location rows, the status bar) at the small.
enum BarMetrics {
    static let controlSize: ControlSize = .regular
    /// The kit's regular and small control heights, the same for its
    /// buttons, pop-ups, segmented controls and fields.
    static let controlHeight: CGFloat = 24
    static let secondaryControlHeight: CGFloat = 20
    /// Around a bar's controls, as the kit's Unified Compact toolbar sets
    /// its items 8 pt from its top, bottom and ends.
    static let inset: CGFloat = 8
    /// Between the pieces of one item (a symbol and its words), and above
    /// and below a secondary row's small controls.
    static let spacing: CGFloat = 4
    /// A bar of actions: the kit's Unified Compact toolbar, 40 pt. Every
    /// bar is this height, whatever it holds, so bars side by side line up.
    static var barHeight: CGFloat { controlHeight + 2 * inset }
    /// A secondary row: its small controls with `spacing` above and below.
    static var secondaryBarHeight: CGFloat { secondaryControlHeight + 2 * spacing }
    /// Between a bar's groups, each a bordered control or control group
    /// whose own edges part it from the next, so no line between: the
    /// kit's Unified Compact toolbar spaces its items 12 pt apart. The
    /// status bar's separate items too.
    static let itemSpacing: CGFloat = 12
    /// Between the parts of one item (the build status's symbols and
    /// counts), and either side of a status bar line: the kit's Unified
    /// toolbar spaces its items 8 pt apart.
    static let groupSpacing: CGFloat = 8
    /// The status bar's lines: the kit's toolbar separator, 1 × 16 pt.
    static let separatorHeight: CGFloat = 16
    /// The status bar's ends, whether a pane or the window's corner is
    /// beside them: under the toolbar's symbols, which the kit's toolbar
    /// sets 16 pt in (its 36 pt items 8 pt from the edge, a 20 pt symbol
    /// centred in each). Clear of the window's rounded corner.
    static let statusEndInset: CGFloat = 16
    /// A search field in a bar: the least any field shrinks to, and the
    /// widest a filter grows.
    static let fieldMinWidth: CGFloat = 100
    static let fieldMaxWidth: CGFloat = 180
    /// Opaque, and what shows under the glass toolbar, so the toolbar and
    /// the bars under it read as one chrome block over the content. Not
    /// `.bar`: nothing scrolls under a stacked bar for it to blur.
    static let background = Color(nsColor: .windowBackgroundColor)
}

/// The app's text roles, each one of the system's text styles, so the
/// same role reads the same everywhere. SF Pro throughout; monospaced text
/// (the build log) is SF Mono at the size of the role it plays.
///
/// - Content and controls: `.body` (13 pt), the system's default.
/// - Section titles over content (the start window's New and Recent) and
///   sheet titles: `sectionTitle`.
/// - Titles of a pane's groups (the inspector's Project, Document and
///   Build, bold as Xcode's inspectors have them): `groupTitle`.
/// - Secondary rows, metadata and captions (the location row, the status
///   bar, line numbers beside search hits, template descriptions, sheet
///   messages): `secondary`, the small system size (11 pt) that `.small`
///   controls use.
enum Typography {
    static let sectionTitle: Font = .title3.weight(.semibold)
    static let groupTitle: Font = .headline
    static let secondary: Font = .subheadline
    static let secondaryControlSize: ControlSize = .small
    /// SF Mono at the secondary size, for AppKit text (the build log).
    static var secondaryMono: NSFont { .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }
}

extension View {
    /// A pane bar's controls, one family in every bar: bordered controls
    /// and control groups at the regular size, on the chrome's background,
    /// inset from the pane's edges.
    func paneBarControls() -> some View {
        controlSize(BarMetrics.controlSize)
            .buttonStyle(.bordered)
            .menuStyle(.button)
            .labelStyle(.iconOnly)
            .lineLimit(1)
            .padding(.horizontal, BarMetrics.inset)
            .frame(maxWidth: .infinity)
            .background(BarMetrics.background)
    }

    /// One control as a group of its own. The system's control group is the
    /// regular size's 24 pt whatever it holds, as its neighbours are; a
    /// bordered icon button or menu alone takes its symbol's height (the
    /// ellipsis 12.5 pt, the share symbol 25.5).
    func inControlGroup() -> some View {
        ControlGroup { self }
            .fixedSize()
    }
}

/// A pane's actions: the row under the window toolbar (over the source,
/// over the PDF, the build panel's header). Each child is a group of its
/// own, a bordered control or a control group, spaced as the kit's
/// toolbar spaces its items. Not glass: these bars sit above content, not
/// over it.
struct PaneBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) { content }
            .frame(height: BarMetrics.barHeight)
            .paneBarControls()
    }
}

/// A button's symbol alone, on the line its title would take: a bordered
/// button is as tall as its label, and a symbol alone is shorter than a
/// line of text (the compact Compile came out 21 pt beside 24 pt groups).
/// A hidden title isn't read, so the button names itself for VoiceOver.
struct SymbolOnTextLine: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.icon
            configuration.title.hidden().frame(width: 0)
        }
    }
}

/// A secondary row: a pane's location (as Xcode's jump bar sits under its
/// tab bar), or the window's status. One text style and one
/// control size for all of them, so rows of the same height and role read
/// the same.
struct SecondaryBar<Content: View>: View {
    var spacing = BarMetrics.spacing
    /// From the row's ends to its items.
    var endInset = BarMetrics.inset
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
            .font(Typography.secondary)
            .controlSize(Typography.secondaryControlSize)
            .lineLimit(1)
            .padding(.horizontal, endInset)
            .frame(height: BarMetrics.secondaryBarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BarMetrics.background)
    }
}

/// A pane's chrome stacked over its content, as the source and the PDF
/// have it: its bar of actions and its location row, then its find bar
/// while that shows, then one line where the chrome meets the content.
/// Stacked, not overlaid: the bars are opaque, and text under them was only
/// hidden. No line between the bars: they are one block of chrome on one
/// background, as the toolbar over them is.
struct PaneStack<Bar: View, Location: View, Find: View, Content: View>: View {
    let finding: Bool
    @ViewBuilder var bar: Bar
    @ViewBuilder var location: Location
    @ViewBuilder var find: Find
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            bar
            location
            if finding {
                find
                    // Sliding down from the rows over it; a dissolve with
                    // Reduce Motion, as the HIG asks of slides.
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            Divider()
            content
        }
        .animation(.snappy(duration: 0.25), value: finding)
    }
}

/// One icon action in a bar's group.
struct Segment: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var enabled = true
    let action: () -> Void
}

extension Segment {
    /// A menu command; its shortcut shows in the menu, not the tooltip.
    @MainActor
    init(_ command: MenuCommand, _ systemImage: String, app: AppModel, project: ProjectModel) {
        self.init(id: command.rawValue, title: command.title, systemImage: systemImage,
                  enabled: app.isEnabled(command, on: project)) { app.perform(command, on: project) }
    }
}

/// Related icon actions side by side, icons only: the system's control
/// group, one bordered piece with a line between its segments.
struct ToolGroup: View {
    let items: [Segment]

    var body: some View {
        ControlGroup {
            ForEach(items) { item in
                Button(item.title, systemImage: item.systemImage, action: item.action)
                    .disabled(!item.enabled)
                    .help(item.title)
            }
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }
}

/// The line between the status bar's parts, `BarMetrics.groupSpacing`
/// either side.
struct ToolSeparator: View {
    var body: some View {
        Divider()
            .frame(height: BarMetrics.separatorHeight)
            .padding(.horizontal, BarMetrics.groupSpacing)
    }
}

/// Find, as Xcode's find bar has it: the field, previous / next, the count
/// (while there is room) and Done, then, for the source, a second row to
/// replace with, its field under the find field. Return and Shift-Return
/// step, Escape closes. The source's and the PDF's find bars.
struct FindBar<Replace: View>: View {
    @Binding var query: String
    let prompt: String
    let focus: Int
    var options: [SearchOption] = []
    let matches: FindMatches
    /// The query the matches are for, which the count reads.
    let searched: String
    let step: @MainActor (Int) -> Void
    let close: @MainActor () -> Void
    /// The replace row's cells, a `GridRow`: its field, then its buttons.
    @ViewBuilder var replace: Replace

    var body: some View {
        // A pane bar's controls, a row of them or two, inset as its one row is.
        Grid(alignment: .leading, horizontalSpacing: BarMetrics.itemSpacing, verticalSpacing: BarMetrics.inset) {
            GridRow {
                SearchField(text: $query, prompt: prompt, focus: focus, options: options, step: step, close: close)
                    .frame(minWidth: BarMetrics.fieldMinWidth, maxWidth: .infinity)
                HStack(spacing: BarMetrics.itemSpacing) {
                    ToolGroup(items: [
                        Segment(id: "previous", title: "Previous Match", systemImage: "chevron.up", enabled: matches.total > 0) { step(-1) },
                        Segment(id: "next", title: "Next Match", systemImage: "chevron.down", enabled: matches.total > 0) { step(1) },
                    ])
                    FindCount(label: matches.label(for: searched))
                    Button("Done") { close() }
                }
                .gridColumnAlignment(.trailing)
            }
            replace
        }
        .padding(.vertical, BarMetrics.inset)
        .frame(minHeight: BarMetrics.barHeight)
        .paneBarControls()
    }
}

extension FindBar where Replace == EmptyView {
    init(query: Binding<String>, prompt: String, focus: Int, matches: FindMatches, searched: String,
         step: @escaping @MainActor (Int) -> Void, close: @escaping @MainActor () -> Void) {
        self.init(query: query, prompt: prompt, focus: focus, matches: matches, searched: searched,
                  step: step, close: close) { EmptyView() }
    }
}

/// A menu item checked while it is the one in use (the open file, the
/// section at the cursor, the zoom), as a pop-up checks its choice;
/// choosing it acts, as a button does.
struct CheckedItem<Label: View>: View {
    let checked: Bool
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        // A toggle is the menu's checkable item; choosing the checked one
        // acts too, rather than unchecking it.
        Toggle(isOn: Binding(get: { checked }, set: { _ in action() })) { label }
    }
}

extension CheckedItem where Label == Text {
    init(_ title: String, checked: Bool, action: @escaping () -> Void) {
        self.init(checked: checked, action: action) { Text(title) }
    }
}

/// A find bar's match count, left out when the bar hasn't the room.
struct FindCount: View {
    let label: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            EmptyView()
        }
    }
}

/// A choice in a search field's own menu (Match Case, Whole Words…).
struct SearchOption {
    let title: String
    let isOn: Binding<Bool>
}

/// AppKit's search field, which SwiftUI has only as `.searchable`, in the
/// toolbar or sidebar. Return steps to the next match (Shift-Return the
/// previous) and Escape closes the bar; without `step` or `close` those
/// keys do what they usually do. `options` go in the magnifier's menu.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var focus = 0
    var options: [SearchOption] = []
    var step: (@MainActor (Int) -> Void)?
    var close: (@MainActor () -> Void)?

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: SearchField
        var focus = 0
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

    /// A search field that can be asked for focus before it is in a
    /// window: a find bar shown by ⌘F is made in the same update that asks,
    /// so it takes focus once it lands in its window.
    final class FocusingSearchField: NSSearchField {
        var wantsFocus = false

        override class var cellClass: AnyClass? {
            get { FindFieldCell.self }
            set { super.cellClass = newValue }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if wantsFocus { takeFocus() }
        }

        /// Focus, its text selected, once in a window. After this turn:
        /// the key press or menu item that asked is still being handled,
        /// and the editor it came from would keep first responder.
        func takeFocus() {
            wantsFocus = true
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsFocus, let window = self.window else { return }
                self.wantsFocus = false
                if window.firstResponder !== self.currentEditor() { window.makeFirstResponder(self) }
                self.currentEditor()?.selectAll(nil)
            }
        }
    }

    /// A find bar's field edits in a field editor of its own, which leaves
    /// Edit › Find's items to its pane (`FindMenuResponder`), so ⌘G steps
    /// the bar's matches while typing in it. The window's shared field
    /// editor answers them itself, and turns them off.
    final class FindFieldCell: NSSearchFieldCell {
        var passesFind = false
        private lazy var findEditor: NSTextView = {
            let editor = FindFieldEditor()
            editor.isFieldEditor = true
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            passesFind ? findEditor : super.fieldEditor(for: controlView)
        }
    }

    final class FindFieldEditor: NSTextView {
        override func responds(to selector: Selector!) -> Bool {
            selector != #selector(performFindPanelAction(_:)) && super.responds(to: selector)
        }
    }

    func makeNSView(context: Context) -> NSSearchField {
        let view = FocusingSearchField()
        // Only a find bar's: a filter has no matches to step.
        (view.cell as? FindFieldCell)?.passesFind = step != nil
        view.sendsSearchStringImmediately = true
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.action = #selector(Coordinator.search(_:))
        return view
    }

    /// As wide as it is offered, however narrow: the frame around it sets
    /// its least and ideal widths.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = self
        view.placeholderString = prompt
        // The SDK maps SwiftUI's sizes to AppKit's, so the field matches its neighbours.
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
        if coordinator.focus != focus {
            coordinator.focus = focus
            (view as? FocusingSearchField)?.takeFocus()
        }
    }
}

/// A small sheet that asks for a few values (a new file's name and folder,
/// a line to go to, a new project): its title and message over a grouped
/// form, Cancel and the action at its foot, the action the default
/// button. One shape for every such sheet, rather than alerts with text
/// fields, which the HIG keeps for important information.
struct DialogSheet<Fields: View>: View {
    let title: String
    var message: String?
    let action: String
    let enabled: Bool
    let submit: () -> Void
    @ViewBuilder var fields: Fields
    @Environment(\.dismiss) private var dismiss

    /// A grouped form's own inset, so the title lines up with its sections.
    private static var formInset: CGFloat { 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BarMetrics.spacing) {
                Text(title).font(Typography.sectionTitle)
                if let message {
                    Text(message)
                        .font(Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], Self.formInset)
            // On the sheet's own background: the grouped form's differs in
            // dark mode, a seam under the title and over the buttons.
            Form { fields }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
        }
        // The kit's dialogs are 390–400 pt wide.
        .frame(width: 400)
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

/// A name edited in place, as Finder renames: Return or clicking away
/// commits, Escape leaves it as it was.
struct RenameField: View {
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .labelsHidden()
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onChange(of: focused) { was, now in
                if was, !now { commit() }
            }
            // Once the context menu has closed and handed the list its focus
            // back, or the list takes it straight from the field.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                focused = true
            }
    }
}
