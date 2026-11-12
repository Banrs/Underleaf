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
        guard let offered else { return }
        close()
        guard offered.items.indices.contains(index), editor.caret >= offered.start else { return }
        let item = offered.items[index]
        let edit = TextEdit(start: offered.start, length: editor.caret - offered.start, text: item.text)
        let insertion = Insertion(edit: edit, caret: offered.start + item.text.utf16.count, fields: item.fields)
        editor.insert(insertion, named: String(localized: "Completion"))
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

    static let margin: CGFloat = 5, textInset: CGFloat = 10, detailSpacing: CGFloat = 20, corner: CGFloat = 13

    var body: some View {
        ChoiceList(rows: rows, height: look.height, corner: Self.corner, truncation: .tail, chosen: clicked) { item in
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
