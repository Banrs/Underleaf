import AppKit
import SwiftUI

/// Aa's popover, as Notes' Aa: the styles' toggles, then the levels, the caret's checked. The
/// menu bar's Format menu and the toolbar's overflow menu keep them as plain menu items.
final class FormatPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let app: AppModel
    private let project: ProjectModel
    /// The click that closed it, when one did: on Aa, it isn't one to open it again.
    private var closingClick: Int?

    /// The mouse click being handled; its press and release have one number.
    private var click: Int? {
        NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0.eventNumber : nil }
    }

    init(app: AppModel, project: ProjectModel) {
        self.app = app
        self.project = project
        super.init()
        // Escape and a click elsewhere close it.
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(relativeTo item: NSToolbarItem) {
        if popover.isShown {
            popover.close()
            return
        }
        if let click, click == closingClick { return }
        // Made anew, so it opens at the caret's level.
        let content = NSHostingController(rootView: FormatPanel(app: app, project: project) { [weak self] in
            self?.popover.close()
        })
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.show(relativeTo: item)
    }

    func popoverWillClose(_ notification: Notification) {
        closingClick = click
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}

/// Bold, Italic and Underline, centred, lit when the selection is in their command; then the
/// levels the document's class has (the core's `heading_styles`), each at its weight and shape
/// there and its size scaled into Notes', at an even pitch, after its number as the class prints
/// it. A style toggles and the popover stays, as Notes' does; a level is chosen and it closes, as
/// a menu. It opens with the caret's level checked and nothing highlighted; the arrow keys start
/// from the checked level, and the pointer highlights a level without taking the keyboard's focus
/// to it. The highlight is also the keyboard's focus, which draws no ring: Tab shows where it is,
/// and Return and Space act only on a highlighted level. Levels go by their commands.
struct FormatPanel: View {
    let app: AppModel
    let project: ProjectModel
    let close: () -> Void
    /// The keyboard's level, which the arrow keys move.
    @FocusState private var focused: String?
    /// The level under the pointer or last reached by the arrow keys, as a menu's highlight.
    @State private var highlighted: String?
    /// Set while the caret's level is given the keyboard on opening, which isn't a move to highlight.
    @State private var seeding = false
    /// The selection's, read again as the text or the selection changes.
    @State private var styles = TextStyles()

    /// Notes' list markers sit a word space from their text.
    private static let markerGap: CGFloat = 4
    /// The UI kit's menu (macOS 27, Menus, Regular): an item's highlight 5 pt in from the edge with
    /// 8 pt corners, its content and the separators 16 pt in, the first item 6 pt down.
    fileprivate static let highlightInset: CGFloat = 5, highlightRadius: CGFloat = 8, contentInset: CGFloat = 16, menuTop: CGFloat = 6

    var body: some View {
        let headings = project.headingStyles
        let levels = headings.map(\.command)
        let layout = Layout(headings)
        // Read once: it searches the outline.
        let current = project.headingCommand
        VStack(spacing: 0) {
            // The three share the width, edge to edge with the levels' highlights below.
            HStack(spacing: Self.highlightInset) {
                toggle(.editBold, symbol: "bold", on: styles.bold != nil, help: "Make text bold")
                toggle(.editItalic, symbol: "italic", on: styles.italic != nil, help: "Make text italic")
                toggle(.editUnderline, symbol: "underline", on: styles.underline != nil, help: "Underline text")
            }
            .padding(.horizontal, Self.highlightInset)
            .padding(.vertical, Self.menuTop)
            Divider()
                .padding(.horizontal, Self.contentInset)
            VStack(spacing: 0) {
                ForEach(headings, id: \.command) { style in
                    row(style, layout: layout, checked: style.command == current)
                }
            }
            .padding(.horizontal, Self.highlightInset)
            .padding(.vertical, Self.menuTop)
            .onKeyPress(.downArrow) { move(by: 1, in: levels) }
            .onKeyPress(.upArrow) { move(by: -1, in: levels) }
            .onKeyPress(keys: [.return, .space]) { _ in chooseFocused() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Section Level")
        }
        .fixedSize()
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        // At the caret's level, as a pop-up menu opens at its item.
        .onAppear {
            seeding = levels.contains(current)
            focused = current
        }
        .onChange(of: focused) { _, level in
            if seeding {
                seeding = false
            } else {
                highlighted = level
            }
        }
        .onChange(of: project.editor.changes.count, initial: true) {
            styles = project.editor.textStyles
        }
    }

    private func toggle(_ command: MenuCommand, symbol: String, on: Bool, help: LocalizedStringKey) -> some View {
        Toggle(command.title, systemImage: symbol, isOn: Binding(get: { on }, set: { _ in
            app.perform(command, on: project)
        }))
        .toggleStyle(GlassTile())
        // What it does, as the toolbar's own buttons for these say (HIG, Offering help).
        .help(help)
    }

    /// Notes' style toggles: the symbol alone, on a tile of the accent's glass while on, as wide as its share of the row.
    private struct GlassTile: ToggleStyle {
        /// Notes' tile's height.
        private static let side: CGFloat = 24

        func makeBody(configuration: Configuration) -> some View {
            Button { configuration.isOn.toggle() } label: {
                configuration.label
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, minHeight: Self.side, maxHeight: Self.side)
                    .glassEffect(configuration.isOn ? .regular.tint(.accentColor).interactive() : .identity,
                                 in: .rect(cornerRadius: FormatPanel.highlightRadius))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : .isToggle)
        }
    }

    private func row(_ style: HeadingStyle, layout: Layout, checked: Bool) -> some View {
        let lit = highlighted == style.command
        return Button { choose(style.command) } label: {
            HStack(spacing: 6) {
                // The kit's checkmark: bold at the menu's size.
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .opacity(checked ? 1 : 0)
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: Self.markerGap) {
                    if layout.markers > 0 {
                        Text(verbatim: style.marker ?? "")
                            .foregroundStyle(.secondary)
                            .frame(width: layout.markers, alignment: .trailing)
                    }
                    Text(style.title)
                }
                .font(layout.font(style))
                Spacer(minLength: 12)
            }
            .padding(.horizontal, Self.contentInset - Self.highlightInset)
            .frame(height: layout.pitch)
            // A menu's highlight, the system's tint, which follows the pointer and the arrow keys;
            // on it the text's styles turn as a selected row's do.
            .foregroundStyle(.primary)
            .background(lit ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: Self.highlightRadius))
            .environment(\.backgroundProminence, lit ? .increased : .standard)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused, equals: style.command)
        .focusEffectDisabled()
        .onHover { inside in
            if inside {
                highlighted = style.command
            } else if highlighted == style.command {
                highlighted = nil
            }
        }
        // The level alone: the marker is the document's numbering, not the level's name.
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func move(by step: Int, in levels: [String]) -> KeyPress.Result {
        // From the highlight; with none yet, the keyboard's own level is highlighted first.
        let next = highlighted.flatMap(levels.firstIndex).map { levels[min(max($0 + step, 0), levels.count - 1)] } ?? focused
        highlighted = next
        focused = next
        return .handled
    }

    private func choose(_ command: String) {
        project.editor.perform(.heading(command))
        close()
    }

    /// Return and Space choose the highlighted level.
    private func chooseFocused() -> KeyPress.Result {
        guard let highlighted else { return .ignored }
        choose(highlighted)
        return .handled
    }

    /// The levels' fonts at the text's size, the even pitch the largest needs, and the marker
    /// column, as wide as the widest number shown in its level's font.
    struct Layout {
        private let fonts: [String: NSFont]
        let pitch: CGFloat
        let markers: CGFloat

        init(_ headings: [HeadingStyle]) {
            let fonts = Dictionary(headings.map { ($0.command, Self.font($0.font)) }) { first, _ in first }
            self.fonts = fonts
            // The rows' even pitch, as Notes': the largest line and a little, and at least the kit's 24 pt item.
            let line = fonts.values.map { $0.ascender - $0.descender + $0.leading }.max() ?? 16
            pitch = max(24, (line + 4).rounded(.up))
            markers = headings.compactMap { style in
                style.marker.map { NSAttributedString(string: $0, attributes: [.font: fonts[style.command]!]).size().width }
            }.max().map { $0.rounded(.up) } ?? 0
        }

        func font(_ style: HeadingStyle) -> Font {
            Font(fonts[style.command] ?? .systemFont(ofSize: NSFont.systemFontSize))
        }

        /// A level at its weight and shape, its size LaTeX's scaled into Notes' range: \Huge's 2.5 times the text comes
        /// out at Notes' Title, 22 points, and \large and \Large near its Subheading and Heading.
        private static func font(_ style: HeadingStyle.Font) -> NSFont {
            let size = (NSFont.systemFontSize * pow(style.scale, 0.58)).rounded()
            var descriptor = NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular).fontDescriptor
            switch style.shape {
            case .upright: break
            case .italic: descriptor = descriptor.withSymbolicTraits(.italic)
            case .smallCaps:
                descriptor = descriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                                                                              .selectorIdentifier: kLowerCaseSmallCapsSelector]]])
            }
            return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        }
    }
}
