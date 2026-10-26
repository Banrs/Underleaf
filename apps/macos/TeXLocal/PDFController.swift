import PDFKit
import SwiftUI

@Observable
final class PDFController: NSObject {
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

    @ObservationIgnored var restorePage: Int?
    @ObservationIgnored var restoreZoom: Zoom?
    @ObservationIgnored var onVisiblePages: (ClosedRange<Int>) -> Void = { _ in }
    @ObservationIgnored private var toldPages: ClosedRange<Int>?
    @ObservationIgnored private(set) var shownVersion = 0
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
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
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

    @objc func visiblePagesChanged() {
        guard let pages = visiblePages, pages != toldPages else { return }
        toldPages = pages
        onVisiblePages(pages)
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
        if view.autoScales, abs(scale - view.scaleFactorForSizeToFit) < 0.001 {
            zoom = .fitWidth
        } else if zoom != .fitPage || abs(scale - pageScale) > 0.001 {
            zoom = .scale(Double(scale))
        }
    }

    private var pageScale: CGFloat {
        guard let page = view.currentPage else { return view.scaleFactor }
        let margins = view.pageBreakMargins, box = page.bounds(for: view.displayBox)
        let pageHeight = page.rotation.isMultiple(of: 180) ? box.height : box.width
        return min(view.shownHeight / (pageHeight + margins.top + margins.bottom), view.scaleFactorForSizeToFit)
    }

    func setScale(_ scale: CGFloat) {
        zoom = .scale(Double(self.scale))
        view.autoScales = false
        view.scaleFactor = scale
    }

    func zoom(in zoomIn: Bool) {
        zoom = .scale(Double(scale))
        if zoomIn { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }

    func fitPage() {
        guard view.currentPage != nil, view.shownHeight > 0 else { return }
        if view.autoScales { view.autoScales = false }
        let scale = pageScale
        if view.scaleFactor != scale { view.scaleFactor = scale }
        zoom = .fitPage
    }

    func apply(_ zoom: Zoom) {
        switch zoom {
        case .fitWidth: fitWidth()
        case .fitPage: fitPage()
        case .scale(let scale): setScale(CGFloat(scale))
        }
    }

    func go(toPage number: Int) {
        if let document = view.document, let page = document.page(ifAt: min(max(number, 1), document.pageCount) - 1) { view.go(to: page) }
    }

    func fitWidth() {
        zoom = .fitWidth
        view.autoScales = true
    }

    func restoreIfReady() {
        guard view.document != nil, view.hasShownArea else { return }
        if let zoom = restoreZoom.take() { apply(zoom) }
        if let number = restorePage.take() { go(toPage: number) }
    }

    var keptPage: Int? { restorePage ?? (page > 0 ? page : nil) }
    var keptZoom: Zoom { restoreZoom ?? zoom }

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

    func print(title: String, file: URL?) {
        Task {
            let document = if let file { await Self.loadDocument(file) } else { view.document }
            guard let operation = document?.printOperation(for: .shared, scalingMode: .pageScaleDownToFit, autoRotate: true),
                  let window = view.window ?? NSApp.mainWindow else { return NSSound.beep() }
            operation.jobTitle = title
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    func show(_ document: PDFDocument) {
        shownVersion += 1
        revealing?.cancel()
        resetLive()
        clearLiveLater()
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
        view.minScaleFactor = Self.minScale
        view.maxScaleFactor = Self.maxScale
        view.pageScrollView?.setAccessibilityLabel("PDF")
        view.matchScroller()
        if autoScales { view.autoScales = true } else { view.scaleFactor = scale }
        restoreIfReady()
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
}

extension PDFDocument {
    func page(ifAt index: Int) -> PDFPage? { (0..<pageCount).contains(index) ? page(at: index) : nil }

    func number(of page: PDFPage) -> Int? {
        let index = index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

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
