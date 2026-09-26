import SwiftUI

/// The one set of metrics every in-window bar shares, from the kit's
/// toolbars: 8 pt around the controls, the controls of a group abutting,
/// 8 pt between groups, and 16 pt separator lines. One size, the
/// standard one: the bars under the window toolbar (the source's and the
/// PDF's actions, the find bar, the build panel's header) and the
/// secondary rows.
@MainActor
enum BarMetrics {
    static let controlSize: ControlSize = .regular
    static let inset: CGFloat = 8
    static let spacing: CGFloat = 4
    /// A bar of actions: its controls' native height (24 pt at regular)
    /// with 8 pt above and below, the kit's Unified Compact toolbar. Every
    /// bar is its control size's height, whatever it holds, so bars side by
    /// side line up, as AppKit's do.
    static var barHeight: CGFloat { controlHeight(controlSize) + 2 * inset }
    /// The secondary rows (the location rows, the status bar): small
    /// controls (20 pt) with 4 pt above and below.
    static var secondaryBarHeight: CGFloat { controlHeight(Typography.secondaryControlSize) + 2 * spacing }
    static let groupSpacing: CGFloat = 8
    static let separatorHeight: CGFloat = 16
    /// Between the separate items of a secondary row's text (the status
    /// bar's build, save state and position), wider than a group's so each
    /// reads as its own item.
    static let itemSpacing: CGFloat = 12
    /// A search field in a bar: the least any field shrinks to, and the
    /// widest a filter grows.
    static let fieldMinWidth: CGFloat = 100
    static let fieldMaxWidth: CGFloat = 180
    /// Opaque, and what shows under the glass toolbar, so the toolbar and
    /// the bars under it read as one chrome block over the content. Not
    /// `.bar`: nothing scrolls under a stacked bar for it to blur.
    static let background = Color(nsColor: .windowBackgroundColor)

    /// A bezeled control's height at a size, as the system draws it.
    static func controlHeight(_ size: ControlSize) -> CGFloat {
        if let height = heights[size] { return height }
        let height = NSHostingView(rootView: Button("Button") {}.buttonStyle(.bordered).controlSize(size)).fittingSize.height
        heights[size] = height
        return height
    }

    private static var heights: [ControlSize: CGFloat] = [:]
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
    /// A pane bar's controls: AppKit's accessory-bar buttons at the bar's
    /// size, on the chrome's background, inset from the pane's edges.
    func paneBarControls() -> some View {
        controlSize(BarMetrics.controlSize)
            .buttonStyle(.accessoryBar)
            .lineLimit(1)
            .padding(.horizontal, BarMetrics.inset)
            .frame(maxWidth: .infinity)
            .background(BarMetrics.background)
    }
}

/// A pane's actions: the row under the window toolbar (over the source,
/// over the PDF, the build panel's header), in AppKit's accessory-bar
/// controls, as Finder's and Mail's in-window bars have them: flat buttons
/// that highlight on hover, a line between groups. Not glass: these bars
/// sit above content, not over it.
struct PaneBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Each child a group of its own (a group's controls abut), so
        // groups apart, as the source's find bar spaces them.
        HStack(spacing: BarMetrics.groupSpacing) { content }
            .frame(height: BarMetrics.barHeight)
            .paneBarControls()
    }
}

/// A secondary row: a pane's location (as Xcode's jump bar sits under its
/// tab bar), or the window's status. One text style and one
/// control size for all of them, so rows of the same height and role read
/// the same.
struct SecondaryBar<Content: View>: View {
    var spacing = BarMetrics.spacing
    /// From the row's ends to its items: the kit's 8 pt, or clear of a
    /// window corner the row meets.
    var leadingInset = BarMetrics.inset
    var trailingInset = BarMetrics.inset
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
            .font(Typography.secondary)
            .controlSize(Typography.secondaryControlSize)
            .lineLimit(1)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(height: BarMetrics.secondaryBarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BarMetrics.background)
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
    init(_ command: MenuCommand, _ systemImage: String, app: AppModel) {
        self.init(id: command.rawValue, title: command.title, systemImage: systemImage,
                  enabled: app.isEnabled(command)) { app.perform(command) }
    }
}

/// Related icon actions side by side, icons only.
struct ToolGroup: View {
    let items: [Segment]

    var body: some View {
        HStack(spacing: 0) {
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

/// The line between a bar's groups.
struct ToolSeparator: View {
    var body: some View {
        Divider().frame(height: BarMetrics.separatorHeight)
    }
}

/// A find bar's previous / next.
struct FindSteps: View {
    let enabled: Bool
    let step: (Int) -> Void

    var body: some View {
        ToolGroup(items: [
            Segment(id: "previous", title: "Previous Match", systemImage: "chevron.up", enabled: enabled) { step(-1) },
            Segment(id: "next", title: "Next Match", systemImage: "chevron.down", enabled: enabled) { step(1) },
        ])
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

    func makeNSView(context: Context) -> NSSearchField {
        let view = FocusingSearchField()
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

    /// The kit's dialogs are 390–400 pt wide.
    static var width: CGFloat { 400 }
    /// A grouped form's own inset, so the title lines up with its sections.
    static var formInset: CGFloat { 20 }

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

/// AppKit's segmented control, for what SwiftUI's control group can't do
/// and Apple's apps do with it: keep a segment at its widest label's width,
/// so the control keeps its width as the label changes (as Pages' zoom
/// keeps its own), with the label centred and no menu arrow; and open a
/// picker from a segment (Share). Momentary, as a control group's segments
/// are; each segment at the width AppKit gives it on its own, or its widest
/// label's.
struct SegmentedControl: NSViewRepresentable {
    struct Segment {
        var symbol: String?
        var label: String?
        /// The widest label the segment shows: it keeps that one's width.
        var widest: String?
        let help: String
        var enabled = true
        /// A menu to open on click, in place of `action`.
        var menu: [MenuEntry] = []
        /// Run on click, with the control and the segment's rect in it.
        var action: (NSSegmentedControl, NSRect) -> Void = { _, _ in }
    }

    enum MenuEntry {
        case item(String, checked: Bool, () -> Void)
        case separator
    }

    let segments: [Segment]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .momentary
        // A digit's width whatever the digit, so a scale's label keeps its width.
        control.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        control.target = context.coordinator
        control.action = #selector(Coordinator.clicked(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.segments = segments
        control.segmentCount = segments.count
        for (index, segment) in segments.enumerated() {
            let image = segment.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: segment.help) }
            control.setImage(image, forSegment: index)
            control.setLabel(segment.label ?? "", forSegment: index)
            control.setToolTip(segment.help, forSegment: index)
            control.setEnabled(segment.enabled && context.environment.isEnabled, forSegment: index)
            control.setWidth(Self.width(label: segment.widest ?? segment.label, symbol: segment.symbol, image: image,
                                        font: control.font), forSegment: index)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    /// The width AppKit gives a segment with this content on its own: a
    /// one-segment control is its segment's width. Measured once per
    /// content, as the scale's label changes with every pinch.
    private static func width(label: String?, symbol: String?, image: NSImage?, font: NSFont?) -> CGFloat {
        let key = "\(label ?? "")|\(symbol ?? "")"
        if let width = widths[key] { return width }
        let probe = NSSegmentedControl()
        probe.segmentCount = 1
        probe.font = font
        probe.setLabel(label ?? "", forSegment: 0)
        probe.setImage(image, forSegment: 0)
        widths[key] = probe.intrinsicContentSize.width
        return probe.intrinsicContentSize.width
    }

    private static var widths: [String: CGFloat] = [:]

    @MainActor
    final class Coordinator: NSObject {
        var segments: [Segment] = []

        @objc func clicked(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard segments.indices.contains(index) else { return }
            // The control is as wide as its segments, so each starts where
            // the ones before it end.
            let x = (0..<index).map(control.width(forSegment:)).reduce(0, +)
            let rect = NSRect(x: x, y: 0, width: control.width(forSegment: index), height: control.bounds.height)
            let segment = segments[index]
            if segment.menu.isEmpty {
                segment.action(control, rect)
            } else {
                let menu = NSMenu()
                for entry in segment.menu {
                    switch entry {
                    case .separator: menu.addItem(.separator())
                    case let .item(title, checked, run):
                        let item = ActionMenuItem(title: title, run: run)
                        item.state = checked ? .on : .off
                        menu.addItem(item)
                    }
                }
                // Under the segment, its leading edge on the segment's, as a
                // pull-down's menu opens.
                menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: control.isFlipped ? rect.maxY + 4 : -4), in: control)
            }
        }
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func runAction() { run() }
}
