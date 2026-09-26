import SwiftUI

/// The pane bars' two sizes (Settings › General › Toolbar Size), the UI
/// kit's two toolbars: Unified Compact, regular 24 pt controls in 40 pt, and
/// Unified, extra-large 36 pt controls in 52 pt. The raw values are stored
/// preferences, so "compact" stays the name of the standard size.
enum PaneSize: String {
    case compact, large

    var controlSize: ControlSize { self == .large ? .extraLarge : .regular }
    var barHeight: CGFloat { self == .large ? 52 : 40 }
    /// Symbols grow with their bezels, as the kit's 36 pt toolbar controls
    /// carry larger glyphs than its 24 pt ones.
    var imageScale: Image.Scale { self == .large ? .large : .medium }
}

/// The one set of metrics every in-window bar shares, from the kit's
/// toolbars: 8 pt around the controls, 4 pt between the controls of a
/// group, 8 pt between groups, and 16 pt separator lines.
enum BarMetrics {
    /// The secondary rows: the location row, the PDF's page row and the
    /// status bar. Small 20 pt controls with 4 pt above and below.
    static let secondaryBarHeight: CGFloat = 28
    static let inset: CGFloat = 8
    static let spacing: CGFloat = 4
    static let groupSpacing: CGFloat = 8
    static let separatorHeight: CGFloat = 16
    /// Between the separate items of a secondary row's text (the status
    /// bar's build, save state and position; the PDF's freshness and page),
    /// wider than a group's so each reads as its own item.
    static let itemSpacing: CGFloat = 12
    /// A search field in a bar: the width a find bar keeps before it folds
    /// its other controls, the least any field shrinks to, and the widest a
    /// filter grows.
    static let fieldWidth: CGFloat = 160
    static let fieldMinWidth: CGFloat = 100
    static let fieldMaxWidth: CGFloat = 180
    /// Opaque, and what shows under the glass toolbar, so the toolbar and
    /// the pane bars read as one chrome block over the content. Not `.bar`:
    /// nothing scrolls under a stacked bar for it to blur.
    static let background = Color(nsColor: .windowBackgroundColor)
}

/// The app's text roles, each one of the system's text styles, so the
/// same role reads the same everywhere. SF Pro throughout; monospaced text
/// (the build log) is SF Mono at the size of the role it plays.
///
/// - Content and controls: `.body` (13 pt), the system's default.
/// - Section titles over content (the start window's New and Recent):
///   `sectionTitle`.
/// - Secondary rows, metadata and captions (the location row, the PDF's
///   page row, the status bar, line numbers beside search hits, template
///   descriptions): `secondary`, the small system size (11 pt) that
///   `.small` controls use.
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
    fileprivate func paneBarControls(_ size: PaneSize) -> some View {
        controlSize(size.controlSize)
            .imageScale(size.imageScale)
            .buttonStyle(.accessoryBar)
            .lineLimit(1)
            .padding(.horizontal, BarMetrics.inset)
            .frame(maxWidth: .infinity)
            .background(BarMetrics.background)
    }
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
        HStack(spacing: BarMetrics.spacing) { content }
            .frame(height: size.barHeight)
            .paneBarControls(size)
    }
}

/// Several rows of a pane's actions in one bar (the source's find and
/// replace): each row a pane bar's controls, 8 pt apart.
struct PaneBarRows<Content: View>: View {
    @AppStorage("paneBarSize") private var size = PaneSize.compact
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: BarMetrics.inset) { content }
            .padding(.vertical, BarMetrics.inset)
            .paneBarControls(size)
    }
}

/// A secondary row: a pane's location (as Xcode's jump bar sits under its
/// tab bar), the PDF's page, or the window's status. One text style and one
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
