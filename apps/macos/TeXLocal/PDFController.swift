import PDFKit
import SwiftUI

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

    /// As a project's ui state keeps it (docs/core-api.md): "fitWidth", "fitPage" or a scale.
    nonisolated enum Zoom: Decodable, Hashable {
        case fitWidth, fitPage, scale(Double)

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let scale = try? value.decode(Double.self) {
                self = .scale(scale)
            } else {
                self = try value.decode(String.self) == "fitPage" ? .fitPage : .fitWidth
            }
        }

        var json: any Sendable {
            switch self {
            case .fitWidth: "fitWidth"
            case .fitPage: "fitPage"
            case .scale(let scale): scale
            }
        }
    }

    /// PDFKit would go to 10,000%; the toolbar's scale has room for three digits.
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 8
    private static func label(_ scale: CGFloat) -> String { Double(scale).formatted(.percent.precision(.fractionLength(0))) }

    @ObservationIgnored let view = SyncPDFView()
    let find: PDFFind
    private(set) var page = 0
    private(set) var pageCount = 0
    private(set) var scale: CGFloat = 1
    private(set) var zoom = Zoom.fitWidth
    var zoomLabel: String { Self.label(scale) }
    var widestZoomLabel: String { Self.label(Self.maxScale) }
    var canZoomIn: Bool { scale < Self.maxScale }
    var canZoomOut: Bool { scale > Self.minScale }

    /// A project's last page and zoom, kept until the view has a size to show them in.
    @ObservationIgnored var restorePage: Int?
    @ObservationIgnored var restoreZoom: Zoom?
    /// What a project keeps of the view, the restored place while it waits.
    var keptPage: Int? { restorePage ?? (page > 0 ? page : nil) }
    var keptZoom: Zoom { restoreZoom ?? zoom }
    @ObservationIgnored var onVisiblePages: (ClosedRange<Int>) -> Void = { _ in }
    @ObservationIgnored private var toldPages: ClosedRange<Int>?
    @ObservationIgnored private(set) var shownVersion = 0
    /// PDFKit keeps every replaced page's objects for its document's life (27.2): past this footprint the next is shown whole.
    @ObservationIgnored var wholeAt = UInt64.max
    @ObservationIgnored private var magnification: NSKeyValueObservation?
    @ObservationIgnored private weak var watched: NSScrollView?
    @ObservationIgnored private var scrolling: NotificationCenter.ObservationToken?

    @ObservationIgnored var liveWaiting: [Int: PDFPage] = [:]
    @ObservationIgnored var liveSettling: Task<Void, Never>?
    @ObservationIgnored var liveClearing: Task<Void, Never>?
    @ObservationIgnored var liveTaking: Task<Void, Never>?
    @ObservationIgnored var liveBacklog: (document: PDFDocument, pages: IndexSet, complete: Bool)?
    @ObservationIgnored var liveMissed = false
    @ObservationIgnored var liveShown = false

    @ObservationIgnored var pendingReveal: (loc: ForwardLoc, source: SyncSource?)?
    @ObservationIgnored var revealing: Task<Void, Never>?

    override init() {
        find = PDFFind(view: view)
        super.init()
        view.backgroundColor = .untintedTextBackground
        // As Preview's: a page keeps PDFKit's side margins, which scale with it, and the first meets the toolbar's edge.
        view.pageBreakMargins.top = 0
        view.autoScales = true
        view.onResize = { [weak self] in
            guard let self else { return }
            dropLive()
            if zoom == .fitPage { fitPage() }
            restoreIfReady()
            if let pending = pendingReveal { reveal(pending.loc, from: pending.source) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(visiblePagesChanged), name: .PDFViewVisiblePagesChanged, object: view)
        // Only as a pinch ends; the scroll view's magnification follows each step.
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
    }

    private func watchScrollView() {
        guard let scrollView = view.pageScrollView, scrollView !== watched else { return }
        watched = scrollView
        magnification = scrollView.observe(\.magnification, options: .initial) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scaleChanged() }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrolling = NotificationCenter.default.addObserver(of: scrollView.contentView, for: .boundsDidChange) { [weak self] _ in self?.scrolled() }
    }

    @objc func pageChanged() {
        guard let document = view.document, let page = view.currentPage else { return }
        if let number = document.number(of: page) { self.page = number }
        pageCount = document.pageCount
    }

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
        if view.autoScales, abs(scale - view.scaleFactorForSizeToFit) < 0.001 {
            zoom = .fitWidth
        } else if zoom != .fitPage || abs(scale - pageScale) > 0.001 {
            zoom = .scale(Double(scale))
        }
    }

    private var pageScale: CGFloat {
        guard let page = view.currentPage else { return view.scaleFactor }
        let margins = view.pageBreakMargins, box = page.bounds(for: view.displayBox)
        // The box is in page space; a page turned a quarter shows its width upright.
        let pageHeight = page.rotation.isMultiple(of: 180) ? box.height : box.width
        return min(view.shownHeight / (pageHeight + margins.top + margins.bottom), view.scaleFactorForSizeToFit)
    }

    func apply(_ zoom: Zoom) {
        switch zoom {
        case .fitWidth: fitWidth()
        case .fitPage: fitPage()
        case .scale(let scale): setScale(CGFloat(scale))
        }
    }

    /// Off the fit at once; the new scale comes with PDFKit's change.
    func setScale(_ scale: CGFloat) {
        zoom = .scale(Double(self.scale))
        view.autoScales = false
        view.scaleFactor = scale
    }

    func zoom(in zoomIn: Bool) {
        zoom = .scale(Double(scale))
        if zoomIn { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }

    func go(toPage number: Int) {
        if let document = view.document, let page = document.page(ifAt: min(max(number, 1), document.pageCount) - 1) { view.go(to: page) }
    }

    func fitWidth() {
        zoom = .fitWidth
        view.autoScales = true
    }

    /// The fit after the scale, whose change ends a fit.
    func fitPage() {
        guard view.currentPage != nil, view.shownHeight > 0 else { return }
        if view.autoScales { view.autoScales = false }
        let scale = pageScale
        if view.scaleFactor != scale { view.scaleFactor = scale }
        zoom = .fitPage
    }

    /// The file given (the build's during Live Preview, as the document showing is TeXpresso's), or the document showing.
    /// The operation keeps the document (27.2).
    func print(title: String, file: URL?) {
        Task {
            let document = if let file { await Self.loadDocument(file) } else { view.document }
            // The build's file can be half-written while the next build runs.
            guard let operation = document?.printOperation(for: .shared, scalingMode: .pageScaleDownToFit, autoRotate: true),
                  let window = view.window ?? NSApp.mainWindow else { return NSSound.beep() }
            operation.jobTitle = title
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    /// Into the document showing: a new one shows only PDFKit's background until its pages draw (27.2).
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
            wholeAt = Self.footprint + 512 << 20
        }
        watchScrollView()
        // A document resets the limits (27.2). Setting them turns fitting off, so before the fit below.
        view.minScaleFactor = Self.minScale
        view.maxScaleFactor = Self.maxScale
        view.pageScrollView?.setAccessibilityLabel("PDF")
        view.matchScroller()
        if autoScales { view.autoScales = true } else { view.scaleFactor = scale }
        restoreIfReady()
        if let place { go(to: place) }
        pageChanged()
        find.rerun()
    }

    var hasGrown: Bool { Self.footprint > wholeAt }

    private static var footprint: UInt64 {
        var usage = rusage_info_current()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return read == 0 ? usage.ri_phys_footprint : 0
    }

    private func go(to place: (index: Int, point: CGPoint)) {
        guard let document = view.document, let page = document.page(ifAt: min(place.index, document.pageCount - 1)) else { return }
        view.go(to: PDFDestination(page: page, at: place.point))
        // PDFKit rounds destinations with legacy scrollbars; repeated builds must not drift.
        guard let scroll = view.pageScrollView else { return }
        let clip = scroll.contentView
        let target = clip.convert(view.convert(place.point, from: page), from: view)
        let top = clip.convert(CGPoint(x: view.bounds.minX, y: view.bounds.maxY - view.safeAreaInsets.top), from: view)
        clip.scroll(to: CGPoint(x: clip.bounds.minX + target.x - top.x, y: clip.bounds.minY + target.y - top.y))
        scroll.reflectScrolledClipView(clip)
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

    /// The zoom before the page: where a page lands depends on the scale.
    private func restoreIfReady() {
        guard view.document != nil, view.hasShownArea else { return }
        if let zoom = restoreZoom.take() { apply(zoom) }
        if let number = restorePage.take() { go(toPage: number) }
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

    /// `new` in before the old page out, so the document is never shorter than the place being read.
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
