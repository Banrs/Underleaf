import AppKit
import SwiftUI

/// What a completion is, for its badge.
enum CompletionKind {
    case command, environment, label, citation, entryType

    /// A letter on a coloured square, as Xcode's kinds; the colour is the editor's for the same text.
    func badge(in theme: SyntaxTheme) -> (symbol: String, color: NSColor, name: String) {
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

/// The core's completions under the caret: a SwiftUI list on the system's glass, in a
/// panel that never takes the keyboard, so typing stays in the document, which moves
/// the selection and accepts it.
final class CompletionList {
    /// A click chose this row.
    var clicked: (Int) -> Void = { _ in }
    var selection: Int { rows.selection ?? 0 }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    /// Key to what it holds, so its list draws as focused; the document's window keeps the keyboard.
    private final class Panel: NSPanel {
        override var isKeyWindow: Bool { true }
    }
    private let rows = Rows()
    /// At most this many rows show; the rest scroll.
    private static let shownRows = 8

    init() {
        let glass = NSGlassEffectView()
        glass.contentView = NSHostingView(rootView: RowsView(rows: rows) { [unowned self] in clicked($0) })
        panel.contentView = glass
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        // After the layout pass that measured them: resizing the panel inside it would lay
        // the same hosting view out again, which AppKit skips (#30).
        rows.measured = { [weak self] in
            guard let self, !fitPending else { return }
            fitPending = true
            DispatchQueue.main.async { [weak self] in
                self?.fitPending = false
                self?.fit()
            }
        }
    }

    private var fitPending = false

    /// Shows `rows` in `font` with the first selected, the labels' text under
    /// the typed text's start, `start`: a screen rect of `window`'s. Without a
    /// window it holds them unseen.
    func show(_ rows: [(label: String, kind: CompletionKind)], font: NSFont, theme: SyntaxTheme, under start: NSRect, in window: NSWindow?) {
        guard !rows.isEmpty else { return close() }
        if self.rows.font != font { self.rows.metrics = nil }
        self.rows.items = rows.map { Item(label: $0.label, badge: $0.kind.badge(in: theme)) }
        self.rows.font = font
        guard let window else {
            self.rows.selection = 0
            return
        }
        let opening = parent == nil
        if parent !== window {
            parent?.removeChildWindow(panel)
            // Room to lay the rows out in, before the list has measured them.
            if self.rows.metrics == nil { panel.setContentSize(NSSize(width: font.pointSize * 30, height: font.pointSize * 20)) }
        }
        parent = window
        self.start = start
        // Shown once the list has measured its rows (`fit`).
        panel.contentView?.layoutSubtreeIfNeeded()
        focusList()
        self.rows.selection = 0
        fit()
        if opening { announce() }
    }

    /// The panel never has VoiceOver's focus, which stays in the document: the row chosen is
    /// spoken as the list opens and as the arrows move through it, as Xcode's list speaks it.
    private func announce() {
        guard rows.items.indices.contains(selection) else { return }
        let item = rows.items[selection]
        let position = String(localized: "\(selection + 1) of \(rows.items.count)")
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: [item.label, item.badge.name, position].formatted(.list(type: .and, width: .narrow)),
            .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Selected as the list that has the keyboard, though the document has it: a table
    /// draws the focused list's selection only as its key window's first responder, which
    /// the panel says it is while never taking the keyboard. SwiftUI's own focus (`focused`)
    /// gives the row the focused list's fill but the unfocused one's text (27.2).
    private func focusList() {
        func table(in view: NSView) -> NSTableView? {
            view as? NSTableView ?? view.subviews.lazy.compactMap(table).first
        }
        guard !(panel.firstResponder is NSTableView), let content = panel.contentView, let list = table(in: content) else { return }
        panel.makeFirstResponder(list)
    }

    private weak var parent: NSWindow?
    private var start = NSRect.zero

    /// Sized to its rows and widest label, from where the list puts the first row and its text.
    private func fit() {
        guard let metrics = rows.metrics, let parent, !rows.items.isEmpty else { return }
        // The editor's font is monospaced: the longest label is the widest.
        let longest = rows.items.max { $0.label.count < $1.label.count }?.label ?? ""
        let widest = (longest as NSString).size(withAttributes: [.font: rows.font]).width
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        let size = NSSize(width: min(metrics.textStart + widest.rounded(.up) + metrics.textEnd, screen.width / 2),
                          height: metrics.height(rows: min(rows.items.count, Self.shownRows)))
        if panel.contentView?.frame.size != size { panel.setContentSize(size) }
        place(under: start)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
    }

    /// Over the typed text, there being no room under it.
    private(set) var isAbove = false

    /// Moves it under `start`, a screen rect, or over it when there's no room under it.
    func place(under start: NSRect) {
        self.start = start
        guard let window = parent, let metrics = rows.metrics else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var frame = NSRect(origin: NSPoint(x: start.minX - metrics.textStart, y: start.minY - panel.frame.height), size: panel.frame.size)
        isAbove = frame.minY < screen.minY
        if isAbove { frame.origin.y = start.maxY }
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        panel.setFrame(frame, display: true)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent = nil
        rows.items = []
    }

    /// Moves the selection by `step` rows, stopping at the ends.
    func move(_ step: Int) {
        guard !rows.items.isEmpty else { return }
        rows.selection = max(0, min(rows.items.count - 1, selection + step))
        announce()
    }

    fileprivate struct Item {
        let label: String
        let badge: (symbol: String, color: NSColor, name: String)
    }

    /// Where the list lays out its rows, measured in the window: the first label's top and
    /// height, the gap from one row to the next, and its text from the list's leading side.
    /// The rows' content is inset as far at the trailing side as at the leading one.
    fileprivate struct Metrics: Equatable {
        var top: CGFloat
        var labelHeight: CGFloat
        var pitch: CGFloat?
        var textStart: CGFloat
        var textEnd: CGFloat

        /// The same space under the last label as over the first.
        func height(rows: Int) -> CGFloat {
            2 * top + labelHeight + CGFloat(rows - 1) * (pitch ?? labelHeight)
        }
    }

    @Observable fileprivate final class Rows {
        var items: [Item] = []
        var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        var selection: Int?
        @ObservationIgnored var metrics: Metrics? {
            didSet { if metrics != oldValue { measured() } }
        }
        @ObservationIgnored var measured: () -> Void = {}
    }

    private struct RowsView: View {
        let rows: Rows
        let click: (Int) -> Void
        @State private var list = CGRect.zero
        @State private var first: (label: CGRect, text: CGRect)?
        @State private var second: CGRect?

        var body: some View {
            @Bindable var rows = rows
            ScrollViewReader { proxy in
                List(selection: $rows.selection) {
                    ForEach(rows.items.indices, id: \.self) { index in
                        row(rows.items[index], index)
                            .listRowSeparator(.hidden)
                            .simultaneousGesture(TapGesture().onEnded { click(index) })
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: rows.selection) { if let row = rows.selection { proxy.scrollTo(row) } }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { list = $0; measure() }
        }

        private func row(_ item: Item, _ index: Int) -> some View {
            Label {
                Text(item.label)
                    .font(Font(rows.font))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { text in
                        guard index == 0, let label = first?.label else { return }
                        first = (label, text)
                        measure()
                    }
            } icon: {
                // The letter in the text's background: white on Light's deep squares, dark on Dark's pale ones.
                Image(systemName: item.badge.symbol)
                    .font(.system(size: rows.font.pointSize))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color(nsColor: .textBackgroundColor), Color(nsColor: item.badge.color))
            }
            .lineLimit(1)
            // One element: the label, then its kind.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: item.label))
            .accessibilityValue(Text(item.badge.name))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { label in
                switch index {
                case 0: first = (label, first?.text ?? label)
                case 1: second = label
                default: return
                }
                measure()
            }
        }

        /// The list's own margins, for the panel's size: in global space, y runs down.
        private func measure() {
            // Only rows laid out inside the list: a row not yet placed reports no real frame.
            guard let first, list.width > 0, first.text.width > 0, list.contains(first.text), list.contains(first.label) else { return }
            let pitch = second.flatMap { $0.minY > first.label.minY && list.contains($0) ? $0.minY - first.label.minY : nil }
                ?? rows.metrics?.pitch
            rows.metrics = Metrics(top: first.label.minY - list.minY, labelHeight: first.label.height, pitch: pitch,
                                   textStart: first.text.minX - list.minX, textEnd: first.label.minX - list.minX)
        }
    }
}
