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

/// The core's completions under the caret: a table on the system's glass, in a panel that
/// never takes the keyboard, so typing stays in the document, which moves the selection
/// and accepts it.
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// A click chose this row.
    var clicked: (Int) -> Void = { _ in }
    var selection: Int { max(table.selectedRow, 0) }

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var labels: [String] = []
    private var badge = CompletionKind.command.badge(in: .overleaf)
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// At most this many rows show; the rest scroll.
    private static let shownRows = 8
    private static let cell = NSUserInterfaceItemIdentifier("completion")

    /// Selected as the list that has the keyboard, though the document has it.
    private final class Row: NSTableRowView {
        override var isEmphasized: Bool {
            get { true }
            set {}
        }
    }

    override init() {
        super.init()
        table.addTableColumn(NSTableColumn(identifier: Self.cell))
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(click)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let glass = NSGlassEffectView()
        glass.contentView = scroll
        panel.contentView = glass
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
    }

    /// Shows `labels`, all of one kind, in `font` with the first selected, their text under
    /// the typed text's start, `start`: a screen rect of `window`'s. Without a window it
    /// holds them unseen.
    func show(_ labels: [String], kind: CompletionKind, font: NSFont, theme: SyntaxTheme, under start: NSRect, in window: NSWindow?) {
        guard !labels.isEmpty else { return close() }
        self.labels = labels
        self.font = font
        badge = kind.badge(in: theme)
        // The system's 24 pt row at its 13 pt text, for the editor's font.
        table.rowHeight = (font.ascender - font.descender + font.leading).rounded(.up) + 8
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        guard let window else { return }
        let opening = parent == nil
        parent = window
        fit()
        place(under: start)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if opening { announce() }
    }

    /// The panel never has VoiceOver's focus, which stays in the document: the row chosen is
    /// spoken as the list opens and as the arrows move through it, as Xcode's list speaks it.
    private func announce() {
        guard labels.indices.contains(selection) else { return }
        let position = String(localized: "\(selection + 1) of \(labels.count)")
        var announcement = AttributedString([labels[selection], badge.name, position].formatted(.list(type: .and, width: .narrow)))
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    private weak var parent: NSWindow?
    /// From the panel's leading edge to its labels' text.
    private var textStart: CGFloat = 0

    /// Sized to its rows and widest label, by the table's own margins round a row's cell.
    private func fit() {
        // The editor's font is monospaced: the longest label is the widest.
        guard let parent, let longest = labels.indices.max(by: { labels[$0].count < labels[$1].count }),
              let cell = tableView(table, viewFor: nil, row: longest) as? NSTableCellView, let text = cell.textField else { return }
        let content = cell.fittingSize.width.rounded(.up)
        cell.setFrameSize(NSSize(width: content, height: table.rowHeight))
        cell.layoutSubtreeIfNeeded()
        let inTable = table.frameOfCell(atColumn: 0, row: 0), row = table.rect(ofRow: 0)
        let margins = table.bounds.width - inTable.width
        // A label's text starts 2 pt into its frame.
        textStart = inTable.minX + text.frame.minX + 2
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        let rows = CGFloat(min(labels.count, Self.shownRows))
        let size = NSSize(width: min(content + margins, screen.width / 2),
                          height: rows * (row.height + table.intercellSpacing.height) + 2 * row.minY)
        if panel.contentView?.frame.size != size { panel.setContentSize(size) }
    }

    /// Over the typed text, there being no room under it.
    private(set) var isAbove = false

    /// Moves it under `start`, a screen rect, or over it when there's no room under it.
    func place(under start: NSRect) {
        guard let window = parent else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var frame = NSRect(origin: NSPoint(x: start.minX - textStart, y: start.minY - panel.frame.height), size: panel.frame.size)
        isAbove = frame.minY < screen.minY
        if isAbove { frame.origin.y = start.maxY }
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        panel.setFrame(frame, display: true)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent = nil
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
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.leadingAnchor.constraint(equalToSystemSpacingAfter: image.trailingAnchor, multiplier: 1),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
