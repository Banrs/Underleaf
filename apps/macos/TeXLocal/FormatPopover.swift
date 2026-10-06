import AppKit
import SwiftUI

/// Aa's popover, as Notes' Aa: the styles' toggles, then the levels, the caret's checked. The
/// menu bar's Format menu and the toolbar's overflow menu keep them as plain menu items.
@MainActor
final class FormatPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let app: AppModel
    private let project: ProjectModel
    /// When it last closed: the click on Aa that closes it isn't one to open it again.
    private var closed = Date.distantPast

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
        guard Date.now.timeIntervalSince(closed) > 0.25 else { return }
        // Made anew, so it opens at the caret's level.
        let content = NSHostingController(rootView: FormatPanel(app: app, project: project) { [weak self] in
            self?.popover.close()
        })
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.show(relativeTo: item)
    }

    func popoverDidClose(_ notification: Notification) {
        closed = .now
        popover.contentViewController = nil
    }
}

/// Bold, Italic and Underline, centred, lit when the selection is in their command; then the
/// levels the document's class has, each at its weight and shape there and its size scaled into
/// Notes', at an even pitch, after its number as the class prints it. A style toggles and the popover
/// stays, as Notes' does; a level is chosen and it closes, as a menu. It opens with the caret's
/// level checked and nothing highlighted; the arrow keys start from the checked level.
struct FormatPanel: View {
    let app: AppModel
    let project: ProjectModel
    let close: () -> Void
    /// The keyboard's level, the pointer's or the arrow keys'.
    @FocusState private var focused: HeadingLevel?
    /// Highlighted once the pointer or the arrow keys have moved.
    @State private var engaged = false
    /// The selection's, read again as the text or the selection changes.
    @State private var styles = TextStyles()

    /// Notes' list markers sit a word space from their text.
    private static let markerGap: CGFloat = 4
    /// The UI kit's menu (macOS 27, Menus, Regular): an item's highlight 5 pt in from the edge with
    /// 8 pt corners, its content and the separators 16 pt in, the first item 6 pt down.
    private static let highlightInset: CGFloat = 5, highlightRadius: CGFloat = 8, contentInset: CGFloat = 16, menuTop: CGFloat = 6

    var body: some View {
        let headings = project.headingStyles
        let layout = Layout(headings)
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                toggle(.editBold, symbol: "bold", on: styles.bold != nil)
                toggle(.editItalic, symbol: "italic", on: styles.italic != nil)
                toggle(.editUnderline, symbol: "underline", on: styles.underline != nil)
            }
            .padding(.vertical, 8)
            Divider()
                .padding(.horizontal, Self.contentInset)
            VStack(spacing: 0) {
                ForEach(headings.levels, id: \.self) { level in
                    row(level, marker: headings.marker(level), layout: layout)
                }
            }
            .padding(.horizontal, Self.highlightInset)
            .padding(.vertical, Self.menuTop)
            .onKeyPress(.downArrow) { move(by: 1, in: headings.levels) }
            .onKeyPress(.upArrow) { move(by: -1, in: headings.levels) }
            .onKeyPress(.return) { chooseFocused() }
            .onKeyPress(.space) { chooseFocused() }
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
            focused = project.headingLevel
            styles = project.editor.textStyles
        }
        .onChange(of: project.editor.changes.count) {
            styles = project.editor.textStyles
        }
    }

    private func toggle(_ command: MenuCommand, symbol: String, on: Bool) -> some View {
        Toggle(command.title, systemImage: symbol, isOn: Binding(get: { on }, set: { _ in
            app.perform(command, on: project)
        }))
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
        .labelStyle(.iconOnly)
        .font(.system(size: 19))
        .frame(width: 24, height: 24)
        .help(command.title)
    }

    private func row(_ level: HeadingLevel, marker: String?, layout: Layout) -> some View {
        let lit = engaged && focused == level
        let font = layout.font(level)
        return Button { choose(level) } label: {
            HStack(spacing: 6) {
                // The kit's checkmark: bold at the menu's size.
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .opacity(project.headingLevel == level ? 1 : 0)
                HStack(alignment: .firstTextBaseline, spacing: Self.markerGap) {
                    if layout.markers > 0 {
                        Text(verbatim: marker ?? "")
                            .foregroundStyle(.secondary)
                            .frame(width: layout.markers, alignment: .trailing)
                    }
                    Text(level.title)
                }
                .font(font)
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
        .focused($focused, equals: level)
        .focusEffectDisabled()
        .onHover { inside in
            if inside {
                focused = level
                engaged = true
            }
        }
        // The level alone: the marker is the document's numbering, not the level's name.
        .accessibilityLabel(level.title)
        .accessibilityAddTraits(project.headingLevel == level ? .isSelected : [])
    }

    private func move(by step: Int, in levels: [HeadingLevel]) -> KeyPress.Result {
        let index = focused.flatMap(levels.firstIndex) ?? (step > 0 ? -1 : levels.count)
        if engaged { focused = levels[min(max(index + step, 0), levels.count - 1)] }
        engaged = true
        return .handled
    }

    private func choose(_ level: HeadingLevel) {
        project.editor.perform(.heading, level.command)
        close()
    }

    /// Return and Space choose the keyboard's level.
    private func chooseFocused() -> KeyPress.Result {
        guard let focused else { return .ignored }
        choose(focused)
        return .handled
    }

    /// The levels' fonts at the text's size, the even pitch the largest needs, and the marker
    /// column, as wide as the widest number shown in its level's font.
    struct Layout {
        private let fonts: [HeadingLevel: NSFont]
        private let shapes: [HeadingLevel: HeadingStyles.Shape]
        let pitch: CGFloat
        let markers: CGFloat

        init(_ headings: HeadingStyles) {
            var fonts: [HeadingLevel: NSFont] = [:], shapes: [HeadingLevel: HeadingStyles.Shape] = [:]
            for level in headings.levels {
                let style = headings.font(level)
                // LaTeX's sizes in Notes' range: \Huge's 2.5 times the text comes out at Notes'
                // Title, 22 points, and \large and \Large near its Subheading and Heading.
                let size = NSFont.systemFontSize * pow(style.scale, 0.58)
                var font = NSFont.systemFont(ofSize: size.rounded(), weight: style.bold ? .bold : .regular)
                if style.shape == .italic {
                    font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: 0) ?? font
                }
                fonts[level] = font
                shapes[level] = style.shape
            }
            self.fonts = fonts
            self.shapes = shapes
            // The rows' even pitch, as Notes': the largest line and a little, and at least the kit's 24 pt item.
            let line = fonts.values.map { $0.ascender - $0.descender + $0.leading }.max() ?? 16
            pitch = max(24, (line + 4).rounded(.up))
            markers = headings.levels.compactMap { level in
                headings.marker(level).map { NSAttributedString(string: $0, attributes: [.font: fonts[level]!]).size().width }
            }.max().map { $0.rounded(.up) } ?? 0
        }

        func font(_ level: HeadingLevel) -> Font {
            let font = Font(fonts[level] ?? .systemFont(ofSize: NSFont.systemFontSize))
            return shapes[level] == .smallCaps ? font.smallCaps() : font
        }
    }
}
