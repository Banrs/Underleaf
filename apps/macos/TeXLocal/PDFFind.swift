import PDFKit
import SwiftUI

/// Find in the PDF pane: the bar's text, PDFKit's search of the document showing, and its matches, which the view marks.
@Observable
final class PDFFind: NSObject, @MainActor PDFDocumentDelegate {
    static let maxQuery = 256
    static let maxMatches = 5000
    static let debounce: Duration = .milliseconds(200)

    static func normalize(_ query: String) -> String { String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuery)) }

    static func count(_ index: Int, of total: Int, limited: Bool, for query: String) -> String {
        if query.isEmpty { return "" }
        if total == 0 { return String(localized: "Not found") }
        let count = "\(total.formatted())\(limited ? "+" : "")"
        return String(localized: "\(index) of \(count)")
    }

    /// The find text every app shares (the find pasteboard), so ⌘E in one pane and ⌘G in the other find the same;
    /// the tests' own leaves the user's alone.
    static var board = NSPasteboard(name: .find)

    static var shared: String? {
        get { board.string(forType: .string) }
        set {
            guard let newValue, !newValue.isEmpty, newValue != shared else { return }
            board.clearContents()
            board.setString(newValue, forType: .string)
        }
    }

    private let view: SyncPDFView
    /// Whether the bar is open.
    var isOpen = false { didSet { if isOpen, !oldValue, text.isEmpty { text = Self.shared ?? "" } } }
    /// What the field holds, which can be ahead of `query`.
    var text = ""
    let field = FieldHandle()
    /// The query `matches` are for.
    private(set) var query = ""
    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex = 0
    private(set) var limited = false

    /// PDFKit searches off the main thread; the first query extracts page text.
    @ObservationIgnored private var running: (document: PDFDocument, query: String, keepingPlace: Bool, found: [PDFSelection])?
    @ObservationIgnored private var startFrom: (anchor: Position, step: Int)?
    @ObservationIgnored private var rerunning: Task<Void, Never>?
    /// Past Live Preview's gap between keys, so the search runs again as the typing pauses.
    static let rerunDelay: Duration = .milliseconds(350)

    init(view: SyncPDFView) { self.view = view }

    isolated deinit {
        running?.document.delegate = nil
        running?.document.cancelFindString()
    }

    // MARK: - Searching

    /// The field's text once its typing delay ends.
    func typed() {
        guard Self.normalize(text) != running?.query ?? query else { return }
        Self.shared = Self.normalize(text)
        search(text)
    }

    func search(_ value: String, keepingPlace: Bool = false) {
        guard let document = view.document else { return }
        let query = Self.normalize(value)
        // A rebuild can start this query before the field's typing delay ends.
        guard running?.document !== document || running?.query != query else { return }
        cancel()
        guard !query.isEmpty else { return found(query, [], keepingPlace: keepingPlace) }
        document.delegate = self
        running = (document, query, keepingPlace, [])
        // As Safari's and Mail's Find: "Godel" finds "Gödel".
        document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    /// The bar's text again over the document as it now is, where the pane left off.
    func rerun() { if isOpen { search(text, keepingPlace: true) } }

    /// Cancelling posts its end at once, unheard as `running` is cleared first.
    func cancel() {
        rerunning?.cancel()
        let document = running?.document
        running = nil
        document?.cancelFindString()
    }

    /// The bar closed and its matches gone, as for a pane with no document.
    func reset() {
        (isOpen, text) = (false, "")
        cancel()
        (query, matches, matchIndex, limited, startFrom) = ("", [], 0, false, nil)
    }

    // PDFKit delivers document-find delegate callbacks on the main thread.
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
        self.query = query
        matches = Array(all.prefix(Self.maxMatches))
        limited = all.count > matches.count
        if !keepingPlace || matchIndex >= matches.count { matchIndex = 0 }
        let start = startFrom.take()
        if let start, !matches.isEmpty { matchIndex = index(from: start.anchor, step: start.step) }
        matches.forEach { $0.color = .findHighlightColor }
        view.highlightedSelections = matches.isEmpty ? nil : matches
        if matches.isEmpty { view.clearSelection() }
        // Use Selection for Find stays at the selection, which is its match; so does a search again over live pages.
        if !keepingPlace || view.currentSelection == nil { select(scrolling: start.map { $0.step != 0 } ?? !keepingPlace) }
    }

    /// Pages that live preview or a rebuild replaced: their matches go at once, and the search runs again over what is there
    /// once the pages stop coming, so a burst of keys in Live Preview costs one search of the whole document.
    func pagesReplaced(_ gone: Set<PDFPage>) {
        let kept = matches.filter { !$0.pages.contains(where: gone.contains) }
        if kept.count != matches.count {
            let chosen = matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
            matches = kept
            matchIndex = chosen.flatMap { kept.firstIndex(of: $0) } ?? min(matchIndex, max(0, kept.count - 1))
            view.highlightedSelections = kept.isEmpty ? nil : kept
        }
        guard isOpen else { return }
        cancel()
        restart(&rerunning, after: Self.rerunDelay) { [weak self] in
            guard let self else { return }
            search(text, keepingPlace: true)
        }
    }

    // MARK: - Where the next match is

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

    // MARK: - The menus' find

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
        // A copy without Find's colour, which PDFKit draws as the selection, over the mark every match has.
        match.color = nil
        view.setCurrentSelection(match, animate: scrolling && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if scrolling { view.scrollSelectionToVisible(nil) }
    }
}
