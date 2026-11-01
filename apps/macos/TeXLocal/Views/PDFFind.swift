import PDFKit
import SwiftUI

@Observable
final class PDFFind: NSObject, @MainActor PDFDocumentDelegate {
    static let maxMatches = 5000
    static let debounce: Duration = .milliseconds(200)

    private static func normalize(_ query: String) -> String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func count(_ index: Int, of total: Int, limited: Bool, for query: String) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return String(localized: "Not found") }
        let count = "\(total.formatted())\(limited ? "+" : "")"
        return String(localized: "\(index) of \(count)")
    }

    static var board = NSPasteboard(name: .find)

    static var shared: String? {
        get { board.string(forType: .string) }
        set {
            guard let newValue, !newValue.isEmpty, newValue != shared else { return }
            board.replaceContents(with: newValue)
        }
    }

    private let view: SyncPDFView
    var isOpen = false { didSet { if isOpen, !oldValue, text.isEmpty { text = Self.shared ?? "" } } }
    var text = ""
    let field = FieldHandle()
    private(set) var query = ""
    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex = 0
    private(set) var limited = false

    @ObservationIgnored private var running: (document: PDFDocument, query: String, keepingPlace: Bool, found: [PDFSelection])?
    @ObservationIgnored private var startFrom: (anchor: Position, step: Int)?

    init(view: SyncPDFView) { self.view = view }

    isolated deinit {
        running?.document.delegate = nil
        running?.document.cancelFindString()
    }

    func typed() {
        guard Self.normalize(text) != running?.query ?? query else { return }
        Self.shared = Self.normalize(text)
        search(text)
    }

    func search(_ value: String, keepingPlace: Bool = false) {
        guard let document = view.document else { return }
        let query = Self.normalize(value)
        guard running?.document !== document || running?.query != query else { return }
        cancel()
        guard !query.isEmpty else { return found(query, [], keepingPlace: keepingPlace) }
        document.delegate = self
        running = (document, query, keepingPlace, [])
        document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    func rerun() { if isOpen { search(text, keepingPlace: true) } }

    var isRunning: Bool { running != nil }

    /// Live Preview swapped pages: their matches are found again on those pages alone, not in the whole document.
    func replaced(_ swaps: [(old: PDFPage, new: PDFPage?)]) {
        guard isOpen, !query.isEmpty, !swaps.isEmpty else { return }
        var all = matches.filter { match in !swaps.contains { match.pages.contains($0.old) } }
        for page in swaps.compactMap(\.new) {
            guard let text = page.string else { continue }
            var from = text.startIndex
            while let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                if let match = page.selection(for: NSRange(range, in: text)) { all.append(match) }
                from = range.upperBound
            }
        }
        let placed = all.compactMap { match in position(match).map { (match, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        found(query, placed, keepingPlace: true)
    }

    func cancel() {
        let document = running?.document
        running = nil
        document?.cancelFindString()
    }

    func reset() {
        (isOpen, text) = (false, "")
        cancel()
        (query, matches, matchIndex, limited, startFrom) = ("", [], 0, false, nil)
    }

    func documentDidFindMatch(_ note: Notification) {
        guard note.object as? PDFDocument === running?.document,
              let match = note.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else { return }
        running?.found.append(match)
        if running?.found.count ?? 0 > Self.maxMatches { running?.document.cancelFindString() }
    }

    func documentDidEndDocumentFind(_ note: Notification) {
        guard let running, note.object as? PDFDocument === running.document else { return }
        self.running = nil
        found(running.query, running.found, keepingPlace: running.keepingPlace)
    }

    private func found(_ query: String, _ all: [PDFSelection], keepingPlace: Bool) {
        let was = matches
        self.query = query
        matches = Array(all.prefix(Self.maxMatches))
        limited = all.count > matches.count
        if !keepingPlace || matchIndex >= matches.count { matchIndex = 0 }
        let start = startFrom.take()
        if let start, !matches.isEmpty { matchIndex = index(from: start.anchor, step: start.step) }
        matches.forEach { $0.color = .findHighlightColor }
        view.highlightedSelections = matches.isEmpty ? nil : matches
        if matches.isEmpty, let shown = view.currentSelection.flatMap(position),
           was.contains(where: { position($0).map { $0 == shown } ?? false }) { view.clearSelection() }
        if !keepingPlace || view.currentSelection == nil { select(scrolling: start.map { $0.step != 0 } ?? !keepingPlace) }
    }

    private typealias Position = (page: Int, down: CGFloat, across: CGFloat)

    private func position(_ selection: PDFSelection) -> Position? {
        guard let document = view.document, let page = selection.pages.first else { return nil }
        let box = selection.bounds(for: page)
        return (page: document.index(for: page), down: -box.maxY, across: box.minX)
    }

    private var anchor: Position? {
        view.currentSelection.flatMap(position) ?? view.shownPlace.map { (page: $0.index, down: -$0.point.y, across: $0.point.x) }
    }

    private func index(from anchor: Position, step: Int) -> Int {
        let places = matches.map { position($0) }
        switch step {
        case 0: return places.firstIndex { $0.map { $0 >= anchor } ?? false } ?? 0
        case 1...: return places.firstIndex { $0.map { $0 > anchor } ?? false } ?? 0
        default: return places.lastIndex { $0.map { $0 < anchor } ?? false } ?? matches.count - 1
        }
    }

    var canNext: Bool { view.document != nil && (!matches.isEmpty || !(Self.shared ?? "").isEmpty) }

    func next(_ step: Int) {
        let typed = Self.normalize(text)
        let pending = !typed.isEmpty && typed != (running?.query ?? query)
        let value = pending ? typed : Self.shared.map(Self.normalize) ?? typed
        guard !value.isEmpty else { return }
        if !matches.isEmpty, value == query, running == nil { return advance(by: step) }
        if pending { Self.shared = value }
        (isOpen, text, startFrom) = (true, value, anchor.map { ($0, step) })
        search(value)
    }

    var canUseSelection: Bool { !(view.currentSelection?.string ?? "").isEmpty }

    func useSelection() {
        guard let selection = view.currentSelection, let value = selection.string, !value.isEmpty else { return }
        Self.shared = value
        (isOpen, text, startFrom) = (true, value, position(selection).map { ($0, 0) })
        search(value)
    }

    func close() {
        let fromBar = field.hasFocus
        (isOpen, text) = (false, "")
        search("")
        if fromBar { view.window?.makeFirstResponder(view) }
    }

    func advance(by delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        select()
    }

    private func select(scrolling: Bool = true) {
        guard matches.indices.contains(matchIndex), let match = matches[matchIndex].copy() as? PDFSelection else { return }
        match.color = nil
        view.setCurrentSelection(match, animate: scrolling && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if scrolling { view.scrollSelectionToVisible(nil) }
    }
}
