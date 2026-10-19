import PDFKit
import SwiftUI

/// The PDF pane's view and what it shows: the document, its zoom and page, and printing. Live Preview's pages are
/// PDFController+Live.swift's, and SyncTeX's reveal PDFController+Sync.swift's.
@Observable
final class PDFController: NSObject {
    /// Read whole: the next build rewrites the file in place.
    @concurrent static func loadDocument(_ url: URL) async -> sending PDFDocument? {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        for index in 0..<document.pageCount {
            for link in document.page(at: index)?.annotations ?? [] where link.type == "Link" {
                let border = PDFBorder()
                border.lineWidth = 0
                link.border = border
            }
        }
        return document
    }

    @ObservationIgnored let view = SyncPDFView()
    let find: PDFFind
    @ObservationIgnored private var magnification: NSKeyValueObservation?
    @ObservationIgnored private weak var watched: NSScrollView?
    @ObservationIgnored private var scrolling: NotificationCenter.ObservationToken?
    private(set) var page = 0
    @ObservationIgnored var restorePage: Int?
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

    nonisolated enum Zoom: Codable, Hashable { case fitWidth, fitPage, scale(Double) }

    var zoom: Zoom {
        switch fit {
        case .width: .fitWidth
        case .page: .fitPage
        case nil: .scale(Double(scale))
        }
    }

    @ObservationIgnored var restoreZoom: Zoom?

    // Live Preview's (PDFController+Live.swift): pages drawn over PDFKit's that its document takes once the typing
    // pauses, and a whole document's pages still to take.
    @ObservationIgnored var liveWaiting: [Int: PDFPage] = [:]
    @ObservationIgnored var liveSettling: Task<Void, Never>?
    @ObservationIgnored var liveClearing: Task<Void, Never>?
    @ObservationIgnored var liveTaking: Task<Void, Never>?
    @ObservationIgnored var liveBacklog: (document: PDFDocument, pages: IndexSet, complete: Bool)?
    @ObservationIgnored var liveMissed = false
    /// Whether the run's first document shows: a page before it goes, as it would be drawn over the build's PDF or the
    /// last run's.
    @ObservationIgnored var liveShown = false

    // SyncTeX's (PDFController+Sync.swift): a reveal waits for the pane to have room, and for the core's match.
    @ObservationIgnored var pendingReveal: (loc: ForwardLoc, source: SyncSource?)?
    @ObservationIgnored var revealing: Task<Void, Never>?

    override init() {
        find = PDFFind(view: view)
        super.init()
        // As Preview's: a page keeps PDFKit's margin at its sides, which scales with it, and the first meets the toolbar's edge,
        // where its top margin showed as a strip under the toolbar's line at some widths and scrolls and not others. Pages
        // keep their bottom margins' gap between them.
        let margins = view.pageBreakMargins
        view.pageBreakMargins = NSEdgeInsets(top: 0, left: margins.left, bottom: margins.bottom, right: margins.right)
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

    @objc func pageChanged() {
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

    /// The zoom menu's choice, or the one a project last had.
    func apply(_ zoom: Zoom) {
        switch zoom {
        case .fitWidth: fitWidth()
        case .fitPage: fitPage()
        case .scale(let scale): setScale(min(max(CGFloat(scale), Self.minScale), Self.maxScale))
        }
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
    var hasGrown: Bool {
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
        revealing?.cancel()
        resetLive()
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
        // The knob is over white paper, whatever the window's appearance.
        view.pageScrollView?.scrollerKnobStyle = .dark
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
        pendingReveal = nil
        revealing?.cancel()
        resetLive()
        dropLive()
        view.removeMark()
        find.reset()
        view.document = nil
        (page, pageCount) = (0, 0)
    }

    /// Before the page: where a page lands depends on the scale.
    private func restoreZoomIfReady() {
        guard let zoom = restoreZoom, view.document != nil, view.hasShownArea else { return }
        restoreZoom = nil
        apply(zoom)
    }

    private func restorePageIfReady() {
        guard let number = restorePage, view.document != nil, view.hasShownArea else { return }
        restorePage = nil
        go(toPage: number)
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
