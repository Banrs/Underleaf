import AppKit
import SwiftUI

/// The core's completions under the caret, a view over the editor: 27.2's glass in a borderless panel that isn't key
/// draws flat, and AppKit's own completion list is still its square box. Typing stays in the document.
final class CompletionList {
    private unowned let editor: SourceTextView
    /// Nil while the list is closed.
    private(set) var offered: Completions?

    private let rows = CompletionRows()
    private lazy var surface: Surface = {
        let surface = Surface(rootView: CompletionRowsView(rows: rows) { [unowned self] in accept($0) })
        surface.sizingOptions = []
        surface.safeAreaRegions = []
        surface.wantsLayer = true
        // A menu's shadow.
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 22
        shadow.shadowColor = .shadowColor.withAlphaComponent(0.22)
        surface.shadow = shadow
        return surface
    }()

    /// A click chooses a row and leaves the keyboard in the document.
    private final class Surface: NSHostingView<CompletionRowsView> { override var acceptsFirstResponder: Bool { false } }

    init(for editor: SourceTextView) { self.editor = editor }

    /// With Settings' completion off, only a list already showing follows the typing.
    func offer() { if editor.autoComplete || offered != nil { complete(explicit: false) } }

    /// `explicit` (Escape, or Complete) offers what typing alone wouldn't.
    func complete(explicit: Bool) {
        guard editor.isEditable, editor.selectedRange().length == 0, editor.selectedRanges.count == 1, !editor.hasMarkedText(),
              let found = editor.document.completions(caret: editor.caret, explicit: explicit), !found.items.isEmpty
        else { return close() }
        offered = found
        show(reload: true)
    }

    func close() {
        guard offered != nil else { return }
        offered = nil
        surface.removeFromSuperview()
        rows.items = []
    }

    /// Closed once what it completes is out of sight.
    func follow() { show(reload: false) }

    func accept() { accept(rows.selection) }

    private func accept(_ index: Int) {
        let caret = editor.caret
        guard let offered, offered.items.indices.contains(index), caret >= offered.start else { return close() }
        let item = offered.items[index]
        close()
        let edit = TextEdit(NSRange(location: offered.start, length: caret - offered.start), item.text)
        let inserted = Insertion(edit: edit, caret: offered.start + (item.text as NSString).length, fields: item.fields)
        editor.insert(inserted, named: String(localized: "Completion"))
    }

    /// Under the start of what it completes, in the editor's scroll view.
    private func show(reload: Bool) {
        guard let offered, let window = editor.window, let host = editor.enclosingScrollView else { return }
        let start = host.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: .caret(offered.start), actualRange: nil)), from: nil)
        let shown = host.convert(editor.shownRect, from: editor)
        guard shown.contains(NSPoint(x: start.minX, y: start.midY)) else { return close() }
        guard reload else { return place(under: start, in: shown) }
        let count = rows.items.count
        let font = editor.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        (rows.items, rows.kind, rows.font) = (offered.items, offered.kind, font)
        rows.typed = editor.caret - offered.start
        rows.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        rows.height = (font.ascender - font.descender + font.leading).rounded(.up) + 8
        rows.selection = 0
        rows.reveal()
        let opening = surface.superview == nil
        fit()
        if surface.superview !== host { host.addSubview(surface) }
        place(under: start, in: shown)
        // Typing that changes the count is spoken too, after the typed character.
        if opening || rows.items.count != count { announce(interrupting: opening) }
        editor.previewMath()
    }

    /// VoiceOver's focus stays in the document: the row chosen is spoken as the list opens and as the arrows move.
    private func announce(interrupting: Bool = true) {
        guard rows.items.indices.contains(rows.selection) else { return }
        let item = rows.items[rows.selection]
        let position = String(localized: "\(rows.selection + 1) of \(rows.items.count)")
        let words = [item.label, item.detail, rows.kind.name, position].compactMap { $0 }
        var announcement = AttributedString(words.formatted(.list(type: .and, width: .narrow)))
        announcement.accessibilitySpeechAnnouncementPriority = interrupting ? .high : .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    private static let textStart = CompletionRowsView.margin + CompletionRowsView.textInset
    private var size = NSSize.zero

    private func fit() {
        let labels = rows.items.map(\.label)
        // Fixed-pitch: of the ASCII labels the longest is the widest; other scripts come from fallback fonts and are measured.
        let isASCII = { (row: Int) in labels[row].utf8.allSatisfy { $0 < 0x80 } }
        var measured = labels.indices.filter { !isASCII($0) }
        if let longest = labels.indices.filter(isASCII).max(by: { labels[$0].utf8.count < labels[$1].utf8.count }) { measured.append(longest) }
        let widest = measured.map { width(of: labels[$0]) }.max() ?? 0
        // Details are a column beside the labels', as a menu's key equivalents beside its titles. Only the longest is measured,
        // not a bibliography's thousands: a row truncates a wider one.
        let details = rows.items.compactMap(\.detail).max { $0.utf16.count < $1.utf16.count }
            .map { ($0 as NSString).size(withAttributes: [.font: rows.detailFont]).width + CompletionRowsView.detailSpacing } ?? 0
        size = NSSize(width: (widest + details + 2 * Self.textStart).rounded(.up),
                      height: CGFloat(min(labels.count, 8)) * rows.height + 2 * CompletionRowsView.margin)
    }

    /// With the typed part in bold, as the row shows it.
    private func width(of label: String) -> CGFloat {
        let text = NSMutableAttributedString(string: label, attributes: [.font: rows.font])
        text.addAttribute(.font, value: rows.boldFont, range: NSRange(location: 0, length: min(rows.typed, text.length)))
        return text.size().width
    }

    private(set) var isAbove = false

    /// An editor too short for either side has it on the one with more room, cut to whole rows.
    private func place(under start: NSRect, in editor: NSRect) {
        guard let host = surface.superview else { return }
        var frame = NSRect(origin: NSPoint(x: start.minX - Self.textStart, y: 0), size: size)
        frame.size.width = min(size.width, max(160, editor.maxX - frame.minX))
        frame.origin.x = max(editor.minX, min(frame.minX, editor.maxX - frame.width))
        let under = editor.maxY - start.maxY, over = start.minY - editor.minY
        isAbove = under < frame.height && over > under
        let room = isAbove ? over : under
        let margins = 2 * CompletionRowsView.margin
        if room < frame.height {
            let shown = max(1, ((room - margins) / rows.height).rounded(.down))
            frame.size.height = shown * rows.height + margins
        }
        frame.origin.y = isAbove ? start.minY - frame.height : start.maxY
        // The text's start is between pixels, and the glass's edge would blur.
        frame = host.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        guard frame != surface.frame else { return }
        let shorter = frame.height != surface.frame.height
        surface.frame = frame
        if shorter { rows.reveal() }
    }

    func contains(_ point: NSPoint) -> Bool { surface.superview != nil && surface.bounds.contains(surface.convert(point, from: nil)) }

    func move(_ step: Int) {
        rows.selection = max(0, min(rows.items.count - 1, rows.selection + step))
        rows.reveal()
        announce()
    }
}

@Observable final class CompletionRows {
    var items: [Completion] = []
    /// The UTF-16 units typed, which are bold.
    var typed = 0
    var kind = CompletionKind.command
    var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    var boldFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
    var detailFont: NSFont { .systemFont(ofSize: font.pointSize) }
    var height: CGFloat = 24
    var selection = 0
    /// Bumped to scroll the chosen row into view.
    private(set) var revealed = 0

    func reveal() { revealed += 1 }
}

/// An NSMenu's measures on 27.2: 13 pt corners, rows 5 pt in, the chosen one in the accent with 8 pt corners and white text.
struct CompletionRowsView: View {
    let rows: CompletionRows
    let clicked: (Int) -> Void

    static let margin: CGFloat = 5, textInset: CGFloat = 10, detailSpacing: CGFloat = 20

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows.items.indices, id: \.self) { row in
                        let chosen = row == rows.selection, detail = rows.items[row].detail
                        HStack(spacing: Self.detailSpacing) {
                            // The key whole, while its detail truncates.
                            Text(label(row)).layoutPriority(1)
                            if let detail {
                                Text(detail)
                                    .font(Font(rows.detailFont))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Color(nsColor: chosen ? .alternateSelectedControlTextColor : .labelColor))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.textInset)
                        .frame(height: rows.height)
                        .background(chosen ? Color(nsColor: .controlAccentColor) : .clear, in: .rect(cornerRadius: 8))
                        .padding(.horizontal, Self.margin)
                        .contentShape(.rect)
                        .onTapGesture { clicked(row) }
                        .help(detail ?? "")
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                        .id(row)
                    }
                }
            }
            // As a menu's: a scroller shown always would cut the labels.
            .scrollIndicators(.never)
            .padding(.vertical, Self.margin)
            .onChange(of: rows.revealed) { scroller.scrollTo(rows.selection) }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 13))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completions")
    }

    private func label(_ row: Int) -> AttributedString {
        let text = rows.items[row].label
        var label = AttributedString(text)
        label.font = Font(rows.font as CTFont)
        let typed = NSRange(location: 0, length: min(rows.typed, (text as NSString).length))
        if let range = Range(typed, in: label) { label[range].font = Font(rows.boldFont as CTFont) }
        return label
    }
}
