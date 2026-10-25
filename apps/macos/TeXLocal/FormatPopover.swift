import AppKit
import SwiftUI

/// Aa's popover, as Notes' Aa: a toolbar button has no SwiftUI popover.
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
        let content = NSHostingController(rootView: FormatPanel(app: app, project: project) { [weak self] in self?.popover.close() })
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.show(relativeTo: item)
    }

    func popoverWillClose(_ notification: Notification) { closingClick = click }
    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }
}

/// Notes' Aa: the styles' toggles, lit while the selection has them, then the class's levels, each in its heading's
/// weight, the caret's checked. A style toggles and the popover stays; a level is chosen and it closes, as a menu.
struct FormatPanel: View {
    let app: AppModel
    let project: ProjectModel
    let close: () -> Void
    @State private var styles = TextStyles()
    @State private var hovered: String?

    var body: some View {
        let headings = project.headingStyles
        let current = project.headingCommand
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach([(MenuCommand.editBold, styles.bold), (.editItalic, styles.italic), (.editUnderline, styles.underline)], id: \.0) { command, edits in
                    Spacer(minLength: 0)
                    toggle(command, on: edits != nil)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            separator
                .padding(.horizontal, 7)
            // Notes' rows, measured: 10 pt in, 1 pt apart, their content 16 pt in, 8 pt corners.
            VStack(spacing: 1) {
                ForEach(headings, id: \.command) { style in
                    // Run in, apart, as Notes sets Block Quote apart from its styles.
                    if style.command == "paragraph" { separator.padding(.horizontal, -3).padding(.vertical, 6) }
                    row(style, checked: style.command == current)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Section Level")
        }
        .fixedSize()
        .onChange(of: project.editor.changes.count, initial: true) { styles = project.editor.textStyles }
    }

    /// Notes' half-point separator: a `Divider` framed to half a point still inks a whole one.
    private var separator: some View { Rectangle().fill(.separator).frame(height: 0.5) }

    /// The accessory bar's toggles draw their own hover, press and on; one size for the three, which their symbols would vary.
    private func toggle(_ command: MenuCommand, on: Bool) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in app.perform(command, on: project) })) {
            Label(command.title, systemImage: command.style!.symbol)
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .frame(width: 12, height: 16)
        }
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
        .help(command.style!.help)
    }

    private func row(_ style: HeadingStyle, checked: Bool) -> some View {
        let lit = hovered == style.command
        return Button {
            project.editor.perform(.heading(style.command))
            close()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .opacity(checked ? 1 : 0)
                    .accessibilityHidden(true)
                Text(style.title)
                    .font(Self.fonts[style.command] ?? .body)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 28)
            // A menu's highlight, on which the text turns as a selected row's does.
            .background(lit ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .environment(\.backgroundProminence, lit ? .increased : .standard)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = style.command } else if hovered == style.command { hovered = nil }
        }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    /// Larger to smaller, as Notes' Title, Heading and Subheading: a class sets each its own way.
    private static let fonts: [String: Font] = ["part": .title.bold(), "chapter": .title.bold(), "section": .title2.bold(),
                                                "subsection": .title3.bold(), "subsubsection": .headline, "paragraph": .headline]
}
