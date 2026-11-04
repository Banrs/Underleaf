import PDFKit
import Synchronization

final class PDFFind: NSObject, NSMenuItemValidation {
    let text: PDFText
    private let finder = NSTextFinder()
    private unowned let view: SyncPDFView
    private var matches: NSKeyValueObservation?
    private var reading: Task<Void, Never>?

    init(view: SyncPDFView) {
        self.view = view
        text = PDFText(view: view)
        super.init()
        finder.client = text
        finder.isIncrementalSearchingEnabled = true
        // NSTextFinder dims and lights matches by drawing the content view, which leaves PDFKit's page layers out.
        finder.incrementalSearchingShouldDimContentView = false
        matches = finder.observe(\.incrementalMatchRanges) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.highlightMatches() }
        }
    }

    var isOpen: Bool { view.pageScrollView?.isFindBarVisible == true }

    @objc func performFindPanelAction(_ sender: Any?) {
        if let item = sender as? any NSValidatedUserInterfaceItem, let action = NSTextFinder.Action(rawValue: item.tag) { perform(action) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { NSTextFinder.Action(rawValue: item.tag).map(validate) ?? false }

    func validate(_ action: NSTextFinder.Action) -> Bool { shown?.validateAction(action) == true }

    func perform(_ action: NSTextFinder.Action) { shown?.performAction(action) }

    func close() { finder.performAction(.hideFindInterface) }

    private var shown: NSTextFinder? {
        guard view.document != nil, let scrollView = view.pageScrollView else { return nil }
        finder.findBarContainer = scrollView
        return finder
    }

    /// Reads the shown pages' text again after they change, off the main thread and after the change rather than before
    /// it, as it takes about a millisecond a page: 430 ms for the 392-page test PDF. A page keeps its text once read, so
    /// after a live page only that page costs. NSTextFinder doesn't find again when told the text changes, so its matches
    /// go only when the text did.
    func pagesChanged() {
        let pages = PageTexts(document: view.document)
        _ = restart(&reading) { [weak self] in
            let strings = await pages.read()
            guard let self, !Task.isCancelled else { return }
            guard strings != text.pageStrings else { return highlightMatches() }
            finder.noteClientStringWillChange()
            text.pageStrings = strings
        }
    }

    private func highlightMatches() {
        let found = finder.incrementalMatchRanges.compactMap { text.selection(for: $0.rangeValue) }
        for match in found { match.color = .findHighlightColor }
        view.highlightedSelections = found.isEmpty ? nil : found
    }
}

/// The PDF's text as NSTextFinder reads it: the pages' strings in turn, each ending in a search boundary so that no match
/// spans two pages. NSTextFinder reads them on a background queue as it finds incrementally, so they are swapped whole
/// under a lock rather than read from the pages, and only what touches the view is the main actor's.
nonisolated final class PDFText: NSObject, @MainActor NSTextFinderClient {
    private struct Pages {
        var strings: [String] = []
        /// Where each page's string ends in the text, in UTF-16 units as NSTextFinder counts.
        var ends: [Int] = []

        func start(of page: Int) -> Int { page == 0 ? 0 : ends[page - 1] }

        func page(at index: Int) -> Int? { ends.firstIndex { $0 > index } }
    }

    private let pages = Mutex(Pages())
    private unowned let view: SyncPDFView

    init(view: SyncPDFView) { self.view = view }

    var pageStrings: [String] {
        get { pages.withLock { $0.strings } }
        set {
            var end = 0
            let ends = newValue.map { string in
                end += (string as NSString).length
                return end
            }
            pages.withLock { $0 = Pages(strings: newValue, ends: ends) }
        }
    }

    let isEditable = false

    func string(at index: Int, effectiveRange range: NSRangePointer, endsWithSearchBoundary boundary: UnsafeMutablePointer<ObjCBool>) -> String {
        pages.withLock { pages in
            guard let page = pages.page(at: index) else {
                range.pointee = NSRange(location: pages.ends.last ?? 0, length: 0)
                return ""
            }
            range.pointee = NSRange(location: pages.start(of: page), length: pages.ends[page] - pages.start(of: page))
            boundary.pointee = true
            return pages.strings[page]
        }
    }

    func stringLength() -> Int { pages.withLock { $0.ends.last ?? 0 } }

    @MainActor var firstSelectedRange: NSRange {
        guard let document = view.document else { return NSRange() }
        if let selection = view.currentSelection, let page = selection.pages.first,
           case let range = selection.range(at: 0, on: page), range.location != NSNotFound,
           let span = span(of: document.index(for: page)) {
            return NSRange(location: span.lowerBound + range.location, length: range.length)
        }
        guard let top = view.placeBeneathToolbar, let page = document.page(ifAt: top.index), let span = span(of: top.index) else {
            return NSRange()
        }
        let box = page.bounds(for: view.displayBox)
        let below = page.selection(for: CGRect(x: box.minX, y: box.minY, width: box.width, height: max(0, top.point.y - box.minY)))
        let ranges = below.map { below in (0..<below.numberOfTextRanges(on: page)).map { below.range(at: $0, on: page) } } ?? []
        let first = ranges.map(\.location).filter { $0 != NSNotFound }.min()
        return NSRange(location: first.map { span.lowerBound + $0 } ?? span.upperBound, length: 0)
    }

    @MainActor func scrollRangeToVisible(_ range: NSRange) {
        guard let match = selection(for: range) else { return }
        view.setCurrentSelection(match, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        view.scrollSelectionToVisible(nil)
    }

    @MainActor func selection(for range: NSRange) -> PDFSelection? {
        let found = pages.withLock { pages in pages.page(at: range.location).map { ($0, pages.start(of: $0)) } }
        guard let (index, start) = found, let page = view.document?.page(ifAt: index) else { return nil }
        return page.selection(for: NSRange(location: range.location - start, length: range.length))
    }

    private func span(of page: Int) -> Range<Int>? {
        pages.withLock { pages in pages.ends.indices.contains(page) ? pages.start(of: page)..<pages.ends[page] : nil }
    }
}

/// The pages of the document shown, whose text is read off the main thread, as PDFKit itself reads shown pages there to
/// draw them and to find in them.
private nonisolated struct PageTexts: @unchecked Sendable {
    let pages: [PDFPage]

    init(document: PDFDocument?) { pages = document.map { document in (0..<document.pageCount).compactMap { document.page(at: $0) } } ?? [] }

    @concurrent func read() async -> [String] {
        var strings: [String] = []
        for page in pages {
            guard !Task.isCancelled else { break }
            strings.append(page.string ?? "")
        }
        return strings
    }
}
