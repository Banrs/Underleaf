#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// The core's completions under the caret, a view over the editor: 27.2's glass in a borderless panel that isn't key
/// draws flat, and AppKit's own completion list is still its square box; UIKit has none. Typing stays in the document.
final class CompletionList {
    private unowned let editor: SourceTextView
    /// Nil while the list is closed.
    private(set) var offered: Completions?

    private let look = CompletionLook()
    private let rows: ChoiceRows<Completion>
    #if os(macOS)
    private lazy var surface: Surface = {
        let surface = Surface(rootView: CompletionRowsView(rows: rows, look: look) { [unowned self] in accept($0) })
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
    #else
    /// A tap chooses a row and leaves the keyboard in the document: no view of SwiftUI's takes it.
    private lazy var hosting: UIHostingController<CompletionRowsView> = {
        let hosting = UIHostingController(rootView: CompletionRowsView(rows: rows, look: look) { [unowned self] in accept($0) })
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        // A menu's shadow.
        hosting.view.layer.shadowOffset = CGSize(width: 0, height: 4)
        hosting.view.layer.shadowRadius = 11
        hosting.view.layer.shadowOpacity = 0.22
        return hosting
    }()
    private var surface: UIView { hosting.view }
    #endif

    init(for editor: SourceTextView) {
        self.editor = editor
        rows = ChoiceRows { [look] in [$0.label, $0.detail, look.kind.name] }
    }

    /// With Settings' completion off, only a list already showing follows the typing.
    func offer() { if editor.autoComplete || offered != nil { complete(explicit: false) } }

    /// `explicit` (Escape, or Complete) offers what typing alone wouldn't.
    func complete(explicit: Bool) {
        guard editor.isEditable, editor.selection.length == 0, editor.selections.count == 1, !editor.hasMarkedText(),
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

    /// Under the start of what it completes, in the editor's scroll view, or on the iPad in the view holding the editor.
    private func show(reload: Bool) {
        #if os(macOS)
        guard let offered, let window = editor.window, let host = editor.enclosingScrollView else { return }
        let start = host.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: .caret(offered.start), actualRange: nil)), from: nil)
        #else
        guard let offered, let host = editor.superview else { return }
        let start = host.convert(editor.caretRect(at: offered.start), from: editor)
        #endif
        let shown = host.convert(editor.shownRect, from: editor)
        guard shown.contains(CGPoint(x: start.minX, y: start.midY)) else { return close() }
        guard reload else { return place(under: start, in: shown) }
        let count = rows.items.count
        let font = editor.font ?? .monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .regular)
        (rows.items, look.kind, look.font) = (offered.items, offered.kind, font)
        look.typed = editor.caret - offered.start
        #if os(macOS)
        look.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #else
        look.boldFont = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
        #endif
        look.height = max(CompletionRowsView.leastRowHeight, (font.ascender - font.descender + font.leading).rounded(.up) + 8)
        rows.reveal()
        let opening = surface.superview == nil
        fit()
        if surface.superview !== host { host.addSubview(surface) }
        place(under: start, in: shown)
        // Typing that changes the count is spoken too, after the typed character.
        if opening || rows.items.count != count { rows.announce(interrupting: opening) }
        editor.previewMath()
    }

    private static let textStart = CompletionRowsView.margin + CompletionRowsView.textInset
    private var size = CGSize.zero

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
            .map { ($0 as NSString).size(withAttributes: [.font: look.detailFont]).width + CompletionRowsView.detailSpacing } ?? 0
        size = CGSize(width: (widest + details + 2 * Self.textStart).rounded(.up),
                      height: CGFloat(min(labels.count, 8)) * look.height + 2 * CompletionRowsView.margin)
    }

    /// With the typed part in bold, as the row shows it.
    private func width(of label: String) -> CGFloat {
        let text = NSMutableAttributedString(string: label, attributes: [.font: look.font])
        text.addAttribute(.font, value: look.boldFont, range: NSRange(location: 0, length: min(look.typed, text.length)))
        return text.size().width
    }

    private(set) var isAbove = false

    /// An editor too short for either side has it on the one with more room, cut to whole rows.
    private func place(under start: CGRect, in editor: CGRect) {
        guard let host = surface.superview else { return }
        var frame = CGRect(origin: CGPoint(x: start.minX - Self.textStart, y: 0), size: size)
        frame.size.width = min(size.width, editor.width, max(160, editor.maxX - frame.minX))
        frame.origin.x = max(editor.minX, min(frame.minX, editor.maxX - frame.width))
        let under = editor.maxY - start.maxY, over = start.minY - editor.minY
        isAbove = under < frame.height && over > under
        let room = isAbove ? over : under
        let margins = 2 * CompletionRowsView.margin
        if room < frame.height {
            let shown = max(1, ((room - margins) / look.height).rounded(.down))
            frame.size.height = shown * look.height + margins
        }
        frame.origin.y = isAbove ? start.minY - frame.height : start.maxY
        // The text's start is between pixels, and the glass's edge would blur.
        #if os(macOS)
        frame = host.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        #else
        let scale = host.traitCollection.displayScale
        frame = CGRect(x: (frame.minX * scale).rounded() / scale, y: (frame.minY * scale).rounded() / scale,
                       width: (frame.width * scale).rounded() / scale, height: (frame.height * scale).rounded() / scale)
        #endif
        guard frame != surface.frame else { return }
        let shorter = frame.height != surface.frame.height
        surface.frame = frame
        #if os(iOS)
        surface.layer.shadowPath = UIBezierPath(roundedRect: surface.bounds, cornerRadius: CompletionRowsView.corner).cgPath
        #endif
        if shorter { rows.reveal() }
    }

    #if os(macOS)
    func contains(_ point: NSPoint) -> Bool { surface.superview != nil && surface.bounds.contains(surface.convert(point, from: nil)) }
    #endif

    func move(_ step: Int) { rows.move(step) }
}

/// A list chosen from with the arrows while the keyboard stays in the document or a field: the completion list's and Open
/// Quickly's. VoiceOver's focus stays there too, so the row chosen is spoken as the list opens and as the arrows move.
@Observable final class ChoiceRows<Item> {
    /// Each new list chooses its first.
    var items: [Item] = [] { didSet { selection = 0 } }
    var selection = 0
    /// Bumped to scroll the chosen row into view.
    private(set) var revealed = 0
    /// What VoiceOver says of a row, before its place in the list.
    @ObservationIgnored private let spoken: (Item) -> [String?]

    init(spoken: @escaping (Item) -> [String?]) { self.spoken = spoken }

    func reveal() { revealed += 1 }

    /// The arrows stop at the ends.
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
    /// The UTF-16 units typed, which are bold.
    var typed = 0
    var kind = CompletionKind.command
    var font = PlatformFont.monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .regular)
    var boldFont = PlatformFont.monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .bold)
    var detailFont: PlatformFont { .systemFont(ofSize: font.pointSize) }
    var height: CGFloat = 24
}

/// An NSMenu's measures on 27.2: 13 pt corners, rows 5 pt in, the chosen one in the accent with 8 pt corners and white text.
/// On the iPad a UIMenu's: rows a touch's 44 pt, in its larger corners.
struct CompletionRowsView: View {
    let rows: ChoiceRows<Completion>
    let look: CompletionLook
    let clicked: (Int) -> Void

    #if os(macOS)
    static let margin: CGFloat = 5, textInset: CGFloat = 10, detailSpacing: CGFloat = 20, corner: CGFloat = 13, rowCorner: CGFloat = 8
    static let leastRowHeight: CGFloat = 0
    private static let text = Color(nsColor: .labelColor), chosenText = Color(nsColor: .alternateSelectedControlTextColor)
    private static let accent = Color(nsColor: .controlAccentColor)
    #else
    static let margin: CGFloat = 8, textInset: CGFloat = 12, detailSpacing: CGFloat = 20, corner: CGFloat = 24, rowCorner: CGFloat = 16
    static let leastRowHeight: CGFloat = 44
    private static let text = Color.primary, chosenText = Color.white, accent = Color.accentColor
    #endif

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
                                    .font(Font(look.detailFont))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(chosen ? Self.chosenText : Self.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.textInset)
                        .frame(height: look.height)
                        .background(chosen ? Self.accent : .clear, in: .rect(cornerRadius: Self.rowCorner))
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
        .glassEffect(.regular, in: .rect(cornerRadius: Self.corner))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Completions")
    }

    private func label(_ row: Int) -> AttributedString {
        let text = rows.items[row].label
        var label = AttributedString(text)
        label.font = Font(look.font as CTFont)
        let typed = NSRange(location: 0, length: min(look.typed, (text as NSString).length))
        if let range = Range(typed, in: label) { label[range].font = Font(look.boldFont as CTFont) }
        return label
    }
}
