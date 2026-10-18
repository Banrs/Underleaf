import PDFKit
import SwiftUI

@Observable
final class PDFController: NSObject {
    /// Read whole: the next build rewrites the file in place.
    @concurrent static func loadDocument(_ url: URL) async -> sending PDFDocument? {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        for index in 0..<document.pageCount { document.page(at: index)?.hideLinkBorders() }
        return document
    }

    @ObservationIgnored let view = SyncPDFView()
    let find: PDFFind
    @ObservationIgnored private var magnification: NSKeyValueObservation?
    @ObservationIgnored private weak var watched: NSScrollView?
    @ObservationIgnored private var scrolling: NotificationCenter.ObservationToken?
    private(set) var page = 0
    @ObservationIgnored var restorePage: Int?
    @ObservationIgnored private var pendingReveal: (loc: ForwardLoc, source: SyncSource?)?
    @ObservationIgnored private var revealing: Task<Void, Never>?
    private(set) var pageCount = 0
    private(set) var scale: CGFloat = 1
    var zoomLabel: String { Self.label(scale) }
    var widestZoomLabel: String { Self.label(Self.maxScale) }
    var canZoomIn: Bool { scale < Self.maxScale }
    var canZoomOut: Bool { scale > Self.minScale }
    /// PDFKit would go to 10,000%; the toolbar's scale reserves a three-digit label's width.
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 8
    private static func label(_ scale: CGFloat) -> String { Double(scale).formatted(.percent.precision(.fractionLength(0))) }
    enum Fit { case width, page }
    private(set) var fit: Fit? = .width

    nonisolated enum Zoom: Codable, Equatable { case fitWidth, fitPage, scale(Double) }

    var zoom: Zoom {
        switch fit {
        case .width: .fitWidth
        case .page: .fitPage
        case nil: .scale(Double(scale))
        }
    }

    @ObservationIgnored var restoreZoom: Zoom?

    override init() {
        find = PDFFind(view: view)
        super.init()
        view.backgroundColor = .untintedTextBackground
        // A fitted page meets the pane's sides: PDFKit's 4 pt there drew a second edge just inside the window's own and the
        // divider. Pages keep their gaps between them.
        let margins = view.pageBreakMargins
        view.pageBreakMargins = NSEdgeInsets(top: margins.top, left: 0, bottom: margins.bottom, right: 0)
        view.autoScales = true
        view.onResize = { [weak self] in
            guard let self else { return }
            dropLive()
            restoreZoomIfReady()
            if fit == .page { fitPage() }
            restorePageIfReady()
            if let pending = pendingReveal { reveal(pending.loc, from: pending.source) }
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
        if let document = view.document, let page = document.page(ifAt: min(max(number, 1), document.pageCount) - 1) { view.go(to: page) }
    }

    @ObservationIgnored var buildBehindLive: () -> URL? = { nil }

    /// During Live Preview the build's file, since the document showing is TeXpresso's. The operation keeps the document (27.2).
    func print(title: String) {
        Task {
            let document = if let url = buildBehindLive() { await Self.loadDocument(url) } else { view.document }
            // The build's file can be half-written while the next build runs.
            guard let operation = document?.printOperation(for: .shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
                return NSSound.beep()
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
        (liveBacklog, liveMissed, liveShown) = (nil, false, false)
        clearLiveLater()
        // Read before the swap: a page keeps its document only weakly.
        let place = restorePage == nil ? view.shownPlace : nil
        let (autoScales, scale) = (view.autoScales, view.scaleFactor)
        view.removeMark()
        if view.document != nil {
            find.cancel()
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
        if let place { go(to: place) } else { restorePageIfReady() }
        pageChanged()
        find.rerun()
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
        liveWaiting.removeAll()
        dropLive()
        (liveBacklog, liveMissed, liveShown) = (nil, false, false)
        view.removeMark()
        find.reset()
        view.document = nil
        (page, pageCount) = (0, 0)
    }

    // MARK: - Live preview

    @ObservationIgnored private var liveWaiting: [Int: PDFPage] = [:]
    @ObservationIgnored private var liveSettling: Task<Void, Never>?
    @ObservationIgnored private var liveClearing: Task<Void, Never>?
    @ObservationIgnored private var liveTaking: Task<Void, Never>?
    @ObservationIgnored private var liveBacklog: (document: PDFDocument, pages: IndexSet, complete: Bool)?
    @ObservationIgnored private var liveMissed = false
    /// Whether the run's first document shows: a page before it goes, as it would be drawn over the build's PDF or the last run's.
    @ObservationIgnored private var liveShown = false

    /// How long a page drawn over PDFKit's waits for its whole document, which comes 300 ms after the last key and brings
    /// it first, before PDFKit's document takes it alone.
    private static let liveSettleDelay: Duration = .seconds(1)
    /// PDFKit fades a page it is given in over about 240 ms (27.2); the layers over its pages go after that.
    private static let liveClearDelay: Duration = .milliseconds(400)

    /// A live PDF as `Core` read it where the event arrived, in the order the session sent them.
    func showLive(_ read: LiveRead) {
        switch read {
        case .document(let live?):
            var changed = live.changed
            // After a document that wasn't read, any page may differ from what shows.
            if liveMissed, changed != nil { changed = IndexSet(integersIn: 0..<live.document.pageCount) }
            liveMissed = false
            showLive(live.document, changed: changed, complete: live.complete)
            liveShown = true
        case .document(nil):
            liveMissed = true
        case .page(let live?) where liveShown:
            showLive(live.page, at: live.index)
        case .page:
            break
        }
    }

    /// A run of Live Preview ended, or another began: nothing of the last run's counts in the next.
    func endLiveRun() { (liveMissed, liveShown) = (false, false) }

    /// Drawn over PDFKit's page; PDFKit's document takes it once the typing pauses, so a key costs one drawing. A page
    /// past the document showing goes: the next document has it.
    func showLive(_ page: PDFPage, at index: Int) {
        guard let shown = view.document?.page(ifAt: index) else { return }
        liveWaiting[index] = page
        liveBacklog?.pages.remove(index)
        guard view.showLive(page, over: shown, at: index) else { return settleLive() }
        liveClearing?.cancel()
        // Only if the whole document doesn't bring this page first: it would go into PDFKit's document twice.
        restart(&liveSettling, after: Self.liveSettleDelay) { [weak self] in self?.settleLive() }
    }

    private func settleLive() {
        guard let document = view.document, !liveWaiting.isEmpty else { return }
        var gone: Set<PDFPage> = []
        // Not a page a whole document is still bringing (`takeLive`), which would go in twice.
        for (index, page) in liveWaiting where liveBacklog?.pages.contains(index) != true {
            liveWaiting[index] = nil
            if let old = document.replacePage(at: index, with: page) { gone.insert(old) }
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

    /// The first share at once, in the event's own turn; the rest a share a turn, so the typing goes on between them. A
    /// document that comes meanwhile has its first share at once too, and the turns go on with what it leaves.
    private func takeLive() {
        guard takeLiveShare(), liveTaking == nil else { return }
        liveTaking = Task { [weak self] in
            repeat { await Task.yield() } while self?.takeLiveShare() == true
            self?.liveTaking = nil
        }
    }

    /// Whether pages are left for the next turn.
    private func takeLiveShare() -> Bool {
        guard let shown = view.document, var backlog = liveBacklog else { return false }
        liveBacklog = nil
        let start = ContinuousClock.now
        var gone: Set<PDFPage> = [], came = false
        while let index = backlog.pages.first, index <= shown.pageCount, ContinuousClock.now - start < .milliseconds(4) {
            backlog.pages.remove(index)
            guard let page = backlog.document.page(at: index)?.copy() as? PDFPage else { continue }
            // A page in view goes in beneath a layer that shows it already, as PDFKit fades a new one in.
            if let old = shown.page(ifAt: index), liveWaiting.removeValue(forKey: index) == nil, !view.hasLive(at: index) {
                _ = view.showLive(page, over: old, at: index)
            }
            if let old = shown.replacePage(at: index, with: page) { gone.insert(old) } else { shown.insert(page, at: index) }
            came = true
        }
        if backlog.pages.first.map({ $0 <= shown.pageCount }) == true {
            liveBacklog = backlog
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
        return liveBacklog != nil
    }

    private func replaced(_ gone: Set<PDFPage>) {
        guard !gone.isEmpty else { return }
        clearLiveLater()
        if view.currentSelection?.pages.contains(where: gone.contains) == true { view.clearSelection() }
        if let mark = view.mark, gone.contains(mark.page) { view.removeMark() }
        pageChanged()
        find.pagesReplaced(gone)
    }

    /// The layers go once PDFKit has drawn its own pages' tiles and faded them in beneath (27.2).
    private func clearLiveLater() {
        restart(&liveClearing, after: Self.liveClearDelay) { [weak self] in
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

    /// The source's word is looked for in the text of the pages round SyncTeX's boxes (`synctex_match`) and selected; where
    /// it isn't found once, SyncTeX's box flashes.
    func reveal(_ loc: ForwardLoc, from source: SyncSource? = nil) {
        pendingReveal = view.hasShownArea ? nil : (loc, source)
        guard pendingReveal == nil else { return }
        revealing?.cancel()
        guard let document = view.document, let located = document.page(ifAt: Int(loc.page) - 1) else { return }
        guard let source else { return showFound(loc, on: located, hit: nil) }
        let pages = syncPages(loc.matches ?? [loc], in: document)
        revealing = Task {
            let hit = try? await Core.shared.call("synctex_match", ["id": source.id, "file": source.file, "line": source.line,
                                                                    "column": source.column, "pages": pages], as: PageHit?.self)
            guard !Task.isCancelled, view.document === document else { return }
            showFound(loc, on: located, hit: hit)
        }
    }

    private func showFound(_ loc: ForwardLoc, on located: PDFPage, hit: PageHit?) {
        var found: (page: PDFPage, selection: PDFSelection)?
        if let hit, hit.end > hit.start, let page = view.document?.page(ifAt: hit.page - 1),
           let selection = page.selection(for: NSRange(location: hit.start, length: hit.end - hit.start)) {
            found = (page, selection)
        }
        let page = found?.page ?? located
        let rect = found.map { $0.selection.bounds(for: $0.page) }
            ?? SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY + view.shownHeight / 3 / view.scaleFactor)))
        if let selection = found?.selection, !find.isOpen {
            view.removeMark()
            selection.color = .findHighlightColor
            view.setCurrentSelection(selection, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            view.flash(rect, on: page)
        }
    }

    /// The pages from the one before SyncTeX's first box to the one after its last: each one's text, and the UTF-16 ranges
    /// of it the boxes cover. The source's line can wrap past the first box, and TeX can be a page on.
    private func syncPages(_ boxes: [ForwardLoc], in document: PDFDocument) -> [[String: any Sendable]] {
        let numbers = boxes.map { Int($0.page) }
        guard let lowest = numbers.min(), let highest = numbers.max() else { return [] }
        let first = max(1, lowest - 1), last = min(document.pageCount, highest + 1)
        guard first <= last else { return [] }
        return (first...last).compactMap { number -> [String: any Sendable]? in
            guard let page = document.page(ifAt: number - 1), let text = page.string else { return nil }
            let bounds = page.bounds(for: view.displayBox)
            var near: [[Int]] = []
            for box in boxes where Int(box.page) == number {
                guard let covered = page.selection(for: SyncTeXGeometry.highlightRect(box, pageBounds: bounds)) else { continue }
                for index in 0..<covered.numberOfTextRanges(on: page) {
                    let range = covered.range(at: index, on: page)
                    if range.location != NSNotFound, range.length > 0 { near.append([range.location, NSMaxRange(range)]) }
                }
            }
            return ["page": number, "text": text, "near": near]
        }
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

extension PDFPage {
    /// The page's text and the clicked letter's index in it, for the core to find in the source. PDFKit's characterIndex is
    /// inaccurate for pdfTeX's T1 fonts on 27.2; each letter's selection is measured instead.
    func click(at point: CGPoint) -> PageClick? {
        // PDFKit's word lookup crashes on a page whose document has gone (it holds it weakly).
        guard document != nil, let word = selectionForWord(at: point), let text = string else { return nil }
        let range = word.range(at: 0, on: self)
        guard range.location != NSNotFound else { return nil }
        let offset = (0..<range.length).first { i in
            selection(for: NSRange(location: range.location + i, length: 1)).map { $0.bounds(for: self).maxX > point.x } ?? false
        }
        return PageClick(text: text, at: range.location + (offset ?? 0))
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
    func page(ifAt index: Int) -> PDFPage? { (0..<pageCount).contains(index) ? page(at: index) : nil }

    /// PDFKit answers NSNotFound for a page that has left the document.
    func number(of page: PDFPage) -> Int? {
        let index = index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

    /// Puts `new` in at `index` before taking out the page it replaces, which it answers, so the document is never shorter
    /// than the place being read. Past the end, nothing is put in.
    func replacePage(at index: Int, with new: PDFPage) -> PDFPage? {
        guard let old = page(ifAt: index) else { return nil }
        insert(new, at: index)
        removePage(at: index + 1)
        return old
    }

    func replacePages(with other: PDFDocument) {
        let pages = (0..<other.pageCount).compactMap { other.page(at: $0)?.copy() as? PDFPage }
        for (index, page) in pages.enumerated() {
            if replacePage(at: index, with: page) == nil { insert(page, at: index) }
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
}
