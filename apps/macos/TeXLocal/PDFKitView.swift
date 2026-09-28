import CoreImage.CIFilterBuiltins
import PDFKit
import SwiftUI

/// Named PDF view values.
nonisolated enum PDFMetrics {
    /// "The text you are looking at": the first line at or below this fraction of the view.
    static let sourcePointFraction: CGFloat = 0.2
    /// How far down the page each look for that line steps.
    static let sourcePointStep: CGFloat = 6
    /// A neutral near-white that dark paper's inversion turns into dark mode's
    /// under-page grey: Core Image inverts in linear light.
    static let darkPaperBackground = NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1)
    /// Matches .sync-flash in web/styles.css.
    static let flashDuration: Duration = .seconds(2.2)
    static let flashAlpha: CGFloat = 0.4
    /// PDFKit's `PDFAnnotation.type` is the subtype without its slash.
    static let linkType = String(PDFAnnotationSubtype.link.rawValue.dropFirst())
}

/// What the pane's controls and the menus ask of the PDF view.
@Observable
final class PDFController {
    @ObservationIgnored weak var view: SyncPDFView?
    var page = 0
    var pageCount = 0
    /// The query the matches are for, normalised.
    private(set) var query = ""
    var matches: [PDFSelection] = []
    var matchIndex = 0
    /// More matches exist than are kept.
    var limited = false
    /// Whether fitting or set.
    private(set) var scale: CGFloat = 1
    var zoomLabel: String { Double(scale).formatted(.percent.precision(.fractionLength(0))) }
    /// PDFKit's own limits.
    private(set) var canZoomIn = true
    private(set) var canZoomOut = true
    /// How the page is fitted to the view, or nil at a set scale.
    enum Fit { case width, height }
    private(set) var fit: Fit? = .width

    func pageChanged() {
        guard let view, let document = view.document, let page = view.currentPage else { return }
        self.page = document.index(for: page) + 1
        pageCount = document.pageCount
    }

    func scaleChanged() {
        guard let view else { return }
        scale = view.scaleFactor
        canZoomIn = view.canZoomIn
        canZoomOut = view.canZoomOut
        // Any other change of scale (a pinch, a zoom command) ends fitting.
        if view.autoScales {
            fit = .width
        } else if fit == .width || (fit == .height && abs(view.scaleFactor - heightScale(view)) > 0.001) {
            fit = nil
        }
    }

    private func heightScale(_ view: PDFView) -> CGFloat {
        guard let page = view.currentPage else { return view.scaleFactor }
        return view.bounds.height / page.bounds(for: view.displayBox).height
    }

    func setScale(_ scale: CGFloat) {
        guard let view else { return }
        fit = nil
        view.autoScales = false
        view.scaleFactor = scale
    }

    func zoom(in zoomIn: Bool) {
        guard let view else { return }
        fit = nil
        view.autoScales = false
        if zoomIn { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }

    /// One-based, as the page shows it; clamped to the document.
    func go(toPage number: Int) {
        guard let view, let document = view.document, document.pageCount > 0,
              let page = document.page(at: min(max(number, 1), document.pageCount) - 1) else { return }
        view.go(to: page)
    }

    /// In a continuous single-page layout, auto-scaling fits the page width.
    func fitWidth() {
        fit = .width
        view?.autoScales = true
        scaleChanged()
    }

    func fitHeight() {
        guard let view, view.currentPage != nil else { return }
        fit = .height
        view.autoScales = false
        view.scaleFactor = heightScale(view)
    }

    func find(_ value: String) {
        guard let view, let document = view.document else { return }
        query = PDFFind.normalize(value)
        let all = query.isEmpty ? [] : document.findString(query, withOptions: .caseInsensitive)
        matches = Array(all.prefix(PDFFind.maxMatches))
        limited = all.count > matches.count
        matchIndex = 0
        matches.forEach { $0.color = .findHighlightColor }
        view.highlightedSelections = matches.isEmpty ? nil : matches
        view.clearSelection()
        show()
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        show()
    }

    private func show() {
        guard let view, matches.indices.contains(matchIndex) else { return }
        view.setCurrentSelection(matches[matchIndex], animate: true)
        view.scrollSelectionToVisible(nil)
    }

    /// A SyncTeX point on a line of text: SyncTeX resolves only points on a glyph
    /// box, and the page centre is usually whitespace.
    func sourcePoint() -> (Int, CGPoint)? {
        guard let view, let document = view.document else { return nil }
        let probe = CGPoint(x: view.bounds.midX,
                            y: view.bounds.maxY - view.bounds.height * PDFMetrics.sourcePointFraction)
        guard let page = view.page(for: probe, nearest: true) else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        var point = view.convert(probe, to: page)
        while point.y > bounds.minY {
            if let line = page.selectionForLine(at: point), let text = line.string,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let box = line.bounds(for: page)
                point = CGPoint(x: box.midX, y: box.minY)
                break
            }
            point.y -= PDFMetrics.sourcePointStep
        }
        return (document.index(for: page) + 1, SyncTeXGeometry.synctexPoint(point, pageBounds: bounds))
    }
}

/// PDFView with a double-click that jumps to the source (inverse search).
final class SyncPDFView: PDFView {
    var onInverse: (Int, CGPoint) -> Void = { _, _ in }

    /// As the web draws it (`.pdf-dark`): inverted, then turned half way round the
    /// colour wheel so figures keep their hues. The view keeps the light appearance,
    /// whose background and scrollers the inversion turns dark.
    var darkPaper = false {
        didSet {
            guard darkPaper != oldValue else { return }
            wantsLayer = true
            layerUsesCoreImageFilters = true
            appearance = darkPaper ? NSAppearance(named: .aqua) : nil
            // The tinted under-page colour would invert to olive.
            backgroundColor = darkPaper ? PDFMetrics.darkPaperBackground : .underPageBackgroundColor
            pageShadowsEnabled = !darkPaper
            let hue = CIFilter.hueAdjust()
            hue.angle = .pi
            contentFilters = darkPaper ? [CIFilter.colorInvert(), hue] : []
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let document else {
            super.mouseDown(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: true) else { return }
        let point = convert(location, to: page)
        let synctex = SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox))
        onInverse(document.index(for: page) + 1, synctex)
    }
}

struct PDFRepresentable: NSViewRepresentable {
    let project: ProjectModel
    let controller: PDFController
    let darkPaper: Bool
    let document: PDFDocument?
    /// Whether `document` is the current build's.
    let current: Bool

    final class Coordinator {
        var highlightToken = 0
        /// Following the view's page and scale, until the view goes.
        var watches: [Task<Void, Never>] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // An even margin round every page, lined up with the bars' controls.
        let inset = BarMetrics.inset
        view.pageBreakMargins = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.onInverse = { [project] page, point in
            Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
        }
        controller.view = view
        let center = NotificationCenter.default
        // Each read once as it starts watching too: the first fitted scale is set before.
        context.coordinator.watches = [
            Task { [controller] in
                let changes = center.notifications(named: .PDFViewPageChanged, object: view)
                controller.pageChanged()
                for await _ in changes { controller.pageChanged() }
            },
            Task { [controller] in
                let changes = center.notifications(named: .PDFViewScaleChanged, object: view)
                controller.scaleChanged()
                for await _ in changes { controller.scaleChanged() }
            },
        ]
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        view.darkPaper = darkPaper
        if let document, view.document !== document { show(document, in: view) }
        // Only on the current build's pages: the jump would be lost to the swap.
        if current, let highlight = project.highlight, highlight.token != context.coordinator.highlightToken {
            context.coordinator.highlightToken = highlight.token
            flash(highlight.loc, in: view)
        }
    }

    static func dismantleNSView(_ view: SyncPDFView, coordinator: Coordinator) {
        coordinator.watches.forEach { $0.cancel() }
    }

    /// A rebuilt PDF at the same place and zoom, by PDFKit's own destination.
    private func show(_ document: PDFDocument, in view: SyncPDFView) {
        // Read before the swap: a page keeps its document only weakly.
        let place = view.currentDestination.flatMap { destination in
            destination.page.flatMap { view.document?.index(for: $0) }.map { (index: $0, point: destination.point) }
        }
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        view.document = document
        if autoScales { view.autoScales = true } else { view.scaleFactor = scale }
        // A reopened project's first PDF opens at the page it was left at.
        let restore = project.restorePDFPage.map { min(max($0, 1), document.pageCount) - 1 }
        project.restorePDFPage = nil
        if let place, let page = document.page(at: min(place.index, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: place.point))
        } else if let restore, let page = document.page(at: restore) {
            view.go(to: page)
        }
        controller.pageCount = document.pageCount
        controller.pageChanged()
        controller.scaleChanged()
    }

    /// Scroll to a forward-search result and flash it.
    private func flash(_ loc: ForwardLoc, in view: SyncPDFView) {
        guard let page = view.document?.page(at: Int(loc.page) - 1) else { return }
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        let mark = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        mark.color = NSColor.systemYellow.withAlphaComponent(PDFMetrics.flashAlpha)
        page.addAnnotation(mark)
        view.go(to: rect.insetBy(dx: 0, dy: -view.bounds.height / 3), on: page)
        Task {
            try? await Task.sleep(for: PDFMetrics.flashDuration)
            page.removeAnnotation(mark)
        }
    }
}
