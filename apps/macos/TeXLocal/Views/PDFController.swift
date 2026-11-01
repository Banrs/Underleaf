import PDFKit
import os
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
    /// A PDF is being read: the pane's empty state stays hidden meanwhile, as the window no longer waits for it.
    private(set) var isLoading = false
    private(set) var scale: CGFloat = 1
    var zoom = Zoom.fitWidth
    var zoomLabel: String { Self.label(scale) }
    var widestZoomLabel: String { Self.label(Self.maxScale) }
    var canZoomIn: Bool { scale < Self.maxScale }
    var canZoomOut: Bool { scale > Self.minScale }

    @ObservationIgnored var restoreZoom: Zoom?
    @ObservationIgnored var onVisiblePages: (ClosedRange<Int>) -> Void = { _ in }
    @ObservationIgnored private var toldPages: ClosedRange<Int>?
    @ObservationIgnored private(set) var shownVersion = 0
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private var magnification: NSKeyValueObservation?
    @ObservationIgnored private weak var watched: NSScrollView?

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
            if zoom == .fitPage { fitPage() }
            restoreIfReady()
            if let pending = pendingReveal { reveal(pending.loc, from: pending.source) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(visiblePagesChanged), name: .PDFViewVisiblePagesChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
    }

    @objc private func pageChanged() {
        guard let document = view.document else { return }
        pageCount = document.pageCount
        if let page = view.currentPage, let number = document.number(of: page) { self.page = number }
    }

    private var visiblePages: ClosedRange<Int>? {
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
        scrollView.setAccessibilityLabel("PDF")
        view.matchScroller()
        magnification = scrollView.observe(\.magnification, options: .initial) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scaleChanged() }
        }
    }

    @objc private func scaleChanged() {
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
        zoom = .scale(Double(scale))
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

    private func restoreIfReady() {
        guard view.document != nil, view.hasShownArea, let zoom = restoreZoom.take() else { return }
        apply(zoom)
        view.goToStart()
    }

    var keptZoom: Zoom { restoreZoom ?? zoom }

    func load(_ url: URL?) -> Task<Void, Never> {
        let wanted = view.coverPages
        isLoading = true
        return restart(&loading) { [self] in
            let loaded: LoadedPDF? = if let url { await Self.loadDocument(url, covering: wanted) } else { nil }
            guard !Task.isCancelled else { return }
            if let loaded { show(loaded.document, covers: loaded.covers) } else { clear() }
        }
    }

    /// Parses the PDF and touches every page, which creates it here rather than on the main thread when the view lays
    /// the document out (measured on 392 pages: a swap takes 23–28 ms on the main thread without this, 7–8 ms with it).
    @concurrent static func loadDocument(_ url: URL, covering wanted: CoverPages = CoverPages()) async -> sending LoadedPDF? {
        signposts.withIntervalSignpost("pdf.load") {
            guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
            for index in 0..<document.pageCount { document.page(at: index)?.hideLinkBorders() }
            return LoadedPDF(document: document, covers: SyncPDFView.covers(wanted, of: document))
        }
    }

    @concurrent static func loadPage(_ pdf: Data, at index: Int, covering wanted: CoverPages) async -> sending LoadedPDF? {
        guard let document = PDFDocument(data: pdf), let page = document.page(at: 0) else { return nil }
        page.hideLinkBorders()
        let cover = SyncPDFView.covers(CoverPages(indices: wanted.indices.contains(index) ? [0] : [], scale: wanted.scale), of: document)
        return LoadedPDF(document: document, covers: cover[0].map { [index: $0] } ?? [:])
    }

    func print(title: String, file: URL?) {
        Task {
            let document = if let file { await Self.loadDocument(file)?.document } else { view.document }
            guard let operation = document?.printOperation(for: .shared, scalingMode: .pageScaleDownToFit, autoRotate: true),
                  let window = view.window ?? NSApp.mainWindow else { return NSSound.beep() }
            operation.jobTitle = title
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    func show(_ document: PDFDocument, covers: [Int: CGImage] = [:]) {
        let interval = signposts.beginInterval("pdf.show")
        defer { signposts.endInterval("pdf.show", interval) }
        shownVersion += 1
        isLoading = false
        loading?.cancel()
        revealing?.cancel()
        view.removeMark()
        view.clearSelection()
        let place = view.document == nil ? nil : view.shownPlace
        let autoScales = view.autoScales
        view.covering(covers) {
            signposts.withIntervalSignpost("setDocument") { view.document = document }
            view.minScaleFactor = Self.minScale
            view.maxScaleFactor = Self.maxScale
            view.autoScales = autoScales
            if let place { view.go(to: place) }
            signposts.withIntervalSignpost("layout") { view.layoutDocumentView() }
        }
        watchScrollView()
        restoreIfReady()
        pageChanged()
        signposts.withIntervalSignpost("find") { find.rerun() }
    }

    func show(_ page: PDFPage, at index: Int, covers: [Int: CGImage] = [:]) {
        let interval = signposts.beginInterval("live.page")
        defer { signposts.endInterval("live.page", interval) }
        guard let document = view.document, let old = document.page(ifAt: index) else { return }
        find.cancel()
        view.removeMark()
        view.covering(covers) {
            document.insert(page, at: index)
            document.removePage(at: index + 1)
        }
        if view.currentSelection?.pages.contains(old) == true { view.clearSelection() }
        pageChanged()
        find.rerun()
    }

    private func clear() {
        shownVersion += 1
        isLoading = false
        pendingReveal = nil
        revealing?.cancel()
        view.removeMark()
        find.reset()
        view.document = nil
        (page, pageCount) = (0, 0)
    }
}

nonisolated struct LoadedPDF {
    let document: PDFDocument
    let covers: [Int: CGImage]
}

nonisolated extension PDFDocument {
    func page(ifAt index: Int) -> PDFPage? { (0..<pageCount).contains(index) ? page(at: index) : nil }

    func number(of page: PDFPage) -> Int? {
        let index = index(for: page)
        return index == NSNotFound ? nil : index + 1
    }
}

nonisolated extension PDFPage {
    /// hyperref boxes links by default; the boxes are for print, so the view shows none.
    func hideLinkBorders() {
        for link in annotations where link.type == "Link" {
            let border = PDFBorder()
            border.lineWidth = 0
            link.border = border
        }
    }
}
