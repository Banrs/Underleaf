import SwiftUI

/// The one set of metrics every in-window bar shares, from the kit's
/// toolbars: 8 pt around the controls, 4 pt between the controls of a
/// group, 8 pt between groups, and 16 pt separator lines. One size, the
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
    /// A search field in a bar: the width a find bar keeps before it folds
    /// its other controls, the least any field shrinks to, and the widest a
    /// filter grows.
    static let fieldWidth: CGFloat = 160
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
/// - Secondary rows, metadata and captions (the location row, the status
///   bar, line numbers beside search hits, template descriptions, sheet
///   messages): `secondary`, the small system size (11 pt) that `.small`
///   controls use.
enum Typography {
    static let sectionTitle: Font = .title3.weight(.semibold)
    static let secondary: Font = .subheadline
    static let secondaryControlSize: ControlSize = .small
    /// SF Mono at the secondary size, for AppKit text (the build log).
    static var secondaryMono: NSFont { .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }
}

extension View {
    /// A pane bar's controls: AppKit's accessory-bar buttons at the bar's
    /// size, on the chrome's background, inset from the pane's edges.
    fileprivate func paneBarControls() -> some View {
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
        HStack(spacing: BarMetrics.spacing) { content }
            .frame(height: BarMetrics.barHeight)
            .paneBarControls()
    }
}

/// Several rows of a pane's actions in one bar (the source's find and
/// replace): each row a pane bar's controls, 8 pt apart.
struct PaneBarRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: BarMetrics.inset) { content }
            .padding(.vertical, BarMetrics.inset)
            .paneBarControls()
    }
}

/// A secondary row: a pane's location (as Xcode's jump bar sits under its
/// tab bar), or the window's status. One text style and one
/// control size for all of them, so rows of the same height and role read
/// the same.
struct SecondaryBar<Content: View>: View {
    var spacing = BarMetrics.spacing
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
            .font(Typography.secondary)
            .controlSize(Typography.secondaryControlSize)
            .lineLimit(1)
            .padding(.horizontal, BarMetrics.inset)
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
            // The grouped form's own inset, so the title lines up with its
            // sections.
            .padding([.horizontal, .top], 20)
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
        var widths: [CGFloat] = []
        for (index, segment) in segments.enumerated() {
            let image = segment.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: segment.help) }
            control.setImage(image, forSegment: index)
            control.setLabel(segment.label ?? "", forSegment: index)
            control.setToolTip(segment.help, forSegment: index)
            control.setEnabled(segment.enabled && context.environment.isEnabled, forSegment: index)
            let width = Self.width(label: segment.widest ?? segment.label, image: image, font: control.font)
            control.setWidth(width, forSegment: index)
            widths.append(width)
        }
        context.coordinator.widths = widths
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    /// The width AppKit gives a segment with this content on its own: a
    /// one-segment control is its segment's width.
    private static func width(label: String?, image: NSImage?, font: NSFont?) -> CGFloat {
        let probe = NSSegmentedControl()
        probe.segmentCount = 1
        probe.font = font
        probe.setLabel(label ?? "", forSegment: 0)
        probe.setImage(image, forSegment: 0)
        return probe.intrinsicContentSize.width
    }

    @MainActor
    final class Coordinator: NSObject {
        var segments: [Segment] = []
        var widths: [CGFloat] = []

        @objc func clicked(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard segments.indices.contains(index) else { return }
            // The control is as wide as its segments, so each starts where
            // the ones before it end.
            let x = widths.prefix(index).reduce(0, +)
            let rect = NSRect(x: x, y: 0, width: widths[index], height: control.bounds.height)
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
