import AppKit
import SwiftUI

/// Aa's popover, as Notes' Aa: the styles' toggles, then the levels, the caret's checked.
final class FormatPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let app: AppModel
    private let project: ProjectModel
    /// The click on Aa that closed it isn't one to open it again; a click's press and release have one number.
    private var closingClick: Int?
    private var click: Int? { NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0.eventNumber : nil } }

    init(app: AppModel, project: ProjectModel) {
        self.app = app
        self.project = project
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(relativeTo item: NSToolbarItem) {
        if popover.isShown { return popover.close() }
        if let click, click == closingClick { return }
        // Made anew, so it opens at the caret's level.
        let content = NSHostingController(rootView: FormatPanel(app: app, project: project) { [weak self] in
            self?.popover.close()
        })
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.show(relativeTo: item)
    }

    func popoverWillClose(_ notification: Notification) { closingClick = click }
    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }
}

/// The styles, lit while the selection is in their command, then the class's levels in their weight and shape. A style
/// toggles and the popover stays, as in Notes; a level is chosen and it closes, as a menu. It opens with nothing
/// highlighted; the pointer highlights a level without taking the focus, the arrow keys and Tab move both, and Return
/// and Space choose the highlighted level.
struct FormatPanel: View {
    let app: AppModel
    let project: ProjectModel
    let close: () -> Void
    @FocusState private var focused: String?
    /// The level under the pointer or last reached by the keys, as a menu's highlight.
    @State private var highlighted: String?
    /// 27.2: SwiftUI hands the keyboard to the first level as the popover opens; only a key's move of it is a highlight.
    @State private var keyed = false
    @State private var styles = TextStyles()

    /// Notes' Aa, read through Accessibility (27.2): parts 7 pt apart and from the edges, dividers 7 pt in, rows at a 29 pt
    /// pitch 10 pt in with their content 16 pt in, 8 pt corners, list markers a word space from their text.
    fileprivate static let gap: CGFloat = 7, dividerInset: CGFloat = 7, rowInset: CGFloat = 10, rowGap: CGFloat = 1,
                           contentInset: CGFloat = 16, highlightRadius: CGFloat = 8, notesPitch: CGFloat = 29, markerGap: CGFloat = 4

    var body: some View {
        let headings = project.headingStyles
        let levels = headings.map(\.command)
        let layout = Layout(headings)
        // Read once: it searches the outline.
        let current = project.headingCommand
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach([(MenuCommand.editBold, styles.bold), (.editItalic, styles.italic), (.editUnderline, styles.underline)], id: \.0) { command, edits in
                    Spacer(minLength: 0)
                    toggle(command, on: edits != nil)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Self.gap)
            separator
                .padding(.horizontal, Self.dividerInset)
            VStack(spacing: Self.rowGap) {
                ForEach(headings, id: \.command) { style in
                    // The run-in levels apart, as Notes sets Block Quote apart from its styles.
                    if style == headings.first(where: \.isRunIn), style != headings.first {
                        separator
                            .padding(.horizontal, Self.dividerInset - Self.rowInset)
                            .padding(.vertical, Self.gap - Self.rowGap)
                    }
                    row(style, layout: layout, checked: style.command == current)
                }
            }
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, Self.gap)
            .onKeyPress(.downArrow) { move(by: 1, in: levels, from: current) }
            .onKeyPress(.upArrow) { move(by: -1, in: levels, from: current) }
            .onKeyPress(keys: [.return, .space]) { _ in
                guard let highlighted else { return .ignored }
                choose(highlighted)
                return .handled
            }
            // At the caret's level, as a pop-up menu opens at its item.
            .defaultFocus($focused, current)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Section Level")
        }
        .fixedSize()
        .onKeyPress(phases: .down) { _ in
            keyed = true
            return .ignored
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onChange(of: focused) { _, level in
            if keyed { highlighted = level }
        }
        .onChange(of: project.editor.changes.count, initial: true) { styles = project.editor.textStyles }
    }

    /// Notes' half-point separator: a `Divider` framed to half a point still inks a whole one.
    private var separator: some View { Rectangle().fill(.separator).frame(height: 0.5) }

    private func toggle(_ command: MenuCommand, on: Bool) -> some View {
        Toggle(command.title, systemImage: command.style!.symbol, isOn: Binding(get: { on }, set: { _ in
            app.perform(command, on: project)
        }))
        .toggleStyle(StyleTile())
        .help(command.style!.help)
    }

    /// Notes' style toggles, AppKit checkboxes read through Accessibility (27.2): 24 pt squares, here at our own pitch.
    fileprivate struct StyleTile: ToggleStyle {
        static let side: CGFloat = 24, width: CGFloat = 29

        func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration) }

        /// As Notes': lit in the accent the levels light in while on, and an off one under the pointer; an on one greys under
        /// it, the click's result to come.
        private struct Tile: View {
            let configuration: Configuration
            @State private var hovering = false

            var body: some View {
                let on = configuration.isOn, lit = on || hovering
                let fill = on && hovering ? AnyShapeStyle(.fill) : lit ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)
                Button { configuration.isOn.toggle() } label: {
                    configuration.label
                        .labelStyle(.iconOnly)
                        .imageScale(.large)
                        .foregroundStyle(.primary)
                        .frame(width: StyleTile.side, height: StyleTile.side)
                        .background(fill, in: .rect(cornerRadius: FormatPanel.highlightRadius))
                        .environment(\.backgroundProminence, lit ? .increased : .standard)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .frame(width: StyleTile.width)
                .accessibilityAddTraits(on ? [.isToggle, .isSelected] : .isToggle)
            }
        }
    }

    private func row(_ style: HeadingStyle, layout: Layout, checked: Bool) -> some View {
        let lit = highlighted == style.command
        return Button { choose(style.command) } label: {
            HStack(spacing: 6) {
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
            .padding(.horizontal, Self.contentInset - Self.rowInset)
            .frame(height: layout.pitch - Self.rowGap)
            // A menu's highlight, on which the text's styles turn as a selected row's do.
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
            if inside { highlighted = style.command } else if highlighted == style.command { highlighted = nil }
        }
        // The level alone: the marker is the document's numbering, not the level's name.
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func move(by step: Int, in levels: [String], from current: String) -> KeyPress.Result {
        // With no highlight yet, the caret's level first: the keyboard may not have reached it.
        let next = highlighted.flatMap(levels.firstIndex).map { levels[min(max($0 + step, 0), levels.count - 1)] }
            ?? (levels.contains(current) ? current : focused)
        highlighted = next
        focused = next
        return .handled
    }

    private func choose(_ command: String) {
        project.editor.perform(.heading(command))
        close()
    }

    /// The levels' fonts, the even pitch the largest needs, and the markers' column, as wide as the widest.
    struct Layout {
        private let fonts: [String: NSFont]
        let pitch: CGFloat
        let markers: CGFloat

        init(_ headings: [HeadingStyle]) {
            let fonts = Dictionary(headings.map { ($0.command, Self.font($0.font)) }) { first, _ in first }
            self.fonts = fonts
            let line = fonts.values.map { $0.ascender - $0.descender + $0.leading }.max() ?? 16
            pitch = max(FormatPanel.notesPitch, (line + 4).rounded(.up))
            markers = headings.compactMap { style in
                style.marker.map { NSAttributedString(string: $0, attributes: [.font: fonts[style.command]!]).size().width }
            }.max().map { $0.rounded(.up) } ?? 0
        }

        func font(_ style: HeadingStyle) -> Font { Font(fonts[style.command] ?? .systemFont(ofSize: NSFont.systemFontSize)) }

        /// LaTeX's sizes scaled into Notes': \Huge comes out at its Title's 22 pt, \large and \Large near its Subheading and Heading.
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
