import AppKit
import SwiftUI

/// What a completion is (crates/texlocal-syntax `CompletionKind`): every item of a list is one kind.
nonisolated enum CompletionKind: String, Decodable {
    case command, environment, label, citation, entryType

    /// As VoiceOver names it when the list opens.
    var name: String {
        switch self {
        case .command: String(localized: "Command")
        case .environment: String(localized: "Environment")
        case .label: String(localized: "Label")
        case .citation: String(localized: "Citation")
        case .entryType: String(localized: "Entry Type")
        }
    }
}

/// The core's completions under the typed text, drawn as the system draws a menu (an `NSMenu`
/// measured on 27.2, 2026-10-12): Liquid Glass with 13 pt corners, 24 pt rows at the 13 pt font
/// 5 pt in from its edges, the chosen row in the accent colour with 8 pt corners and its text
/// white 10 pt into it, under a menu's shadow. The labels are the editor's font, what's typed of
/// each heavier, and start under the typed word.
///
/// It is a view over the editor, in the document's window, and not a window of its own: glass in
/// a borderless panel that isn't key draws as a flat grey slab, a menu's material there as an
/// opaque beige one, and AppKit's own completion list for a text view is still its square
/// box from before the glass (all 27.2). So it ends at the editor's edges, as Xcode's opaque
/// panel, which this was a copy of until Daniel called that "very bad and not native", does
/// not. Typing stays in the document, which moves the selection and accepts it. At most 8 rows.
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// A click chose this row.
    var clicked: (Int) -> Void = { _ in }
    var selection: Int { max(table.selectedRow, 0) }

    private let table = NSTableView()
    /// Sized from the start, so that its views have margins to keep as it's resized.
    private let surface = Surface(frame: NSRect(x: 0, y: 0, width: leastWidth, height: leastWidth))
    private var labels: [String] = []
    /// How much of every label is typed, in UTF-16 units.
    private var typed = 0
    private var kind = CompletionKind.command
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// At most this many rows show; the rest scroll.
    private static let shownRows = 8

    private static let radius: CGFloat = 13, margin: CGFloat = 5, highlightRadius: CGFloat = 8, textInset: CGFloat = 10
    /// What a narrow editor leaves it at least, where its labels need as much.
    private static let leastWidth: CGFloat = 160

    /// The glass, with a menu's shadow. The pointer over it is the arrow, not the text's I-beam.
    private final class Surface: NSGlassEffectView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            cornerRadius = CompletionList.radius
            wantsLayer = true
            // A menu's, measured under an NSMenu on white (27.2): 13% at its foot, gone 27 pt out,
            // and less at its sides.
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowBlurRadius = 22
            shadow.shadowColor = .shadowColor.withAlphaComponent(0.22)
            self.shadow = shadow
        }

        required init?(coder: NSCoder) { fatalError() }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    }

    /// The chosen row as a menu's: the accent colour, in from the list's edges.
    private final class Row: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: CompletionList.margin, dy: 0),
                         xRadius: CompletionList.highlightRadius, yRadius: CompletionList.highlightRadius).fill()
        }

        /// The accent whether or not the list has the keyboard, which it never has.
        override var isEmphasized: Bool { get { true } set {} }
    }

    override init() {
        super.init()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion")))
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(click)
        // A click chooses a row and leaves the keyboard in the document.
        table.refusesFirstResponder = true
        table.setAccessibilityLabel(String(localized: "Completions"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        // Whole rows only: the rows' view stops at the margins.
        let content = NSView(frame: surface.bounds)
        content.autoresizingMask = [.width, .height]
        scroll.frame = content.bounds.insetBy(dx: 0, dy: Self.margin)
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        surface.contentView = content
    }

    /// Shows `labels`, all of one `kind` and each starting with the `typed` units before the
    /// caret, in `font` with the first selected, their text under the typed text's start,
    /// `start`, within `editor`, the part of `host` the text shows in: both in `host`'s
    /// coordinates. Without a host it holds them unseen.
    func show(_ labels: [String], typed: Int, kind: CompletionKind, font: NSFont, under start: NSRect, in editor: NSRect,
              of host: NSView?) {
        guard !labels.isEmpty else { return close() }
        let count = self.labels.count
        self.labels = labels
        self.typed = typed
        self.kind = kind
        self.font = font
        // A menu's 24 pt row at its 13 pt text, for the editor's font.
        table.rowHeight = lineHeight + 8
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        reveal(0)
        guard let host else { return }
        let opening = surface.superview == nil
        fit()
        if surface.superview !== host { host.addSubview(surface) }
        place(under: start, in: editor)
        // Typing that leaves fewer, or more again, is spoken too, after the typed character.
        if opening || labels.count != count { announce(interrupting: opening) }
    }

    /// The font's line, to a whole point: 16 pt at 13.
    private var lineHeight: CGFloat { (font.ascender - font.descender + font.leading).rounded(.up) }

    /// The list never has VoiceOver's focus, which stays in the document: the row chosen is
    /// spoken as the list opens and as the arrows move through it, as Xcode's list speaks it,
    /// and, without interrupting, as typing changes how many it has.
    private func announce(interrupting: Bool = true) {
        guard labels.indices.contains(selection) else { return }
        let position = String(localized: "\(selection + 1) of \(labels.count)")
        var announcement = AttributedString([labels[selection], kind.name, position].formatted(.list(type: .and, width: .narrow)))
        announcement.accessibilitySpeechAnnouncementPriority = interrupting ? .high : .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// From its leading edge to its labels' text: the chosen row's inset and the text's in it.
    private static let textStart = margin + textInset
    /// What its widest label and its rows need.
    private var size = NSSize.zero

    /// Measures its widest label, and takes the height of its rows.
    private func fit() {
        // The editor's font is fixed-pitch, so of the labels all in ASCII the longest is the widest.
        // A citation key's or a label's accents and other scripts come from a fallback font of
        // another width: each of those is measured with it.
        let isASCII = { (row: Int) in self.labels[row].utf8.allSatisfy { $0 < 0x80 } }
        var measured = labels.indices.filter { !isASCII($0) }
        if let longest = labels.indices.filter(isASCII).max(by: { labels[$0].utf8.count < labels[$1].utf8.count }) { measured.append(longest) }
        let widest = measured.map { label($0).size().width }.max() ?? 0
        size = NSSize(width: (widest + 2 * Self.textStart).rounded(.up),
                      height: CGFloat(min(labels.count, Self.shownRows)) * table.rowHeight + 2 * Self.margin)
    }

    /// Over the typed text, there being no room under it.
    private(set) var isAbove = false

    /// Moves it under `start`, hard against its line, or over it when there's no room under it
    /// down to the `editor`'s foot and there is over it. It ends at the editor's trailing edge,
    /// its labels' ends cut, unless its least width needs more, and never past the editor's sides.
    func place(under start: NSRect, in editor: NSRect) {
        guard let host = surface.superview else { return }
        var frame = NSRect(origin: NSPoint(x: start.minX - Self.textStart, y: 0), size: size)
        frame.size.width = min(size.width, max(Self.leastWidth, editor.maxX - frame.minX))
        frame.origin.x = max(editor.minX, min(frame.minX, editor.maxX - frame.width))
        // Down the screen is up a flipped view's numbers.
        let under = host.isFlipped ? start.maxY : start.minY - frame.height
        let over = host.isFlipped ? start.minY - frame.height : start.maxY
        let fits = { (y: CGFloat) in y >= editor.minY && y + frame.height <= editor.maxY }
        isAbove = !fits(under) && fits(over)
        frame.origin.y = isAbove ? over : under
        // On the display's pixels: the text's start is between them, and the glass's edge would blur.
        frame = host.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        guard frame != surface.frame else { return }
        surface.frame = frame
        table.sizeLastColumnToFit()
    }

    func close() {
        surface.removeFromSuperview()
        labels = []
        table.reloadData()
    }

    /// Moves the selection by `step` rows, stopping at the ends.
    func move(_ step: Int) {
        guard !labels.isEmpty else { return }
        let row = max(0, min(labels.count - 1, selection + step))
        table.selectRowIndexes([row], byExtendingSelection: false)
        reveal(row)
        announce()
    }

    /// Scrolls no further than brings `row` whole into view, so the rows shown stay whole ones.
    /// The table's own `scrollRowToVisible` stops 11 pt short of a row's foot in the glass (27.2).
    private func reveal(_ row: Int) {
        guard let scroll = table.enclosingScrollView else { return }
        let clip = scroll.contentView, rect = table.rect(ofRow: row)
        let y = min(rect.minY, max(clip.bounds.minY, rect.maxY - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Its rows made again with the row chosen as it is.
    func restyle() {
        guard !labels.isEmpty else { return }
        let row = selection
        table.reloadData()
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    @objc private func click() {
        if table.clickedRow >= 0 { clicked(table.clickedRow) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { labels.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }

    /// The chosen row's text is a menu's, white on the accent; the row left takes the text's colour again.
    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { view, row in
            (view.view(atColumn: 0) as? NSTableCellView)?.textField?.attributedStringValue = label(row)
        }
    }

    /// A row's label in the editor's font, what's typed of it heavier.
    private func label(_ row: Int) -> NSAttributedString {
        let colour: NSColor = row == table.selectedRow ? .alternateSelectedControlTextColor : .labelColor
        let label = NSMutableAttributedString(string: labels[row], attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: Self.oneLine])
        label.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                           range: NSRange(location: 0, length: min(typed, label.length)))
        return label
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(), text = NSTextField(labelWithAttributedString: label(row))
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.textStart),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Self.textStart),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// An attributed label wraps unless its own style says otherwise.
    private static let oneLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
}
