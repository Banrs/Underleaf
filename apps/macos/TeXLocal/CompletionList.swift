import AppKit
import SwiftUI

nonisolated enum CompletionKind: String, Decodable {
    case command, environment, label, citation, entryType

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

/// A view over the editor, in the document's window, not a window of its own: glass in a borderless panel that isn't key
/// draws as a flat grey slab, a menu's material there as an opaque beige one, and AppKit's own completion list for a text
/// view is still its square box from before the glass (all 27.2). Typing stays in the document, which moves the selection and accepts it.
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var clicked: (Int) -> Void = { _ in }
    var selection: Int { max(table.selectedRow, 0) }

    private let table = NSTableView()
    /// Sized from the start, so that its views have margins to keep as it's resized.
    private let surface = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: leastWidth, height: leastWidth))
    private var labels: [String] = []
    private var typed = 0
    private var kind = CompletionKind.command
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
    private static let shownRows = 8
    private static let radius: CGFloat = 13, margin: CGFloat = 5, highlightRadius: CGFloat = 8, textInset: CGFloat = 10
    private static let leastWidth: CGFloat = 160

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
        surface.cornerRadius = Self.radius
        surface.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 22
        shadow.shadowColor = .shadowColor.withAlphaComponent(0.22)
        surface.shadow = shadow
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
        let content = NSView(frame: surface.bounds)
        content.autoresizingMask = [.width, .height]
        scroll.frame = content.bounds.insetBy(dx: 0, dy: Self.margin)
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        surface.contentView = content
    }

    func show(_ labels: [String], typed: Int, kind: CompletionKind, font: NSFont, under start: NSRect, in editor: NSRect,
              of host: NSScrollView?) {
        guard !labels.isEmpty else { return close() }
        let count = self.labels.count
        self.labels = labels
        self.typed = typed
        self.kind = kind
        self.font = font
        boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        table.rowHeight = (font.ascender - font.descender + font.leading).rounded(.up) + 8
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

    /// The list never has VoiceOver's focus, which stays in the document: the row chosen is spoken as the list opens and as the arrows move through it.
    private func announce(interrupting: Bool = true) {
        guard labels.indices.contains(selection) else { return }
        let position = String(localized: "\(selection + 1) of \(labels.count)")
        var announcement = AttributedString([labels[selection], kind.name, position].formatted(.list(type: .and, width: .narrow)))
        announcement.accessibilitySpeechAnnouncementPriority = interrupting ? .high : .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    private static let textStart = margin + textInset
    private var size = NSSize.zero

    private func fit() {
        // The editor's font is fixed-pitch, so of the labels all in ASCII the longest is the widest; accents and other scripts
        // come from a fallback font of another width and are measured.
        let isASCII = { (row: Int) in self.labels[row].utf8.allSatisfy { $0 < 0x80 } }
        var measured = labels.indices.filter { !isASCII($0) }
        if let longest = labels.indices.filter(isASCII).max(by: { labels[$0].utf8.count < labels[$1].utf8.count }) { measured.append(longest) }
        let widest = measured.map { label($0).size().width }.max() ?? 0
        size = NSSize(width: (widest + 2 * Self.textStart).rounded(.up),
                      height: CGFloat(min(labels.count, Self.shownRows)) * table.rowHeight + 2 * Self.margin)
    }

    private(set) var isAbove = false

    /// An editor too short for either has it on the side with more room: it is a view of the editor's, and what ran past the foot would be under the status bar.
    func place(under start: NSRect, in editor: NSRect) {
        guard let host = surface.superview else { return }
        var frame = NSRect(origin: NSPoint(x: start.minX - Self.textStart, y: 0), size: size)
        frame.size.width = min(size.width, max(Self.leastWidth, editor.maxX - frame.minX))
        frame.origin.x = max(editor.minX, min(frame.minX, editor.maxX - frame.width))
        // Down the screen is up a scroll view's numbers: it is flipped.
        let under = editor.maxY - start.maxY, over = start.minY - editor.minY
        isAbove = under < frame.height && over > under
        let room = isAbove ? over : under
        if room < frame.height {
            let rows = max(1, ((room - 2 * Self.margin) / table.rowHeight).rounded(.down))
            frame.size.height = rows * table.rowHeight + 2 * Self.margin
        }
        frame.origin.y = isAbove ? start.minY - frame.height : start.maxY
        // On the display's pixels: the text's start is between them, and the glass's edge would blur.
        frame = host.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        guard frame != surface.frame else { return }
        let shorter = frame.height != surface.frame.height
        surface.frame = frame
        if shorter {
            surface.layoutSubtreeIfNeeded()
            reveal(selection)
        }
    }

    func contains(_ point: NSPoint) -> Bool {
        surface.superview != nil && surface.bounds.contains(surface.convert(point, from: nil))
    }

    func close() {
        surface.removeFromSuperview()
        labels = []
        table.reloadData()
    }

    func move(_ step: Int) {
        guard !labels.isEmpty else { return }
        let row = max(0, min(labels.count - 1, selection + step))
        table.selectRowIndexes([row], byExtendingSelection: false)
        reveal(row)
        announce()
    }

    /// The table's own `scrollRowToVisible` stops 11 pt short of a row's foot in the glass (27.2).
    private func reveal(_ row: Int) {
        guard let scroll = table.enclosingScrollView else { return }
        let clip = scroll.contentView, rect = table.rect(ofRow: row)
        let y = min(rect.minY, max(clip.bounds.minY, rect.maxY - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func click() {
        if table.clickedRow >= 0 { clicked(table.clickedRow) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { labels.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { view, row in
            (view.view(atColumn: 0) as? NSTableCellView)?.textField?.attributedStringValue = label(row)
        }
    }

    private func label(_ row: Int) -> NSAttributedString {
        let colour: NSColor = row == table.selectedRow ? .alternateSelectedControlTextColor : .labelColor
        let label = NSMutableAttributedString(string: labels[row], attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: Self.oneLine])
        label.addAttribute(.font, value: boldFont, range: NSRange(location: 0, length: min(typed, label.length)))
        return label
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView {
            cell.textField?.attributedStringValue = label(row)
            return cell
        }
        let cell = NSTableCellView(), text = NSTextField(labelWithAttributedString: label(row))
        cell.identifier = Self.cellID
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

    private static let cellID = NSUserInterfaceItemIdentifier("completion")

    private static let oneLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
}
