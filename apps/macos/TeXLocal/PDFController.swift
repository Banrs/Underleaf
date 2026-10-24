import PDFKit
import SwiftUI

@Observable
final class PDFController: NSObject {
    /// PDFKit would go to 10,000%; the toolbar's scale has room for three digits.
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 8
    private static func label(_ scale: CGFloat) -> String { Double(scale).formatted(.percent.precision(.fractionLength(0))) }

    @ObservationIgnored let view = SyncPDFView()
    let find: PDFFind
    var page = 0
    var pageCount = 0
    private(set) var scale: CGFloat = 1
    var zoom = Zoom.fitWidth
    var zoomLabel: String { Self.label(scale) }
    var widestZoomLabel: String { Self.label(Self.maxScale) }
    var canZoomIn: Bool { scale < Self.maxScale }
    var canZoomOut: Bool { scale > Self.minScale }

    /// A project's last page and zoom, kept until the view has a size to show them in.
    @ObservationIgnored var restorePage: Int?
    @ObservationIgnored var restoreZoom: Zoom?
    @ObservationIgnored var onVisiblePages: (ClosedRange<Int>) -> Void = { _ in }
    @ObservationIgnored var toldPages: ClosedRange<Int>?
    @ObservationIgnored private(set) var shownVersion = 0
    /// PDFKit keeps every replaced page's objects for its document's life: past this footprint the next is shown whole
    /// (`aDocumentIsShownWholeOnceTheAppHasGrown`).
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

    /// The fit after the scale, whose change ends a fit.
    func fitPage() {
        guard view.currentPage != nil, view.shownHeight > 0 else { return }
        if view.autoScales { view.autoScales = false }
        let scale = pageScale
        if view.scaleFactor != scale { view.scaleFactor = scale }
        zoom = .fitPage
    }

    /// The file given (the build's during Live Preview, as the document showing is TeXpresso's), or the document showing.
    /// The operation keeps the document.
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

    /// Into the document showing: a new one shows only PDFKit's background until its pages draw
    /// (`aRebuildNeverShowsAnEmptyPane`).
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
        // A document resets the limits (`eachDocumentHasTheZoomsLimits`). Setting them turns fitting off, so before the fit
        // below.
        view.minScaleFactor = Self.minScale
        view.maxScaleFactor = Self.maxScale
        view.pageScrollView?.setAccessibilityLabel("PDF")
        view.matchScroller()
        if autoScales { view.autoScales = true } else { view.scaleFactor = scale }
        restoreIfReady()
        // A first document's first page meets the toolbar's edge: PDFKit's own start leaves it under the bar.
        let start = document.page(at: 0).map { (index: 0, point: CGPoint(x: 0, y: $0.bounds(for: view.displayBox).maxY)) }
        if let place = place ?? (restorePage == nil ? start : nil) { go(to: place) }
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
}
