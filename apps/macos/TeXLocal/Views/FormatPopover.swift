import AppKit
import SwiftUI

final class FormatPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let window: WindowModel
    private let views: WorkspaceViews
    private var closingClick: Int?
    private var click: Int? { NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0.eventNumber : nil } }

    init(window: WindowModel, views: WorkspaceViews) {
        self.window = window
        self.views = views
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(relativeTo item: NSToolbarItem) {
        if popover.isShown { return popover.close() }
        if let click, click == closingClick { return }
        let content = NSHostingController(rootView: FormatPanel(window: window, views: views) { [weak self] in self?.popover.close() })
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.show(relativeTo: item)
    }

    func popoverWillClose(_ notification: Notification) { closingClick = click }
    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }
}

struct FormatPanel: View {
    let window: WindowModel
    let views: WorkspaceViews
    let close: () -> Void
    @State private var hovered: String?

    var body: some View {
        let (headings, current, styles) = (views.project.headingStyles, views.project.headingCommand, views.textStyles)
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
            VStack(spacing: 1) {
                ForEach(headings, id: \.command) { style in
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
    }

    private var separator: some View { Rectangle().fill(.separator).frame(height: 0.5) }

    private func toggle(_ command: MenuCommand, on: Bool) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in window.perform(command, on: views.project) })) {
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
            views.perform(.heading(style.command))
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

    private static let fonts: [String: Font] = ["part": .title.bold(), "chapter": .title.bold(), "section": .title2.bold(),
                                                "subsection": .title3.bold(), "subsubsection": .headline, "paragraph": .headline]
}
