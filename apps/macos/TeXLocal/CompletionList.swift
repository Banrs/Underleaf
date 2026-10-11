import AppKit
import SwiftUI

/// What a completion is, for its badge (crates/texlocal-syntax `CompletionKind`).
nonisolated enum CompletionKind: String, Decodable {
    case command, environment, label, citation, entryType

    /// A letter on a coloured square, as Xcode's kinds; the colour is the editor's for the same text.
    @MainActor func badge(in theme: SyntaxTheme) -> (symbol: String, color: NSColor, name: String) {
        let colours = theme.colours
        return switch self {
        case .command: ("c.square.fill", colours.command, String(localized: "Command"))
        case .environment: ("e.square.fill", colours.argument, String(localized: "Environment"))
        case .label: ("l.square.fill", colours.argument, String(localized: "Label"))
        case .citation: ("b.square.fill", colours.argument, String(localized: "Citation"))
        case .entryType: ("t.square.fill", colours.keyword, String(localized: "Entry Type"))
        }
    }
}

/// The core's completions under the caret, as a menu that doesn't take the keyboard: a table on
/// the system's glass with a menu's metrics (macOS 27's design kit: 12 pt corners, items 6 pt
/// down and 5 pt up, their highlight 5 pt in with 8 pt corners, their content 16 pt in). The
/// glass is in the document's own window, over its content: glass in a window of its own has
/// nothing behind it to show, and draws flat grey with no edge or shadow (27.2). Typing stays in
/// the document, which moves the selection and accepts it.
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// A click chose this row.
    var clicked: (Int) -> Void = { _ in }
    var selection: Int { max(table.selectedRow, 0) }

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let glass = NSGlassEffectView()
    private var labels: [String] = []
    private var badge = CompletionKind.command.badge(in: .overleaf)
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// At most this many rows show; the rest scroll.
    private static let shownRows = 8
    private static let cell = NSUserInterfaceItemIdentifier("completion")

    private static let radius: CGFloat = 12, top: CGFloat = 6, bottom: CGFloat = 5
    private static let highlightInset: CGFloat = 5, highlightRadius: CGFloat = 8, contentInset: CGFloat = 16

    /// Selected as the list that has the keyboard, though the document has it, in a menu
    /// item's shape.
    private final class Row: NSTableRowView {
        override var isEmphasized: Bool {
            get { true }
            set {}
        }

        override func drawSelection(in dirtyRect: NSRect) {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: CompletionList.highlightInset, dy: 0),
                         xRadius: CompletionList.highlightRadius, yRadius: CompletionList.highlightRadius).fill()
        }
    }

    override init() {
        super.init()
        table.addTableColumn(NSTableColumn(identifier: Self.cell))
        table.headerView = nil
        table.style = .fullWidth
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(click)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.top, left: 0, bottom: Self.bottom, right: 0)
        // A click chooses a row and leaves the keyboard in the document.
        table.refusesFirstResponder = true
        glass.cornerRadius = Self.radius
        glass.contentView = scroll
    }

    /// Shows `labels`, all of one kind, in `font` with the first selected, their text under
    /// the typed text's start, `start`: a screen rect of `window`'s, and over `floor`, a
    /// height on the screen. Without a window it holds them unseen.
    func show(_ labels: [String], kind: CompletionKind, font: NSFont, theme: SyntaxTheme, under start: NSRect,
              over floor: CGFloat, in window: NSWindow?) {
        guard !labels.isEmpty else { return close() }
        self.labels = labels
        self.font = font
        badge = kind.badge(in: theme)
        // The system's 24 pt row at its 13 pt text, for the editor's font.
        table.rowHeight = (font.ascender - font.descender + font.leading).rounded(.up) + 8
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        // Over everything in the window, the toolbar too.
        guard let host = window?.contentView?.superview else { return }
        let opening = glass.superview == nil
        if glass.superview !== host { host.addSubview(glass, positioned: .above, relativeTo: nil) }
        fit()
        place(under: start, over: floor)
        if opening { announce() }
    }

    /// The list never has VoiceOver's focus, which stays in the document: the row chosen is
    /// spoken as the list opens and as the arrows move through it, as Xcode's list speaks it.
    private func announce() {
        guard labels.indices.contains(selection) else { return }
        let position = String(localized: "\(selection + 1) of \(labels.count)")
        var announcement = AttributedString([labels[selection], badge.name, position].formatted(.list(type: .and, width: .narrow)))
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// From the glass's leading edge to its labels' text.
    private var textStart: CGFloat = 0

    /// Sized to its rows and widest label.
    private func fit() {
        // The editor's font is monospaced: the longest label is the widest.
        guard let host = glass.superview, let longest = labels.indices.max(by: { labels[$0].count < labels[$1].count }),
              let cell = tableView(table, viewFor: nil, row: longest) as? NSTableCellView, let text = cell.textField else { return }
        var width = cell.fittingSize.width.rounded(.up)
        cell.setFrameSize(NSSize(width: width, height: table.rowHeight))
        cell.layoutSubtreeIfNeeded()
        // The table keeps its cells in from a row's ends; a label's text starts 2 pt into its frame.
        let inRow = table.frameOfCell(atColumn: 0, row: 0)
        width += table.rect(ofRow: 0).width - inRow.width
        textStart = inRow.minX + text.frame.minX + 2
        let rows = CGFloat(min(labels.count, Self.shownRows))
        glass.setFrameSize(NSSize(width: min(width, host.bounds.width / 2), height: rows * table.rowHeight + Self.top + Self.bottom))
        glass.layoutSubtreeIfNeeded()
        table.sizeLastColumnToFit()
    }

    /// Over the typed text, there being no room under it.
    private(set) var isAbove = false

    /// Moves it under `start`, a screen rect, or over it when there's no room under it down to `floor`.
    func place(under start: NSRect, over floor: CGFloat) {
        guard let host = glass.superview, let window = host.window else { return }
        var room = host.bounds
        let foot = host.convert(window.convertFromScreen(NSRect(x: 0, y: floor, width: 0, height: 0)), from: nil).minY
        room = NSRect(x: room.minX, y: foot, width: room.width, height: room.maxY - foot)
        let start = host.convert(window.convertFromScreen(start), from: nil)
        var frame = glass.frame
        frame.origin = NSPoint(x: start.minX - textStart, y: start.minY - frame.height)
        isAbove = frame.minY < room.minY
        if isAbove { frame.origin.y = start.maxY }
        frame.origin.x = max(room.minX, min(frame.minX, room.maxX - frame.width))
        glass.frame = frame
    }

    func close() {
        glass.removeFromSuperview()
        labels = []
        table.reloadData()
    }

    /// Moves the selection by `step` rows, stopping at the ends.
    func move(_ step: Int) {
        guard !labels.isEmpty else { return }
        let row = max(0, min(labels.count - 1, selection + step))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        announce()
    }

    @objc private func click() {
        if table.clickedRow >= 0 { clicked(table.clickedRow) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { labels.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cell, owner: nil) as? NSTableCellView ?? Self.makeCell()
        cell.textField?.stringValue = labels[row]
        cell.textField?.font = font
        // The letter in the text's background: white on Light's deep squares, dark on Dark's pale ones.
        cell.imageView?.image = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: badge.name)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)
                .applying(.init(paletteColors: [.textBackgroundColor, badge.color])))
        return cell
    }

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView(), image = NSImageView(), text = NSTextField(labelWithString: "")
        cell.identifier = Self.cell
        text.lineBreakMode = .byTruncatingTail
        for view in [image, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = text
        image.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: contentInset),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.leadingAnchor.constraint(equalToSystemSpacingAfter: image.trailingAnchor, multiplier: 1),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -contentInset),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
