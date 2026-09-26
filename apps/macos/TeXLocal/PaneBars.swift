import SwiftUI

/// The pane bars' two sizes (Settings › General › Toolbar Size), the UI
/// kit's two toolbars: Unified Compact, regular 24 pt controls in 40 pt, and
/// Unified, extra-large 36 pt controls in 52 pt. The raw values are stored
/// preferences, so "compact" stays the name of the standard size.
enum PaneSize: String {
    case compact, large

    var controlSize: ControlSize { self == .large ? .extraLarge : .regular }
    var barHeight: CGFloat { self == .large ? 52 : 40 }
}

/// What every bar shares, as the kit's toolbars measure it: 8 pt around the
/// controls, and 16 pt separator lines.
enum BarMetrics {
    /// The location row and the status bar: small 20 pt controls.
    static let secondaryBarHeight: CGFloat = 28
    static let inset: CGFloat = 8
    static let separatorHeight: CGFloat = 16
    /// Opaque, and what shows under the glass toolbar, so the toolbar and
    /// the pane bars read as one chrome block over the content. Not `.bar`:
    /// nothing scrolls under a stacked bar for it to blur.
    static let background = Color(nsColor: .windowBackgroundColor)
}

/// A pane's actions: the row under the window toolbar, in AppKit's
/// accessory-bar controls, as Finder's and Mail's in-window bars have them:
/// flat buttons that highlight on hover, a line between groups. Glass is for
/// the toolbar and for controls that float over content; these bars sit
/// above it.
struct PaneBar<Content: View>: View {
    @AppStorage("paneBarSize") private var size = PaneSize.compact
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
        .controlSize(size.controlSize)
        .buttonStyle(.accessoryBar)
        .lineLimit(1)
        .padding(.horizontal, BarMetrics.inset)
        .frame(height: size.barHeight)
        .frame(maxWidth: .infinity)
        .background(BarMetrics.background)
    }
}

/// A pane's location: the row under its actions, as Xcode's jump bar sits
/// under its tab bar, directly over the content. Its menus are borderless,
/// at the regular size: a smaller control size only shrinks their text below
/// the crumbs' beside them.
struct LocationBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .lineLimit(1)
            .padding(.horizontal, BarMetrics.inset)
            .frame(height: BarMetrics.secondaryBarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BarMetrics.background)
    }
}

/// One icon action in a pane bar's group.
struct Segment: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var help: String?
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
                    .help(item.help ?? item.title)
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

extension Text {
    /// A pop-up's chevrons after its value, as the kit's pop-up buttons draw
    /// them: the accessory-bar style draws no menu indicator. Part of the
    /// label's one Text, as the menu becomes an AppKit pop-up button that
    /// moves a label's image to the front.
    static var popUpChevron: Text {
        Text(Image(systemName: "chevron.up.chevron.down"))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}
