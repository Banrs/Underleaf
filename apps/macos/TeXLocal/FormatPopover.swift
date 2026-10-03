import AppKit
import SwiftUI

/// Aa's popover, as Notes' Aa: Bold and Italic, then the levels, the caret's checked. The menu
/// bar's Format menu and the toolbar's overflow menu keep them as plain menu items.
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

/// Bold and Italic as the standard symbols, then the levels in one size at even spacing, each
/// after how LaTeX numbers it, as Notes' lists after their markers. It opens with the caret's
/// level checked and nothing highlighted, as a menu; the arrow keys start from the checked level,
/// Return chooses, and a choice closes it, as a menu's.
struct FormatPanel: View {
    let app: AppModel
    let project: ProjectModel
    let close: () -> Void
    /// The keyboard's level, the pointer's or the arrow keys'.
    @FocusState private var focused: HeadingLevel?
    /// Highlighted once the pointer or the arrow keys have moved.
    @State private var engaged = false

    private var numbering: HeadingNumbering {
        HeadingNumbering(documentClass: project.documentClass, hasChapters: project.outline.contains { $0.level == 1 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                style(.editBold, symbol: "bold")
                style(.editItalic, symbol: "italic")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
                .padding(.horizontal, 14)
            VStack(spacing: 0) {
                ForEach(HeadingLevel.all, id: \.self) { level in
                    row(level, marker: numbering.marker(level))
                }
            }
            .padding(6)
            .onKeyPress(.downArrow) { move(by: 1) }
            .onKeyPress(.upArrow) { move(by: -1) }
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
        .onAppear { focused = project.headingLevel }
    }

    private func style(_ command: MenuCommand, symbol: String) -> some View {
        Button {
            app.perform(command, on: project)
            close()
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .help(command.title)
        .accessibilityLabel(command.title)
    }

    private func row(_ level: HeadingLevel, marker: String?) -> some View {
        let lit = engaged && focused == level
        return Button { choose(level) } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .opacity(project.headingLevel == level ? 1 : 0)
                // The widest marker sets the column, so the names line up.
                ZStack(alignment: .leading) {
                    Text(verbatim: "1.1.1").hidden()
                    Text(verbatim: marker ?? "")
                        .foregroundStyle(lit ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                }
                .monospacedDigit()
                Text(level.title)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            // A menu's highlight, which follows the pointer and the arrow keys.
            .background(lit ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
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

    private func move(by step: Int) -> KeyPress.Result {
        let levels = HeadingLevel.all
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
}

/// How a document's class numbers its headings, as its markers read: the book classes number
/// chapters and the sections in them (1.1), the article classes have no chapters. Parts are
/// Roman in both; the lowest levels go unnumbered.
nonisolated enum HeadingNumbering {
    case article, book

    private static let bookClasses: Set = ["book", "report", "memoir", "amsbook", "scrbook", "scrreprt"]

    /// A class it doesn't know numbers as a book's when the document has chapters.
    init(documentClass: String?, hasChapters: Bool) {
        self = documentClass.map(Self.bookClasses.contains) == true || hasChapters ? .book : .article
    }

    func marker(_ level: HeadingLevel) -> String? {
        switch (self, level.command) {
        case (_, "part"): "I"
        case (.book, "chapter"): "1"
        case (.book, "section"), (.article, "subsection"): "1.1"
        case (.book, "subsection"), (.article, "subsubsection"): "1.1.1"
        case (.article, "section"): "1"
        default: nil
        }
    }

    /// The class a file's `\documentclass` names, outside comments.
    static func documentClass(in text: String) -> String? {
        // A comment runs from a % that isn't escaped to the line's end.
        let code = text.replacing(/(^|[^\\])%[^\n]*/.anchorsMatchLineEndings()) { $0.1 }
        return code.firstMatch(of: /\\documentclass\s*(?:\[[^\]]*\])?\s*\{\s*([^}\s]+)\s*\}/).map { String($0.1) }
    }
}
