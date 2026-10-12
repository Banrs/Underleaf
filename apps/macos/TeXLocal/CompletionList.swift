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

/// The core's completions under the typed text, as Xcode 27's list (measured from Xcode 27.1,
/// 2026-10-11): an opaque panel of its own with rounded corners and a 1 pt inner line, 22 pt
/// rows at the 13 pt font with 5 pt round them, the chosen row raised from the ground with 5 pt
/// corners and the others fainter, a 16 pt badge 10 pt into it and the label after, what's typed
/// of it stronger. At least 258 pt wide, and at most 8 rows. Typing stays in the document, which moves the
/// selection and accepts it.
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// A click chose this row.
    var clicked: (Int) -> Void = { _ in }
    var selection: Int { max(table.selectedRow, 0) }

    private let table = Table()
    private let scroll = NSScrollView()
    /// Sized from the start, so that its views have margins to keep as it's resized.
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: minimumWidth, height: minimumWidth),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var labels: [String] = []
    /// How much of every label is typed, in UTF-16 units.
    private var typed = 0
    private var badge = CompletionKind.command.badge(in: .overleaf)
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// At most this many rows show; the rest scroll.
    private static let shownRows = 8

    private static let radius: CGFloat = 8.5, margin: CGFloat = 5, minimumWidth: CGFloat = 258
    private static let highlightRadius: CGFloat = 5, contentInset: CGFloat = 10, badgeGap: CGFloat = 2
    /// A square symbol's side over its point size.
    private static let squareSide: CGFloat = 0.9

    /// Xcode shows the rows not chosen at 85%, and what isn't typed of a label as secondary text:
    /// together about 3:1 in Light. With Increase Contrast every row is whole and all of its
    /// label the text's colour, the typed part heavier still.
    private static var increasesContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    private static var faint: CGFloat { increasesContrast ? 1 : 0.85 }

    /// The rows over the chosen one's ground, which is raised as Xcode's: a control's face in
    /// Light and the fill that lightens in Dark, with a shadow that falls on the rows beside it,
    /// so it is drawn beneath them all.
    private final class Table: NSTableView {
        override func drawBackground(inClipRect clipRect: NSRect) {
            super.drawBackground(inClipRect: clipRect)
            guard selectedRow >= 0 else { return }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let pill = NSBezierPath(roundedRect: rect(ofRow: selectedRow).insetBy(dx: CompletionList.margin, dy: 0),
                                    xRadius: CompletionList.highlightRadius, yRadius: CompletionList.highlightRadius)
            // The shadow alone, round the pill: Dark's fill is translucent, and would cast next to none.
            NSGraphicsContext.saveGraphicsState()
            let around = NSBezierPath(rect: bounds)
            around.append(pill)
            around.windingRule = .evenOdd
            around.addClip()
            let shadow = NSShadow()
            // Xcode's, measured: a point down, soft over 16 pt, and stronger on the dark ground.
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 16
            shadow.shadowColor = .shadowColor.withAlphaComponent(dark ? 0.38 : 0.17)
            shadow.set()
            NSColor.black.setFill()
            pill.fill()
            NSGraphicsContext.restoreGraphicsState()
            (dark ? NSColor.secondarySystemFill : .controlColor).setFill()
            pill.fill()
        }
    }

    override init() {
        super.init()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion")))
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(click)
        // A click chooses a row and leaves the keyboard in the document.
        table.refusesFirstResponder = true
        table.setAccessibilityLabel(String(localized: "Completions"))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        let ground = NSBox()
        ground.boxType = .custom
        ground.cornerRadius = Self.radius
        ground.fillColor = .untintedUnderPageBackground
        ground.borderColor = .tertiarySystemFill
        guard let content = panel.contentView else { return }
        ground.frame = content.bounds
        // Whole rows only: the rows' view stops at the margins.
        scroll.frame = content.bounds.insetBy(dx: 0, dy: Self.margin)
        for view in [ground, scroll] {
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }
        // Clear round the ground's corners, which the window's shadow then follows.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
    }

    /// Shows `labels`, all of one kind and each starting with the `typed` units before the
    /// caret, in `font` with the first selected, their text under the typed text's start,
    /// `start`, in the `editor`'s part of the screen, of `window`'s. Without a window it holds
    /// them unseen.
    func show(_ labels: [String], typed: Int, kind: CompletionKind, font: NSFont, theme: SyntaxTheme, under start: NSRect,
              in editor: NSRect, of window: NSWindow?) {
        guard !labels.isEmpty else { return close() }
        let count = self.labels.count
        self.labels = labels
        self.typed = typed
        self.font = font
        badge = kind.badge(in: theme)
        // Xcode's 22 pt row at its 13 pt text, for the editor's font.
        table.rowHeight = lineHeight + 6
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        guard let window else { return }
        let opening = panel.parent == nil
        fit()
        place(under: start, in: editor, on: window.screen)
        if panel.parent !== window {
            panel.appearanceSource = window
            window.addChildWindow(panel, ordered: .above)
        }
        // Typing that leaves fewer is spoken too, after the typed character.
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
        var announcement = AttributedString([labels[selection], badge.name, position].formatted(.list(type: .and, width: .narrow)))
        announcement.accessibilitySpeechAnnouncementPriority = interrupting ? .high : .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// From the panel's leading edge to its labels' text.
    private var textStart: CGFloat = 0
    /// Wide enough for its widest label.
    private var width = CompletionList.minimumWidth

    /// Measures its widest label, and takes the height of its rows.
    private func fit() {
        // The editor's font is fixed-pitch, so of the labels all in ASCII the longest is the widest.
        // A citation key's or a label's accents and other scripts come from a fallback font of
        // another width: each of those is measured with it.
        let isASCII = { (row: Int) in self.labels[row].utf8.allSatisfy { $0 < 0x80 } }
        var measured = labels.indices.filter { !isASCII($0) }
        if let longest = labels.indices.filter(isASCII).max(by: { labels[$0].utf8.count < labels[$1].utf8.count }) { measured.append(longest) }
        guard let widest = zip(measured, measured.map { label($0).size().width }).max(by: { $0.1 < $1.1 })?.0,
              let cell = tableView(table, viewFor: nil, row: widest) as? NSTableCellView, let text = cell.textField else { return }
        width = max(cell.fittingSize.width.rounded(.up), Self.minimumWidth)
        cell.setFrameSize(NSSize(width: width, height: table.rowHeight))
        cell.layoutSubtreeIfNeeded()
        // A label's text starts 2 pt into its frame.
        textStart = text.frame.minX + 2
        let rows = CGFloat(min(labels.count, Self.shownRows))
        panel.setContentSize(NSSize(width: width, height: rows * table.rowHeight + 2 * Self.margin))
    }

    /// Over the typed text, there being no room under it.
    private(set) var isAbove = false

    /// Moves it under `start`, a screen rect, hard against its line, or over it when there's no
    /// room under it down to the `editor`'s foot and the screen's. It ends at the editor's
    /// trailing edge, its labels' ends cut, unless its least width needs more, and never off
    /// the screen's sides: Xcode's only ends at the screen's.
    func place(under start: NSRect, in editor: NSRect, on screen: NSScreen? = nil) {
        guard let room = (screen ?? panel.screen ?? panel.parent?.screen)?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = start.minX - textStart
        frame.size.width = min(width, max(Self.minimumWidth, editor.maxX - frame.minX))
        frame.origin.x = max(room.minX, min(frame.minX, room.maxX - frame.width))
        frame.origin.y = start.minY - frame.height
        isAbove = frame.minY < max(editor.minY, room.minY) && start.maxY + frame.height <= room.maxY
        if isAbove { frame.origin.y = start.maxY }
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        table.sizeLastColumnToFit()
        panel.invalidateShadow()
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
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

    /// Its rows made again with the row chosen as it is: Increase Contrast changes their colours.
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

    /// The chosen row's ground moves with it, and its neighbours fade.
    func tableViewSelectionDidChange(_ notification: Notification) {
        table.needsDisplay = true
        table.enumerateAvailableRowViews { view, row in
            (view.view(atColumn: 0) as? NSView)?.alphaValue = row == table.selectedRow ? 1 : Self.faint
        }
    }

    /// A row's label: what's typed as the document's text and heavier, the rest of it behind.
    private func label(_ row: Int) -> NSAttributedString {
        let label = NSMutableAttributedString(string: labels[row], attributes: [
            .font: font, .foregroundColor: Self.increasesContrast ? NSColor.labelColor : .secondaryLabelColor, .paragraphStyle: Self.oneLine])
        label.addAttributes([.font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), .foregroundColor: NSColor.labelColor],
                            range: NSRange(location: 0, length: min(typed, label.length)))
        return label
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(), image = NSImageView(), text = NSTextField(labelWithString: "")
        text.attributedStringValue = label(row)
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The square as high as the label's line, Xcode's 16 pt at 13, and the letter in the text's
        // background: white on Light's deep squares, dark on Dark's pale ones.
        let side = lineHeight
        image.image = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: badge.name)?
            .withSymbolConfiguration(.init(pointSize: side / Self.squareSide, weight: .regular)
                .applying(.init(paletteColors: [.textBackgroundColor, badge.color])))
        // The symbol at its own size in the square, its margins outside.
        image.imageScaling = .scaleNone
        for view in [image, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = text
        cell.alphaValue = row == tableView.selectedRow ? 1 : Self.faint
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.margin + Self.contentInset),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: side),
            image.heightAnchor.constraint(equalToConstant: side),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: Self.badgeGap),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -(Self.margin + Self.contentInset)),
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
