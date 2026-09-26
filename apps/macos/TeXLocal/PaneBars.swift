import SwiftUI

/// The one set of metrics every in-window bar shares, from the kit's
/// toolbars: 8 pt around the controls, 4 pt between the controls of a
/// group, 8 pt between groups, and 16 pt separator lines. The window
/// toolbar is the system's, at the system's size; these are the bars under
/// it (the build panel's header and the find bars) and the secondary rows.
enum BarMetrics {
    /// A bar of actions: regular 24 pt controls with 8 pt above and below,
    /// the kit's Unified Compact toolbar.
    static let barHeight: CGFloat = 40
    static let controlSize: ControlSize = .regular
    /// The secondary rows: the source's location row and the status bar.
    /// Small 20 pt controls with 4 pt above and below.
    static let secondaryBarHeight: CGFloat = 28
    static let inset: CGFloat = 8
    static let spacing: CGFloat = 4
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
}

/// Controls that float over a pane's content (the PDF's page controls and
/// its find bar): Liquid Glass capsules, as the toolbar's items are, at the
/// toolbar's size, so the two read as one control layer. The kit's XL
/// toolbar pill: large (28 pt) controls with 4 pt of glass around them, a
/// 36 pt capsule.
enum FloatingMetrics {
    static let controlSize: ControlSize = .large
    static let padding: CGFloat = 4
    /// From the capsule's ends to the first and last control: the
    /// borderless buttons draw no bezel of their own to pad them.
    static let inset: CGFloat = 12
    /// Apart from the pane's edges.
    static let margin: CGFloat = 12
    /// Between separate capsules: further apart than the container's
    /// blending distance, so they stay separate shapes.
    static let spacing: CGFloat = 8
    static let blending: CGFloat = 4
    /// Between the controls in one capsule.
    static let itemSpacing: CGFloat = 12
    /// The height a capsule takes, for the content inset that lets the
    /// last page scroll clear of it.
    static let height: CGFloat = 36
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
    /// One floating capsule of system glass holding a few controls. The
    /// buttons in it are borderless (the glass is their container, as a
    /// toolbar item's is), each in the primary colour (`onGlass()`). Regular glass, not interactive: its buttons respond, the
    /// capsule doesn't; and no `glassEffectUnion`, whose merged
    /// interactive glass glitched icons on hover.
    ///
    /// `leadsWithField`: a search field first, 4 pt from the capsule's
    /// end, so its own capsule sits concentric in the glass.
    func floatingGlass(leadsWithField: Bool = false) -> some View {
        buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .controlSize(FloatingMetrics.controlSize)
            .lineLimit(1)
            .padding(.vertical, FloatingMetrics.padding)
            .padding(.leading, leadsWithField ? FloatingMetrics.padding : FloatingMetrics.inset)
            .padding(.trailing, FloatingMetrics.inset)
            .frame(minHeight: FloatingMetrics.height)
            .glassEffect(.regular, in: .capsule)
    }
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

extension Button {
    /// A button on floating glass in the primary colour, as the toolbar's
    /// glass items are, and dimmed while disabled: borderless and
    /// accessory-bar buttons draw secondary, which read as disabled on glass.
    func onGlass() -> some View { modifier(OnGlass()) }
}

private struct OnGlass: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    }
}

/// A row of a pane's own actions (the build panel's header), in AppKit's
/// accessory-bar controls, as Finder's and Mail's in-window bars have
/// them: flat buttons that highlight on hover, a line between groups. Not glass: these bars sit above content, not over it.
/// What acts on the window's panes is in the window toolbar instead.
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
