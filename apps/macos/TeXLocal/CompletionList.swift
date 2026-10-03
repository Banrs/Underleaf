import AppKit

/// What a completion is, for its badge.
enum CompletionKind {
    case command, environment, label, citation, entryType

    /// A letter on a coloured square, as Xcode's kinds; the colour is the editor's for the same text.
    var badge: (symbol: String, color: NSColor, name: String) {
        switch self {
        case .command: ("c.square.fill", .syntaxCommand, String(localized: "Command"))
        case .environment: ("e.square.fill", .syntaxArgument, String(localized: "Environment"))
        case .label: ("l.square.fill", .syntaxArgument, String(localized: "Label"))
        case .citation: ("b.square.fill", .syntaxArgument, String(localized: "Citation"))
        case .entryType: ("t.square.fill", .syntaxKeyword, String(localized: "Entry Type"))
        }
    }
}

/// The core's completions under the caret, as Xcode's: a list in system glass
/// in a panel that never takes the keyboard, so typing stays in the document,
/// which moves the selection and accepts it.
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// A click chose this row.
    var clicked: (Int) -> Void = { _ in }
    private(set) var selection = 0

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [(label: String, kind: CompletionKind)] = []
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// The table's own row height, for the system font.
    private let systemRowHeight: CGFloat
    /// At most this many rows show; the rest scroll.
    private static let shownRows = 8

    override init() {
        systemRowHeight = table.rowHeight
        super.init()
        let column = NSTableColumn(identifier: .init("completion"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(click)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let glass = NSGlassEffectView()
        glass.contentView = scroll
        panel.contentView = glass
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
    }

    /// Shows `rows` in `font` with the first selected, the labels' text under
    /// the typed text's start, `start`: a screen rect of `window`'s. Without a
    /// window it holds them unseen.
    func show(_ rows: [(label: String, kind: CompletionKind)], font: NSFont, under start: NSRect, in window: NSWindow?) {
        self.rows = rows
        self.font = font
        let line = { (font: NSFont) in (font.ascender - font.descender + font.leading).rounded(.up) }
        table.rowHeight = systemRowHeight + max(0, line(font) - line(.systemFont(ofSize: NSFont.systemFontSize)))
        table.reloadData()
        select(0)
        guard let window else { return }
        // Laid out first at a provisional width, for the margins round a label's text.
        let height = table.rect(ofRow: min(rows.count, Self.shownRows) - 1).maxY + table.rect(ofRow: 0).minY
        panel.setContentSize(NSSize(width: NSFont.systemFontSize * 20, height: height))
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let content = panel.contentView,
              let text = (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField
        else { return }
        let field = content.convert(text.bounds, from: text)
        // As the label draws it, with its own padding; then the first row's again.
        let widest = rows.map { row -> CGFloat in
            text.stringValue = row.label
            return text.cell?.cellSize.width ?? text.intrinsicContentSize.width
        }.max() ?? 0
        text.stringValue = rows[0].label
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        textInset = field.minX
        panel.setContentSize(NSSize(width: min(field.minX + widest.rounded(.up) + content.bounds.width - field.maxX, screen.width / 2),
                                    height: height))
        place(under: start, in: window)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
    }

    /// From the window's left to its labels' text.
    private var textInset: CGFloat = 0

    /// Over the typed text, there being no room under it.
    private(set) var isAbove = false

    /// Moves it under `start`, a screen rect, or over it when there's no room under it.
    func place(under start: NSRect, in parent: NSWindow? = nil) {
        guard let window = parent ?? panel.parent else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var frame = NSRect(origin: NSPoint(x: start.minX - textInset, y: start.minY - panel.frame.height), size: panel.frame.size)
        isAbove = frame.minY < screen.minY
        if isAbove { frame.origin.y = start.maxY }
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        panel.setFrame(frame, display: true)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        rows = []
        table.reloadData()
    }

    /// Moves the selection by `step` rows, stopping at the ends.
    func move(_ step: Int) {
        select(max(0, min(rows.count - 1, selection + step)))
    }

    private func select(_ row: Int) {
        selection = row
        guard rows.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func click() {
        if rows.indices.contains(table.clickedRow) { clicked(table.clickedRow) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Cell.identifier, owner: nil) as? Cell ?? Cell()
        let (label, kind) = rows[row], badge = kind.badge
        cell.textField?.stringValue = label
        cell.textField?.font = font
        cell.imageView?.image = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: badge.name)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, badge.color])))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // A click moves it too, before its action.
        if table.selectedRow >= 0 { selection = table.selectedRow }
    }

    /// Selected as the list that has the keyboard, though the document has it.
    private final class Row: NSTableRowView {
        override var isEmphasized: Bool {
            get { true }
            set {}
        }
    }

    /// The badge, then the label at the system's spacing.
    private final class Cell: NSTableCellView {
        static let identifier = NSUserInterfaceItemIdentifier("completion")

        init() {
            super.init(frame: .zero)
            identifier = Self.identifier
            let image = NSImageView(), text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            for view in [image, text] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            image.setContentHuggingPriority(.required, for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: leadingAnchor),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.leadingAnchor.constraint(equalToSystemSpacingAfter: image.trailingAnchor, multiplier: 1),
                text.trailingAnchor.constraint(equalTo: trailingAnchor),
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            imageView = image
            textField = text
        }

        required init?(coder: NSCoder) { nil }
    }
}
