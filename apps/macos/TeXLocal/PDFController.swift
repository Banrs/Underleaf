import PDFKit
import SwiftUI
import Synchronization

@Observable
final class PDFController: NSObject, @MainActor PDFDocumentDelegate {
    /// Read whole: the next build rewrites the file in place.
    @concurrent nonisolated static func loadDocument(_ url: URL) async -> sending PDFDocument? {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        for index in 0..<document.pageCount { document.page(at: index)?.hideLinkBorders() }
        return document
    }

    @ObservationIgnored let view = SyncPDFView()
    @ObservationIgnored private var magnification: NSKeyValueObservation?
    @ObservationIgnored private weak var watched: NSScrollView?
    @ObservationIgnored private var scrolling: NotificationCenter.ObservationToken?
    private(set) var page = 0
    @ObservationIgnored var restorePage: Int?
    @ObservationIgnored private var pendingReveal: (loc: ForwardLoc, word: SyncTeXWord?)?
    private(set) var pageCount = 0
    var finding = false {
        didSet { if finding, !oldValue, findText.isEmpty { findText = PDFFind.shared ?? "" } }
    }
    var findText = ""
    @ObservationIgnored let findField = FieldHandle()
    private(set) var query = ""
    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex = 0
    private(set) var limited = false
    private(set) var scale: CGFloat = 1
    var zoomLabel: String { Self.label(scale) }
    var widestZoomLabel: String { Self.label(Self.maxScale) }
    var canZoomIn: Bool { scale < Self.maxScale }
    var canZoomOut: Bool { scale > Self.minScale }
    /// PDFKit would go to 10,000%; the toolbar's scale reserves a three-digit label's width.
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 8
    private static func label(_ scale: CGFloat) -> String {
        Double(scale).formatted(.percent.precision(.fractionLength(0)))
    }
    enum Fit { case width, page }
    private(set) var fit: Fit? = .width

    nonisolated enum Zoom: Codable, Equatable {
        case fitWidth, fitPage, scale(Double)
    }

    var zoom: Zoom {
        switch fit {
        case .width: .fitWidth
        case .page: .fitPage
        case nil: .scale(Double(scale))
        }
    }

    @ObservationIgnored var restoreZoom: Zoom?

    override init() {
        super.init()
        view.backgroundColor = .untintedTextBackground
        view.autoScales = true
        view.onResize = { [weak self] in
            guard let self else { return }
            dropLive()
            restoreZoomIfReady()
            if fit == .page { fitPage() }
            restorePageIfReady()
            if let pending = pendingReveal { reveal(pending.loc, word: pending.word) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(visiblePagesChanged), name: .PDFViewVisiblePagesChanged, object: view)
        // Comes only as a pinch ends; the scroll view's magnification follows each step.
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
    }

    private func watchScrollView() {
        guard let scrollView = view.pageScrollView, scrollView !== watched else { return }
        watched = scrollView
        magnification = scrollView.observe(\.magnification, options: .initial) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scaleChanged() }
        }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scrolling = NotificationCenter.default.addObserver(of: clip, for: .boundsDidChange) { [weak self] _ in self?.scrolled() }
    }

    @objc private func pageChanged() {
        guard let document = view.document, let page = view.currentPage else { return }
        if let number = document.number(of: page) { self.page = number }
        pageCount = document.pageCount
    }

    @ObservationIgnored var onVisiblePages: (ClosedRange<Int>) -> Void = { _ in }
    @ObservationIgnored private var toldPages: ClosedRange<Int>?

    var visiblePages: ClosedRange<Int>? {
        guard let document = view.document, view.hasShownArea else { return nil }
        let shown = view.visiblePages.map { document.index(for: $0) }.filter { $0 != NSNotFound }
        return shown.min().flatMap { first in shown.max().map { first...$0 } }
    }

    @objc private func visiblePagesChanged() {
        guard let pages = visiblePages, pages != toldPages else { return }
        toldPages = pages
        onVisiblePages(pages)
    }

    @objc private func scaleChanged() {
        view.fitPageEdges()
        if view.liveScaleChanged { dropLive() }
        guard view.document != nil, view.hasShownArea else { return }
        scale = view.scaleFactor
        // A pinch keeps autoScales on until it ends: one back at the width fits again, one ending off it doesn't.
        if view.autoScales, abs(view.scaleFactor - view.scaleFactorForSizeToFit) < 0.001 {
            fit = .width
        } else if fit == .width || (fit == .page && abs(view.scaleFactor - pageScale) > 0.001) {
            fit = nil
        }
    }

    private var pageScale: CGFloat {
        guard let page = view.currentPage else { return view.scaleFactor }
        let margins = view.pageBreakMargins, box = page.bounds(for: view.displayBox)
        // The box is in page space; a page turned a quarter shows its width upright.
        let pageHeight = page.rotation.isMultiple(of: 180) ? box.height : box.width
        let height = view.shownHeight / (pageHeight + margins.top + margins.bottom)
        return min(height, view.scaleFactorForSizeToFit)
    }

    func setScale(_ scale: CGFloat) {
        fit = nil
        view.autoScales = false
        view.scaleFactor = scale
    }

    func zoom(in zoomIn: Bool) {
        fit = nil
        if zoomIn { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }

    func go(toPage number: Int) {
        guard let document = view.document, let page = document.page(ifAt: min(max(number, 1), document.pageCount) - 1) else { return }
        view.go(to: page)
    }

    @ObservationIgnored var buildBehindLive: () -> URL? = { nil }

    /// During Live Preview the build's file, since the document showing is TeXpresso's. The operation keeps the document (27.2).
    func print(title: String) {
        Task {
            let document = if let url = buildBehindLive() { await Self.loadDocument(url) } else { view.document }
            // The build's file can be half-written while the next build runs.
            guard let operation = document?.printOperation(for: .shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
                NSSound.beep()
                return
            }
            operation.jobTitle = title
            if let window = view.window ?? NSApp.mainWindow {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
        }
    }

    func fitWidth() {
        fit = .width
        view.autoScales = true
    }

    /// Sets the fit after the scale, since the scale's change ends a fit.
    func fitPage() {
        guard view.currentPage != nil, view.shownHeight > 0 else { return }
        if view.autoScales { view.autoScales = false }
        let scale = pageScale
        if view.scaleFactor != scale { view.scaleFactor = scale }
        fit = .page
    }

    func setDarkPaper(_ dark: Bool) {
        guard dark != view.darkPaper else { return }
        dropLive()
        let fit = fit, scale = view.scaleFactor, place = view.shownDestination
        view.darkPaper = dark
        guard view.document != nil else { return }
        // PDFKit caches page tiles; changing the display box refreshes them.
        let box = view.displayBox
        view.displayBox = box == .mediaBox ? .cropBox : .mediaBox
        view.displayBox = box
        switch fit {
        case .width: fitWidth()
        case .page: fitPage()
        case nil: setScale(scale)
        }
        if let place { view.go(to: place) }
    }

    /// PDFKit searches off the main thread; the first query extracts page text.
    @ObservationIgnored private var search: (document: PDFDocument, query: String, keepingPlace: Bool, found: [PDFSelection])?

    isolated deinit {
        search?.document.delegate = nil
        search?.document.cancelFindString()
    }

    func findTyped() {
        guard PDFFind.normalize(findText) != search?.query ?? query else { return }
        PDFFind.shared = PDFFind.normalize(findText)
        find(findText)
    }

    func find(_ value: String, keepingPlace: Bool = false) {
        guard let document = view.document else { return }
        let query = PDFFind.normalize(value)
        // A rebuild can start this query before the field's typing delay ends.
        guard search?.document !== document || search?.query != query else { return }
        cancelSearch()
        guard !query.isEmpty else { return found(query, [], keepingPlace: keepingPlace) }
        document.delegate = self
        search = (document, query, keepingPlace, [])
        // As Safari's and Mail's Find: "Godel" finds "Gödel".
        document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Cancelling posts its end at once, unheard as `search` is cleared first.
    private func cancelSearch() {
        let document = search?.document
        search = nil
        document?.cancelFindString()
    }

    // PDFKit delivers document-find delegate callbacks on the main thread.
    func documentDidFindMatch(_ note: Notification) {
        guard note.object as? PDFDocument === search?.document,
              let match = note.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else { return }
        search?.found.append(match)
        if search?.found.count ?? 0 > PDFFind.maxMatches { search?.document.cancelFindString() }
    }

    func documentDidEndDocumentFind(_ note: Notification) {
        guard let search, note.object as? PDFDocument === search.document else { return }
        self.search = nil
        found(search.query, search.found, keepingPlace: search.keepingPlace)
    }

    private func found(_ query: String, _ all: [PDFSelection], keepingPlace: Bool) {
        self.query = query
        matches = Array(all.prefix(PDFFind.maxMatches))
        limited = all.count > matches.count
        if !keepingPlace || matchIndex >= matches.count { matchIndex = 0 }
        let start = startFrom
        startFrom = nil
        if let start, !matches.isEmpty { matchIndex = index(from: start.anchor, step: start.step) }
        matches.forEach { $0.color = .findHighlightColor }
        view.highlightedSelections = matches.isEmpty ? nil : matches
        if matches.isEmpty { view.clearSelection() }
        // Use Selection for Find stays at the selection, which is its match; so does a search again over live pages.
        if !keepingPlace || view.currentSelection == nil { selectMatch(scrolling: start.map { $0.step != 0 } ?? !keepingPlace) }
    }

    @ObservationIgnored private var startFrom: (anchor: Position, step: Int)?

    private typealias Position = (page: Int, down: CGFloat, across: CGFloat)

    private func position(_ selection: PDFSelection) -> Position? {
        guard let document = view.document, let page = selection.pages.first else { return nil }
        let box = selection.bounds(for: page)
        return (page: document.index(for: page), down: -box.maxY, across: box.minX)
    }

    private var anchor: Position? {
        view.currentSelection.flatMap(position) ?? shownPlace.map { (page: $0.index, down: -$0.point.y, across: $0.point.x) }
    }

    private func index(from anchor: Position, step: Int) -> Int {
        let places = matches.map { position($0) }
        switch step {
        case 0: return places.firstIndex { $0.map { $0 >= anchor } ?? false } ?? 0
        case 1...: return places.firstIndex { $0.map { $0 > anchor } ?? false } ?? 0
        default: return places.lastIndex { $0.map { $0 < anchor } ?? false } ?? matches.count - 1
        }
    }

    var canFindNext: Bool { view.document != nil && (!matches.isEmpty || !(PDFFind.shared ?? "").isEmpty) }

    func findNext(_ step: Int) {
        let typed = PDFFind.normalize(findText)
        let pending = !typed.isEmpty && typed != (search?.query ?? query)
        let text = pending ? typed : PDFFind.shared.map(PDFFind.normalize) ?? typed
        guard !text.isEmpty else { return }
        if !matches.isEmpty, text == query, search == nil { return self.step(step) }
        if pending { PDFFind.shared = text }
        finding = true
        findText = text
        startFrom = anchor.map { ($0, step) }
        find(text)
    }

    var canUseSelectionForFind: Bool { !(view.currentSelection?.string ?? "").isEmpty }

    func useSelectionForFind() {
        guard let selection = view.currentSelection, let text = selection.string, !text.isEmpty else { return }
        PDFFind.shared = text
        finding = true
        findText = text
        startFrom = position(selection).map { ($0, 0) }
        find(text)
    }

    func closeFind() {
        let fromBar = findField.hasFocus
        finding = false
        findText = ""
        find("")
        if fromBar { view.window?.makeFirstResponder(view) }
    }

    @ObservationIgnored private(set) var shownVersion = 0

    /// PDFKit keeps the objects of every page a document takes from another for that document's life (27.2), and only a
    /// new document frees them; so the meter is the app's own memory growth.
    @ObservationIgnored private var memoryAtWhole = UInt64.max
    private var hasGrown: Bool {
        let now = memory()
        return now > memoryAtWhole && now - memoryAtWhole > 512 << 20
    }

    @ObservationIgnored var memory: () -> UInt64 = { PDFController.footprint }

    private static var footprint: UInt64 {
        var usage = rusage_info_current()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return read == 0 ? usage.ri_phys_footprint : 0
    }

    /// A rebuild's pages replace those showing in the same document: a new document shows only PDFKit's background
    /// until its pages draw, a few frames later (27.2). Once in a while a whole one frees the memory the replaced pages hold.
    func show(_ document: PDFDocument) {
        shownVersion += 1
        liveWaiting.removeAll()
        liveBacklog = nil
        clearLiveLater()
        // Read before the swap: a page keeps its document only weakly.
        let place = restorePage == nil ? shownPlace : nil
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        view.removeMark()
        if view.document != nil {
            cancelSearch()
            view.clearSelection()
            view.highlightedSelections = nil
        }
        if let shown = view.document, !hasGrown {
            shown.replacePages(with: document)
        } else {
            view.removeLive()
            view.document = document
            memoryAtWhole = memory()
        }
        watchScrollView()
        // A document resets the limits (27.2). Setting them turns fitting off, so before the fit below.
        view.minScaleFactor = Self.minScale
        view.maxScaleFactor = Self.maxScale
        view.pageScrollView?.setAccessibilityLabel("PDF")
        view.matchScroller()
        if autoScales { view.autoScales = true } else { view.scaleFactor = scale }
        restoreZoomIfReady()
        if let place {
            go(to: place)
        } else {
            restorePageIfReady()
        }
        pageChanged()
        if finding { find(findText, keepingPlace: true) }
    }

    private var shownPlace: (index: Int, point: CGPoint)? {
        guard let destination = view.shownDestination, let page = destination.page, let document = view.document else { return nil }
        return (index: document.index(for: page), point: destination.point)
    }

    private func go(to place: (index: Int, point: CGPoint)) {
        guard let document = view.document, let page = document.page(ifAt: min(place.index, document.pageCount - 1)) else { return }
        view.go(to: PDFDestination(page: page, at: place.point))
        // PDFKit rounds destinations with legacy scrollbars; repeated builds must not drift.
        if let scroll = view.pageScrollView {
            let clip = scroll.contentView
            let target = clip.convert(view.convert(place.point, from: page), from: view)
            let top = clip.convert(CGPoint(x: view.bounds.minX, y: view.bounds.maxY - view.safeAreaInsets.top), from: view)
            clip.scroll(to: CGPoint(x: clip.bounds.minX + target.x - top.x, y: clip.bounds.minY + target.y - top.y))
            scroll.reflectScrolledClipView(clip)
        }
    }

    func clear() {
        shownVersion += 1
        liveSettling?.cancel()
        liveClearing?.cancel()
        liveWaiting.removeAll()
        liveBacklog = nil
        view.removeLive()
        (finding, findText) = (false, "")
        view.removeMark()
        cancelSearch()
        view.document = nil
        (query, matches, matchIndex, limited, startFrom) = ("", [], 0, false, nil)
        (page, pageCount) = (0, 0)
    }

    // MARK: - Live preview

    @ObservationIgnored private var liveWaiting: [Int: PDFPage] = [:]
    @ObservationIgnored private var liveSettling: Task<Void, Never>?
    @ObservationIgnored private var liveClearing: Task<Void, Never>?
    @ObservationIgnored private var liveBacklog: (document: PDFDocument, pages: IndexSet, complete: Bool)?

    /// Drawn over PDFKit's page; PDFKit's document takes it once the typing pauses, so a key costs one drawing.
    func showLive(_ page: PDFPage, at index: Int) {
        guard let shown = view.document?.page(ifAt: index) else { return }
        liveWaiting[index] = page
        liveBacklog?.pages.remove(index)
        guard view.showLive(page, over: shown, at: index) else { return settleLive() }
        liveClearing?.cancel()
        // Only if the whole document doesn't bring this page first (300 ms after the last key): it would go into PDFKit's document twice.
        restart(&liveSettling, after: .seconds(1)) { [weak self] in self?.settleLive() }
    }

    private func settleLive() {
        guard let document = view.document, !liveWaiting.isEmpty else { return }
        var gone: Set<PDFPage> = []
        // Not a page a whole document is still bringing (`takeLive`), which would go in twice.
        for (index, page) in liveWaiting where liveBacklog?.pages.contains(index) != true {
            liveWaiting[index] = nil
            guard let old = document.page(ifAt: index) else { continue }
            document.insert(page, at: index)
            document.removePage(at: index + 1)
            gone.insert(old)
        }
        replaced(gone)
    }

    /// A live page is drawn only where its page showed, so PDFKit takes the waiting ones for what comes into view.
    private func scrolled() {
        guard !liveWaiting.isEmpty else { return }
        Task { [weak self] in self?.settleLive() }
    }

    /// Only the pages in `changed` differ (nil: any may); PDFKit's document takes those a few milliseconds' worth at a time so a long document doesn't stop the typing.
    func showLive(_ document: PDFDocument, changed: IndexSet?, complete: Bool) {
        // Whole too once the pages taken hold too much (`memoryAtWhole`), if it is all there.
        guard let shown = view.document, var pages = changed, !(complete && hasGrown) else { return show(document) }
        if let liveBacklog { pages.formUnion(liveBacklog.pages) }
        if shown.pageCount < document.pageCount { pages.insert(integersIn: shown.pageCount..<document.pageCount) }
        pages.formIntersection(IndexSet(integersIn: 0..<document.pageCount))
        liveBacklog = (document, pages, complete)
        takeLive()
    }

    private func takeLive() {
        guard let shown = view.document, var backlog = liveBacklog else { return }
        liveBacklog = nil
        let start = ContinuousClock.now
        var gone: Set<PDFPage> = [], came = false
        while let index = backlog.pages.first, index <= shown.pageCount, ContinuousClock.now - start < .milliseconds(4) {
            backlog.pages.remove(index)
            guard let page = backlog.document.page(at: index)?.copy() as? PDFPage else { continue }
            let old = shown.page(ifAt: index)
            // A page in view goes in beneath a layer that shows it already, as PDFKit fades a new one in.
            if let old, liveWaiting.removeValue(forKey: index) == nil, !view.hasLive(at: index) {
                _ = view.showLive(page, over: old, at: index)
            }
            shown.insert(page, at: index)
            if let old {
                shown.removePage(at: index + 1)
                gone.insert(old)
            }
            came = true
        }
        if backlog.pages.first.map({ $0 <= shown.pageCount }) == true {
            liveBacklog = backlog
            Task { [weak self] in self?.takeLive() }
        } else if backlog.complete {
            while shown.pageCount > backlog.document.pageCount, let last = shown.page(at: shown.pageCount - 1) {
                liveWaiting[shown.pageCount - 1] = nil
                view.removeLive(at: shown.pageCount - 1)
                shown.removePage(at: shown.pageCount - 1)
                gone.insert(last)
            }
        }
        // Pages that came or went at the end leave the others where they were: the document view counts from its top.
        if gone.isEmpty, came { pageChanged() }
        replaced(gone)
    }

    private func replaced(_ gone: Set<PDFPage>) {
        guard !gone.isEmpty else { return }
        clearLiveLater()
        if view.currentSelection?.pages.contains(where: gone.contains) == true { view.clearSelection() }
        if let mark = view.mark, gone.contains(mark.page) { view.removeMark() }
        pageChanged()
        let kept = matches.filter { !$0.pages.contains(where: gone.contains) }
        if kept.count != matches.count {
            let chosen = matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
            matches = kept
            matchIndex = chosen.flatMap { kept.firstIndex(of: $0) } ?? min(matchIndex, max(0, kept.count - 1))
            view.highlightedSelections = kept.isEmpty ? nil : kept
        }
        guard finding else { return }
        cancelSearch()
        find(findText, keepingPlace: true)
    }

    /// The layers go once PDFKit has drawn its own pages' tiles and faded them in beneath (27.2).
    private func clearLiveLater() {
        restart(&liveClearing, after: .milliseconds(400)) { [weak self] in
            if let self, liveWaiting.isEmpty { view.removeLive() }
        }
    }

    private func dropLive() {
        liveSettling?.cancel()
        settleLive()
        liveClearing?.cancel()
        view.removeLive()
    }

    /// Before the page: where a page lands depends on the scale.
    private func restoreZoomIfReady() {
        guard let zoom = restoreZoom, view.document != nil, view.hasShownArea else { return }
        restoreZoom = nil
        switch zoom {
        case .fitWidth: fitWidth()
        case .fitPage: fitPage()
        case .scale(let scale): setScale(min(max(CGFloat(scale), Self.minScale), Self.maxScale))
        }
    }

    private func restorePageIfReady() {
        guard let number = restorePage, view.document != nil, view.hasShownArea else { return }
        restorePage = nil
        go(toPage: number)
    }

    func reveal(_ loc: ForwardLoc, word: SyncTeXWord?) {
        guard view.hasShownArea else {
            pendingReveal = (loc, word)
            return
        }
        pendingReveal = nil
        guard let document = view.document, let locatedPage = document.page(ifAt: Int(loc.page) - 1) else { return }
        // The source occurrence can wrap beyond the first SyncTeX box.
        let match = word.flatMap { document.match(for: $0, near: loc.matches ?? [loc]) }
        let page = match?.page ?? locatedPage
        let rect = match?.rect ?? SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY + view.shownHeight / 3 / view.scaleFactor)))
        if let selection = match?.selection, !finding {
            view.removeMark()
            selection.color = .findHighlightColor
            view.setCurrentSelection(selection, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            view.flash(rect, on: page)
        }
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        selectMatch()
    }

    private func selectMatch(scrolling: Bool = true) {
        guard matches.indices.contains(matchIndex), let match = matches[matchIndex].copy() as? PDFSelection else { return }
        // A copy without Find's colour, which PDFKit draws as the selection, over the mark every match has.
        match.color = nil
        view.setCurrentSelection(match, animate: scrolling && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if scrolling { view.scrollSelectionToVisible(nil) }
    }

    /// SyncTeX resolves only points on a glyph box, and the page centre is usually whitespace.
    func sourcePoint() -> (page: Int, point: CGPoint)? {
        guard let document = view.document else { return nil }
        let probe = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - view.safeAreaInsets.top - view.shownHeight * 0.2)
        guard let page = view.page(for: probe, nearest: true), let number = document.number(of: page) else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        var point = view.convert(probe, to: page)
        while point.y > bounds.minY {
            if let line = page.selectionForLine(at: point), let text = line.string,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let box = line.bounds(for: page)
                point = CGPoint(x: box.midX, y: box.minY)
                break
            }
            point.y -= 6
        }
        return (number, SyncTeXGeometry.synctexPoint(point, pageBounds: bounds))
    }
}

final class SyncPDFView: PDFView, PDFPageOverlayViewProvider {
    var onInverse: (_ page: Int, _ point: CGPoint, _ word: SyncTeXWord?) -> Void = { _, _, _ in }
    var onResize: () -> Void = {}
    private let pagesDark = Atomic(false)

    var darkPaper = false {
        didSet {
            pagesDark.store(darkPaper, ordering: .relaxed)
            pageShadowsEnabled = !darkPaper
            matchScroller()
            fitPageEdges()
        }
    }

    /// PDFKit's scroll view isn't in its interface: its document view leads to it.
    var pageScrollView: NSScrollView? { documentView?.enclosingScrollView }

    func matchScroller() {
        pageScrollView?.scrollerKnobStyle = darkPaper ? .light : .dark
    }

    override func zoomIn(_ sender: Any?) {
        autoScales = false
        super.zoomIn(sender)
    }

    override func zoomOut(_ sender: Any?) {
        autoScales = false
        super.zoomOut(sender)
    }

    /// PDFKit draws page tiles off the main actor; only page pixels change.
    override nonisolated func draw(_ page: PDFPage, to context: CGContext) {
        Self.drawPaper(page.bounds(for: .cropBox).applying(page.transform(for: .cropBox)), to: context,
                       dark: pagesDark.load(ordering: .relaxed)) { page.draw(with: .cropBox, to: context) }
    }

    private nonisolated static func drawPaper(_ box: CGRect, to context: CGContext, dark: Bool, page draw: () -> Void) {
        context.saveGState()
        defer { context.restoreGState() }
        func drawPage() {
            context.setFillColor(.white)
            context.fill(box)
            draw()
        }
        drawPage()
        guard dark else { return }
        context.setBlendMode(.difference)
        context.setFillColor(.white)
        context.fill(box)
        context.setBlendMode(.color)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setBlendMode(.normal)
        drawPage()
        context.endTransparencyLayer()
    }

    // MARK: - Live preview

    /// A page given to PDFKit fades in over an eighth of a second (27.2), and a layer's contents change in one frame.
    private let liveCanvas = LiveCanvas()
    private var liveLayers: [Int: CALayer] = [:]
    private var liveScale: CGFloat = 0
    private var shownScale: CGFloat { pageScrollView?.magnification ?? scaleFactor }
    var liveScaleChanged: Bool { !liveLayers.isEmpty && shownScale != liveScale }

    /// PDFKit rounds a page's frame to the display's pixels and draws at the view's scale from the frame's corner (27.2),
    /// so its page can take the layer's place unseen. Only the part in view is drawn: the whole grows with the square of
    /// the zoom, to half a gigabyte for A4 at 800% on a 2x display.
    func showLive(_ page: PDFPage, over shown: PDFPage, at index: Int) -> Bool {
        guard let documentView, let window, let overlay = overlays.object(forKey: shown), overlay.window != nil else { return false }
        let visible = overlay.visibleRect
        guard !visible.isEmpty else { return false }
        if liveCanvas.superview !== documentView {
            liveCanvas.frame = documentView.bounds
            documentView.addSubview(liveCanvas)
        }
        // PDFKit's scale is its scroll view's magnification: the size on screen is the one in the window.
        let onScreen = overlay.convert(overlay.bounds, to: nil).size, pixel = window.backingScaleFactor
        let box = page.bounds(for: .cropBox), scale = scaleFactor * pixel
        let whole = CGSize(width: (onScreen.width * pixel).rounded(), height: (onScreen.height * pixel).rounded())
        let unit = CGSize(width: overlay.bounds.width / (onScreen.width * pixel), height: overlay.bounds.height / (onScreen.height * pixel))
        let part = CGRect(x: (visible.minX - overlay.bounds.minX) / unit.width, y: (visible.minY - overlay.bounds.minY) / unit.height,
                          width: visible.width / unit.width, height: visible.height / unit.height)
            .integral.intersection(CGRect(origin: .zero, size: whole))
        let width = Int(part.width), height = Int(part.height)
        // Drawn into a surface the window server takes as it is: a bitmap of the layer's own is redrawn into the display's colours on its way to the screen (27.2).
        guard width >= 1, height >= 1,
              let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                   .pixelFormat: kCVPixelFormatType_32BGRA]),
              surface.lock(options: [], seed: nil) == KERN_SUCCESS else { return false }
        Self.drawLive(page, to: surface, box: box, scale: scale, from: part.origin, dark: darkPaper)
        surface.unlock(options: [], seed: nil)
        if let name = Self.liveSpace.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, name) }
        let layer = liveLayers[index] ?? {
            let layer = CALayer()
            // A layer animates what changes by default; these change with the page they show.
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            liveCanvas.layer?.addSublayer(layer)
            liveLayers[index] = layer
            return layer
        }()
        layer.contents = surface
        layer.frame = liveCanvas.convert(CGRect(x: overlay.bounds.minX + part.minX * unit.width, y: overlay.bounds.minY + part.minY * unit.height,
                                                width: part.width * unit.width, height: part.height * unit.height), from: overlay)
        liveScale = shownScale
        return true
    }

    private nonisolated static let liveSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Halves drawn at once by Core Graphics itself: most of a page's time is its fonts', and PDFKit draws a page for
    /// one caller at a time (27.2). A page whose box PDFKit would turn or move is drawn in one, by PDFKit.
    private nonisolated static func drawLive(_ page: PDFPage, to surface: IOSurface, box: CGRect, scale: CGFloat, from corner: CGPoint,
                                             dark: Bool) {
        // Drawing a page is safe from any thread, as PDFKit's own tiles are drawn.
        nonisolated(unsafe) let page = page
        nonisolated(unsafe) let ref = page.rotation == 0 && box.origin == .zero && page.bounds(for: .mediaBox) == box ? page.pageRef : nil
        let (width, height, halves) = (surface.width, surface.height, ref == nil ? 1 : 2)
        DispatchQueue.concurrentPerform(iterations: halves) { half in
            let rows = (height * half / halves)..<(height * (half + 1) / halves)
            guard let context = CGContext(data: surface.baseAddress + rows.lowerBound * surface.bytesPerRow, width: width,
                                          height: rows.count, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: liveSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            // A context counts from its own bottom row, the picture's rows from its top.
            context.translateBy(x: -corner.x, y: CGFloat(rows.upperBound - height) - corner.y)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            drawPaper(box, to: context, dark: dark) {
                if let ref { context.drawPDFPage(ref) } else { page.draw(with: .cropBox, to: context) }
            }
        }
    }

    func hasLive(at index: Int) -> Bool { liveLayers[index] != nil }

    func removeLive(at index: Int) {
        liveLayers.removeValue(forKey: index)?.removeFromSuperlayer()
    }

    func removeLive() {
        for layer in liveLayers.values { layer.removeFromSuperlayer() }
        liveLayers.removeAll()
    }

    /// In the page's overlay rather than an annotation, which would be printed and read by VoiceOver.
    private(set) var mark: (page: PDFPage, rect: CGRect, view: NSView, fading: Task<Void, Never>)?
    private let overlays = NSMapTable<PDFPage, NSView>.weakToWeakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pageOverlayViewProvider = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A fade is what the HIG puts in motion's place, so Reduce Motion keeps it.
    func flash(_ rect: CGRect, on page: PDFPage) {
        removeMark()
        let view = MarkView(onDarkPaper: darkPaper)
        let fading = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2.2)) } catch { return }
            await NSAnimationContext.runAnimationGroup { _ in view.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            self?.removeMark()
        }
        mark = (page, rect, view, fading)
        if let overlay = overlays.object(forKey: page) { place(view, at: rect, on: page, in: overlay) }
    }

    func removeMark() {
        mark?.fading.cancel()
        mark?.view.removeFromSuperview()
        mark = nil
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PageOverlay()
        overlay.dark = darkPaper
        overlays.setObject(overlay, forKey: page)
        return overlay
    }

    func fitPageEdges() {
        for case let overlay as PageOverlay in overlays.objectEnumerator()?.allObjects ?? [] {
            overlay.dark = darkPaper
            overlay.fitEdge()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fitPageEdges()
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlay: NSView, for page: PDFPage) {
        if let mark, mark.page === page { place(mark.view, at: mark.rect, on: page, in: overlay) }
    }

    /// Unrotated: PDFKit rotates the overlay itself.
    private func place(_ mark: NSView, at rect: CGRect, on page: PDFPage, in overlay: NSView) {
        let box = page.bounds(for: displayBox)
        let x = overlay.bounds.width / box.width, y = overlay.bounds.height / box.height
        mark.frame = CGRect(x: (rect.minX - box.minX) * x, y: (rect.minY - box.minY) * y,
                            width: rect.width * x, height: rect.height * y)
        mark.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin, .width, .height]
        overlay.addSubview(mark)
    }

    override func mouseMoved(with event: NSEvent) {
        if !updateDividerCursor(with: event) { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !updateDividerCursor(with: event) { super.cursorUpdate(with: event) }
    }

    /// SwiftUI reassigns unchanged frames during layout; PDFView would refit the width and undo a pinch in its own
    /// `setFrame:` while auto-scaling is active (27.2).
    override var frame: NSRect {
        get { super.frame }
        set { if newValue != super.frame { super.frame = newValue } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI reassigns the same frame on scroll; only a new size counts.
        guard newSize != frame.size else { return }
        // At the document start, width changes or Fit Page can lose the first page's visible top beneath the toolbar.
        let widthChanged = newSize.width != frame.width
        let atStart = hasShownArea && atDocumentStart
        super.setFrameSize(newSize)
        onResize()
        if atStart, widthChanged || !atDocumentStart, let page = document?.page(at: 0) {
            go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: displayBox).maxY)))
        }
    }

    private var atDocumentStart: Bool {
        guard let page = document?.page(at: 0) else { return false }
        let top = convert(CGPoint(x: 0, y: page.bounds(for: displayBox).maxY), from: page).y
        return top <= bounds.maxY - safeAreaInsets.top + pageBreakMargins.top * scaleFactor
    }

    /// `currentDestination` lies behind the bars.
    var shownDestination: PDFDestination? {
        let top = CGPoint(x: bounds.minX, y: bounds.maxY - safeAreaInsets.top)
        return page(for: top, nearest: true).map { PDFDestination(page: $0, at: convert(top, to: $0)) }
    }

    /// A double-click whose pointer has moved by the time PDFKit's handling returns was dragged on to select by words.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, let up = window?.mouseLocationOutsideOfEventStream else { return }
        let down = event.locationInWindow
        if abs(up.x - down.x) <= 4, abs(up.y - down.y) <= 4 { goToSource(at: convert(down, from: nil)) }
    }

    func jumpToSelection() {
        guard let selection = currentSelection, let page = selection.pages.first else { return }
        let box = selection.bounds(for: page)
        go(to: PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.midY + shownHeight / 2 / scaleFactor)))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        menu?.keep([#selector(copy(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:))])
        guard let menu, document != nil else { return menu }
        let item = NSMenuItem(title: MenuCommand.syncInverse.title, action: #selector(goToSource(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = convert(event.locationInWindow, from: nil)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func goToSource(_ item: NSMenuItem) {
        if let location = item.representedObject as? CGPoint { goToSource(at: location) }
    }

    private func goToSource(at location: CGPoint) {
        guard let page = page(for: location, nearest: true), let number = document?.number(of: page) else { return }
        let point = convert(location, to: page)
        onInverse(number, SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox)), page.syncWord(at: point))
    }
}

private final class LiveCanvas: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        // Over the page views PDFKit adds after it.
        layer?.zPosition = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PageOverlay: NSView {
    /// On dark paper, PDFKit's white layer under each page's tiles shows through the inverted tile as a light line
    /// where the page's edge falls inside a pixel (27.2); a black edge covers it.
    private let edge = CALayer()
    var dark = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        edge.borderColor = .black
        edge.isHidden = true
        layer?.addSublayer(edge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        fitEdge()
    }

    func fitEdge() {
        let pixel = convertFromBacking(NSSize(width: 1, height: 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.isHidden = !dark
        edge.frame = bounds.insetBy(dx: -pixel.width, dy: -pixel.height)
        edge.borderWidth = 2 * max(pixel.width, pixel.height)
        CATransaction.commit()
    }
}

private final class MarkView: NSView {
    private let paper: NSColor

    init(onDarkPaper dark: Bool) {
        paper = dark ? .black : .white
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let find = NSColor.findHighlightColor
        layer?.backgroundColor = find.withAlphaComponent(0.4).cgColor
        layer?.borderColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? find.contrasting(with: paper, by: 3).cgColor : find.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 1
    }
}

struct PDFRepresentable: NSViewRepresentable {
    let project: ProjectModel
    let darkPaper: Bool

    func makeNSView(context: Context) -> SyncPDFView {
        let view = project.pdf.view
        view.onInverse = { [weak project] page, point, word in
            Task { await project?.inverseSync(page: page, x: point.x, y: point.y, word: word) }
        }
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        project.pdf.setDarkPaper(darkPaper)
    }
}

extension PDFPage {
    /// PDFKit's characterIndex is inaccurate for pdfTeX's T1 fonts on 27.2; each letter's selection is measured instead.
    func syncWord(at point: CGPoint) -> SyncTeXWord? {
        // PDFKit's word lookup crashes on a page whose document has gone (it holds it weakly).
        guard document != nil, let word = selectionForWord(at: point), let text = word.string, let context = string else { return nil }
        let range = word.range(at: 0, on: self)
        let offset = (0..<range.length).first { i in
            selection(for: NSRange(location: range.location + i, length: 1)).map { $0.bounds(for: self).maxX > point.x } ?? false
        }
        return SyncTeXWord(text: text, offset: offset ?? 0, context: context, contextOffset: range.location)
    }

    nonisolated func hideLinkBorders() {
        for annotation in annotations where annotation.type == "Link" {
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
        }
    }
}

extension PDFDocument {
    /// `page(at:)` raises outside the document.
    func page(ifAt index: Int) -> PDFPage? {
        (0..<pageCount).contains(index) ? page(at: index) : nil
    }

    /// PDFKit answers NSNotFound for a page that has left the document.
    func number(of page: PDFPage) -> Int? {
        let index = index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

    /// Each put in before the one it replaces is taken out, so the document is never shorter than the place being read.
    func replacePages(with other: PDFDocument) {
        let pages = (0..<other.pageCount).compactMap { other.page(at: $0)?.copy() as? PDFPage }
        let old = pageCount
        for (index, page) in pages.enumerated() {
            insert(page, at: index)
            if index < old { removePage(at: index + 1) }
        }
        while pageCount > pages.count { removePage(at: pageCount - 1) }
        func here(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let target = destination.page, target.document === other,
                  let page = page(ifAt: other.index(for: target)) else { return nil }
            let local = PDFDestination(page: page, at: destination.point)
            local.zoom = destination.zoom
            return local
        }
        for link in pages.flatMap(\.annotations) where link.type == "Link" {
            if let destination = here(link.destination) { link.destination = destination }
            if let goTo = link.action as? PDFActionGoTo, let destination = here(goTo.destination) {
                link.action = PDFActionGoTo(destination: destination)
            }
        }
    }

    typealias SyncMatch = (page: PDFPage, rect: CGRect, selection: PDFSelection)

    func match(for word: SyncTeXWord, near locations: [ForwardLoc]) -> SyncMatch? {
        guard !locations.isEmpty, pageCount > 0 else { return nil }
        let first = max(0, Int(locations.lazy.map(\.page).min()!) - 2)
        let last = min(pageCount - 1, Int(locations.lazy.map(\.page).max()!))
        guard first <= last else { return nil }
        var letters: [Character] = [], positions: [(page: PDFPage, range: NSRange)] = []
        for index in first...last {
            guard let page = page(at: index), let text = page.string else { continue }
            let normalized = SyncText(text)
            letters += normalized.letters
            positions.append(contentsOf: normalized.ranges.lazy.map { (page, $0) })
        }
        let source = SyncText(word.context, source: true), target = SyncText(word.text).letters
        guard !target.isEmpty else { return nil }
        let at = source.ranges.firstIndex { $0.location >= word.contextOffset } ?? source.letters.count
        func rect(at start: Int, length: Int) -> SyncMatch? {
            guard start >= 0, start + length <= positions.count else { return nil }
            let first = positions[start]
            let samePage = positions[start..<start + length].prefix { $0.page === first.page }
            guard let end = samePage.last,
                  let selection = first.page.selection(for: NSRange(location: first.range.location,
                                                                    length: NSMaxRange(end.range) - first.range.location)) else { return nil }
            return (first.page, selection.bounds(for: first.page), selection)
        }
        func distance(_ hit: SyncMatch) -> CGFloat {
            let index = index(for: hit.page) + 1
            return locations.lazy.map { loc in
                let box = SyncTeXGeometry.highlightRect(loc, pageBounds: hit.page.bounds(for: .cropBox))
                let x = max(0, box.minX - hit.rect.maxX, hit.rect.minX - box.maxX)
                let y = max(0, box.minY - hit.rect.maxY, hit.rect.minY - box.maxY)
                return CGFloat(abs(Double(index) - loc.page)) * 100_000 + x + y
            }.min() ?? .greatestFiniteMagnitude
        }
        if at + target.count <= source.letters.count,
           source.letters[at..<at + target.count].elementsEqual(target) {
            let exact = SyncText.matches(source.letters, in: letters).compactMap { start -> (target: SyncMatch, distance: CGFloat, anchor: CGFloat)? in
                guard let anchor = rect(at: start, length: 1), let end = rect(at: start + source.letters.count - 1, length: 1),
                      let target = rect(at: start + at, length: target.count) else { return nil }
                return (target, distance(target), distance(anchor) + distance(end))
            }
            if let best = exact.min(by: { a, b in a.distance == b.distance ? a.anchor < b.anchor : a.distance < b.distance }) {
                let tied = exact.lazy.filter { abs($0.distance - best.distance) < 0.001 && abs($0.anchor - best.anchor) < 0.001 }.prefix(2)
                return tied.count == 1 ? best.target : nil
            }
        }
        let before = source.letters.prefix(at), after = source.letters.dropFirst(min(at + target.count, source.letters.count))
        let candidates = SyncText.matches(target, in: letters).compactMap { start -> (hit: SyncMatch, context: Int, distance: CGFloat)? in
            guard let hit = rect(at: start, length: target.count) else { return nil }
            let page = Double(index(for: hit.page) + 1)
            let boxes = locations.filter { $0.page == page }.map { SyncTeXGeometry.highlightRect($0, pageBounds: hit.page.bounds(for: .cropBox)) }
            guard let top = boxes.lazy.map(\.maxY).max(), let bottom = boxes.lazy.map(\.minY).min(),
                  hit.rect.maxY >= bottom - hit.rect.height, hit.rect.minY <= top + hit.rect.height else { return nil }
            let prefix = zip(before.reversed(), letters[..<start].reversed()).prefix { $0 == $1 }.count
            let suffix = zip(after, letters[(start + target.count)...]).prefix { $0 == $1 }.count
            return (hit, prefix + suffix, distance(hit))
        }
        guard let best = candidates.max(by: { a, b in a.context == b.context ? a.distance > b.distance : a.context < b.context }) else { return nil }
        // Equal evidence cannot identify which duplicate was clicked; keep SyncTeX's box.
        let tied = candidates.lazy.filter { $0.context == best.context && abs($0.distance - best.distance) < 0.001 }.prefix(2)
        return tied.count == 1 ? best.hit : nil
    }
}

private nonisolated struct SyncText {
    var letters: [Character] = []
    var ranges: [NSRange] = []

    init(_ text: String, source: Bool = false) {
        var offset = 0, command = false, escaped = false
        let ligatures = ["ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl"]
        for character in text {
            let value = String(character), length = value.utf16.count
            defer { offset += length }
            if source {
                if character == "\\" { command = true; escaped = true; continue }
                if command, character.isLetter { continue }
                command = false
                if character == "%", !escaped { break }
                escaped = false
            }
            for letter in (ligatures[value] ?? value.precomposedStringWithCanonicalMapping) where letter.isLetter || letter.isNumber {
                letters.append(letter)
                ranges.append(NSRange(location: offset, length: length))
            }
        }
    }

    static func matches(_ target: [Character], in text: [Character]) -> [Int] {
        guard !target.isEmpty, text.count >= target.count else { return [] }
        return (0...text.count - target.count).filter { start in
            text[start] == target[0] && text[start..<start + target.count].elementsEqual(target)
        }
    }
}

private extension PDFView {
    var shownHeight: CGFloat { bounds.height - safeAreaInsets.top - safeAreaInsets.bottom }

    var hasShownArea: Bool { bounds.width > 0 && shownHeight > 0 }
}

extension NSMenu {
    func keep(_ actions: Set<Selector>) {
        func kept(_ item: NSMenuItem) -> Bool {
            item.action.map(actions.contains) == true || item.submenu?.items.contains(where: kept) == true
        }
        let word = items.firstIndex { $0.action == #selector(NSText.cut(_:)) || $0.action == #selector(NSText.copy(_:)) } ?? 0
        var shown = Array(items[..<word])
        for item in items[word...] where item.isSeparatorItem ? shown.last?.isSeparatorItem == false : kept(item) { shown.append(item) }
        if shown.last?.isSeparatorItem == true { shown.removeLast() }
        items = shown
    }
}
