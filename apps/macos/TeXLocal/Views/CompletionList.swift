import AppKit
import SwiftUI

final class CompletionList {
    private unowned let editor: SourceTextView
    private(set) var offered: Completions?

    private let look = CompletionLook()
    private let rows: ChoiceRows<Completion>
    private lazy var panel: FloatingPanel = {
        let surface = Surface(rootView: CompletionRowsView(rows: rows, look: look) { [unowned self] in accept($0) })
        surface.sizingOptions = []
        surface.safeAreaRegions = []
        let panel = FloatingPanel(takesKeys: false)
        panel.contentView = surface
        return panel
    }()

    private final class Surface: NSHostingView<CompletionRowsView> { override var acceptsFirstResponder: Bool { false } }

    init(for editor: SourceTextView) {
        self.editor = editor
        rows = ChoiceRows { [look] in [$0.label, $0.detail, look.kind.title] }
    }

    func offer() { if editor.autoComplete || offered != nil { complete(explicit: false) } }

    func complete(explicit: Bool) {
        guard editor.isEditable, editor.selection.length == 0, editor.selections.count == 1, !editor.hasMarkedText(),
              let found = editor.document.complete(caret: editor.caret, explicit: explicit), !found.items.isEmpty
        else { return close() }
        offered = found
        show(reload: true)
    }

    func close() {
        guard offered != nil else { return }
        offered = nil
        panel.dismiss()
        rows.items = []
    }

    func follow() { show(reload: false) }

    func accept() { accept(rows.selection) }

    private func accept(_ index: Int) {
        guard offered != nil else { return }
        close()
        editor.insert(editor.document.acceptCompletion(index, caret: editor.caret), named: String(localized: "Completion"))
    }

    private func show(reload: Bool) {
        guard let offered, let window = editor.window, let screen = window.screen else { return }
        let start = editor.firstRect(forCharacterRange: .caret(offered.start), actualRange: nil)
        guard window.convertToScreen(editor.convert(editor.shownRect, to: nil)).contains(CGPoint(x: start.minX, y: start.midY)) else { return close() }
        guard reload else { return place(under: start, on: screen.visibleFrame, over: window, animated: false) }
        let count = rows.items.count
        let font = editor.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        (rows.items, look.kind, look.font) = (offered.items, offered.kind, font)
        look.typed = editor.caret - offered.start
        look.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        look.height = (font.ascender - font.descender + font.leading).rounded(.up) + 8
        rows.reveal()
        let opening = !panel.isVisible
        fit()
        place(under: start, on: screen.visibleFrame, over: window, animated: true)
        if opening || rows.items.count != count { rows.announce(interrupting: opening) }
        editor.previewMath()
    }

    private static let textStart = CompletionRowsView.margin + CompletionRowsView.textInset
    private var size = CGSize.zero

    private func fit() {
        let labels = rows.items.map(\.label)
        let isASCII = { (row: Int) in labels[row].utf8.allSatisfy { $0 < 0x80 } }
        var measured = labels.indices.filter { !isASCII($0) }
        if let longest = labels.indices.filter(isASCII).max(by: { labels[$0].utf8.count < labels[$1].utf8.count }) { measured.append(longest) }
        let widest = measured.map { width(of: labels[$0]) }.max() ?? 0
        let details = rows.items.compactMap(\.detail).max { $0.utf16.count < $1.utf16.count }
            .map { ($0 as NSString).size(withAttributes: [.font: look.detailFont]).width + CompletionRowsView.detailSpacing } ?? 0
        size = CGSize(width: (widest + details + 2 * Self.textStart).rounded(.up),
                      height: CGFloat(min(labels.count, 8)) * look.height + 2 * CompletionRowsView.margin)
    }

    private func width(of label: String) -> CGFloat {
        let text = NSMutableAttributedString(string: label, attributes: [.font: look.font])
        text.addAttribute(.font, value: look.boldFont, range: NSRange(location: 0, length: min(look.typed, text.length)))
        return text.size().width
    }

    private(set) var isAbove = false

    /// Places the list under the caret's line, or over it when the screen has more room there, in a panel of its own so
    /// that it may run past the editor's column as Xcode's does; `start` and `screen` are in screen coordinates.
    private func place(under start: CGRect, on screen: CGRect, over window: NSWindow, animated: Bool) {
        var frame = CGRect(origin: CGPoint(x: start.minX - Self.textStart, y: 0), size: size)
        frame.size.width = min(size.width, screen.width)
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        let under = start.minY - screen.minY, over = screen.maxY - start.maxY
        isAbove = under < frame.height && over > under
        let room = isAbove ? over : under
        let margins = 2 * CompletionRowsView.margin
        if room < frame.height {
            let shown = max(1, ((room - margins) / look.height).rounded(.down))
            frame.size.height = shown * look.height + margins
        }
        frame.origin.y = isAbove ? start.maxY : start.minY - frame.height
        frame = window.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        let shorter = frame.height != panel.frame.height
        panel.show(frame, over: window, animated: animated)
        if shorter { rows.reveal() }
    }

    func move(_ step: Int) { rows.move(step) }
}

/// A borderless panel floating over its window as a child window, its shadow the system's, drawn from its glass's shape:
/// it fades in as it appears, and resizes at the system's pace unless Reduce Motion is on.
class FloatingPanel: NSPanel {
    private let takesKeys: Bool

    init(takesKeys: Bool) {
        self.takesKeys = takesKeys
        super.init(contentRect: .zero, styleMask: takesKeys ? [.borderless] : [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { takesKeys }

    func show(_ frame: NSRect, over window: NSWindow, animated: Bool) {
        if parent == nil {
            setFrame(frame, display: false)
            alphaValue = 0
            window.addChildWindow(self, ordered: .above)
            NSAnimationContext.runAnimationGroup { _ in animator().alphaValue = 1 }
        } else if frame != self.frame {
            let animates = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            // A zero-length group also stops a resize still running, which a plain setFrame would leave to finish.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animates ? animationResizeTime(frame) : 0
                animator().setFrame(frame, display: true)
            }
        }
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

struct ChoiceList<Item, Row: View>: View {
    let rows: ChoiceRows<Item>
    let height: CGFloat
    let truncation: Text.TruncationMode
    let chosen: (Int) -> Void
    @ViewBuilder let row: (Item) -> Row

    private static var text: Color { Color(nsColor: .labelColor) }
    private static var chosenText: Color { Color(nsColor: .alternateSelectedControlTextColor) }
    private static var accent: Color { Color(nsColor: .controlAccentColor) }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows.items.indices, id: \.self) { index in
                        let selected = index == rows.selection
                        row(rows.items[index])
                            .lineLimit(1)
                            .truncationMode(truncation)
                            .foregroundStyle(selected ? Self.chosenText : Self.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, CompletionRowsView.textInset)
                            .frame(height: height)
                            .background(selected ? Self.accent : .clear, in: .rect(cornerRadius: CompletionRowsView.rowCorner))
                            .padding(.horizontal, CompletionRowsView.margin)
                            .contentShape(.rect)
                            .onTapGesture { chosen(index) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .id(index)
                    }
                }
            }
            .scrollIndicators(.never)
            .padding(.vertical, CompletionRowsView.margin)
            .onChange(of: rows.revealed) { scroller.scrollTo(rows.selection) }
        }
    }
}

@Observable final class ChoiceRows<Item> {
    var items: [Item] = [] { didSet { selection = 0 } }
    var selection = 0
    private(set) var revealed = 0
    @ObservationIgnored private let spoken: (Item) -> [String?]

    init(spoken: @escaping (Item) -> [String?]) { self.spoken = spoken }

    func reveal() { revealed += 1 }

    func move(_ step: Int) {
        selection = max(0, min(items.count - 1, selection + step))
        reveal()
        announce()
    }

    func announce(interrupting: Bool = true) {
        guard items.indices.contains(selection) else { return }
        let words = spoken(items[selection]).compactMap(\.self) + [String(localized: "\(selection + 1) of \(items.count)")]
        var announcement = AttributedString(words.formatted(.list(type: .and, width: .narrow)))
        announcement.accessibilitySpeechAnnouncementPriority = interrupting ? .high : .low
        AccessibilityNotification.Announcement(announcement).post()
    }
}

@Observable final class CompletionLook {
    var typed = 0
    var kind = SymbolKind.command
    var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    var boldFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
    var detailFont: NSFont { .systemFont(ofSize: font.pointSize) }
    var height: CGFloat = 24
}

struct CompletionRowsView: View {
    let rows: ChoiceRows<Completion>
    let look: CompletionLook
    let clicked: (Int) -> Void

    static let margin: CGFloat = 5, textInset: CGFloat = 10, detailSpacing: CGFloat = 20, corner: CGFloat = 13, rowCorner: CGFloat = 8

    var body: some View {
        ChoiceList(rows: rows, height: look.height, truncation: .tail, chosen: clicked) { item in
            HStack(spacing: Self.detailSpacing) {
                Text(label(item)).layoutPriority(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(Font(look.detailFont))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .help(item.detail ?? "")
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Self.corner))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completions")
    }

    private func label(_ item: Completion) -> AttributedString {
        let text = item.label
        var label = AttributedString(text)
        label.font = Font(look.font as CTFont)
        let typed = NSRange(location: 0, length: min(look.typed, (text as NSString).length))
        if let range = Range(typed, in: label) { label[range].font = Font(look.boldFont as CTFont) }
        return label
    }
}
