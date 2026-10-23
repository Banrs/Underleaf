import PDFKit
import SwiftUI
import UIKit

@Observable
final class PDFController: NSObject {
    /// PDFKit would go to 10,000%; the scale's label has room for three digits.
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 8

    @ObservationIgnored let view = SyncPDFView()
    var page = 0
    var pageCount = 0
    private(set) var scale: CGFloat = 1
    var zoom = Zoom.fitWidth
    var canZoomIn: Bool { scale < Self.maxScale }
    var canZoomOut: Bool { scale > Self.minScale }

    /// A project's last page and zoom, kept until the view has a size to show them in.
    @ObservationIgnored var restorePage: Int?
    @ObservationIgnored var restoreZoom: Zoom?
    @ObservationIgnored var onVisiblePages: (ClosedRange<Int>) -> Void = { _ in }
    @ObservationIgnored var toldPages: ClosedRange<Int>?
    @ObservationIgnored private(set) var shownVersion = 0
    @ObservationIgnored private var liveShown = false
    @ObservationIgnored private var liveMissed = false
    @ObservationIgnored var pendingReveal: (loc: ForwardLoc, source: SyncSource?)?
    @ObservationIgnored var revealing: Task<Void, Never>?

    override init() {
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
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

    @objc private func scaleChanged() {
        guard view.document != nil, view.hasShownArea else { return }
        scale = view.scaleFactor
        if view.autoScales, abs(scale - view.scaleFactorForSizeToFit) < 0.001 {
            zoom = .fitWidth
        } else if zoom != .fitPage {
            zoom = .scale(Double(scale))
        }
    }

    func setScale(_ scale: CGFloat) {
        zoom = .scale(Double(self.scale))
        view.autoScales = false
        view.scaleFactor = min(max(scale, Self.minScale), Self.maxScale)
    }

    func zoom(in zoomIn: Bool) { setScale(scale * (zoomIn ? 1.25 : 0.8)) }

    func fitPage() {
        guard let page = view.currentPage, view.hasShownArea else { return }
        view.autoScales = false
        let box = page.bounds(for: view.displayBox)
        view.scaleFactor = min(view.shownHeight / box.height, view.scaleFactorForSizeToFit)
        zoom = .fitPage
    }

    /// The file given (the build's during Live Preview), or the document showing.
    func print(title: String, file: URL?) {
        Task {
            let document = if let file { await Self.loadDocument(file) } else { view.document }
            guard let data = document?.dataRepresentation() else { return }
            let info = UIPrintInfo.printInfo()
            info.jobName = title
            info.outputType = .general
            let printing = UIPrintInteractionController.shared
            printing.printInfo = info
            printing.printingItem = data
            printing.present(animated: true)
        }
    }

    /// Into the document showing, so the place and zoom stay.
    func show(_ document: PDFDocument) {
        shownVersion += 1
        revealing?.cancel()
        (liveShown, liveMissed) = (false, false)
        let place = restorePage == nil ? view.shownPlace : nil
        view.removeMark()
        if let shown = view.document {
            view.clearSelection()
            shown.replacePages(with: document)
        } else {
            view.document = document
        }
        view.minScaleFactor = Self.minScale
        view.maxScaleFactor = Self.maxScale
        restoreIfReady()
        if let place { go(to: place) }
        pageChanged()
    }

    private func go(to place: (index: Int, point: CGPoint)) {
        guard let document = view.document, let page = document.page(ifAt: min(place.index, document.pageCount - 1)) else { return }
        view.go(to: PDFDestination(page: page, at: place.point))
    }

    func clear() {
        shownVersion += 1
        pendingReveal = nil
        revealing?.cancel()
        (liveShown, liveMissed) = (false, false)
        view.removeMark()
        view.document = nil
        (page, pageCount) = (0, 0)
    }

    // MARK: - Live Preview

    func showLive(_ read: LiveRead) {
        switch read {
        case .document(let live?):
            guard let shown = view.document, let changed = live.changed, !liveMissed else {
                liveMissed = false
                show(live.document)
                liveShown = true
                return
            }
            for index in changed where index < live.document.pageCount {
                guard let page = live.document.page(at: index)?.copy() as? PDFPage else { continue }
                if shown.replacePage(at: index, with: page) == nil { shown.insert(page, at: index) }
            }
            if shown.pageCount > live.document.pageCount, live.complete {
                while shown.pageCount > live.document.pageCount { shown.removePage(at: shown.pageCount - 1) }
            }
            liveShown = true
            pageChanged()
        case .document(nil):
            liveMissed = true
        case .page(let live?) where liveShown:
            _ = view.document?.replacePage(at: live.index, with: live.page)
        case .page:
            break
        }
    }

    func endLiveRun() { (liveMissed, liveShown) = (false, false) }

    // MARK: - SyncTeX

    /// The word selected in the find highlight's yellow, unless the find navigator is open with its own.
    func highlight(_ selection: PDFSelection?, or rect: CGRect, on page: PDFPage) {
        if let selection, !view.findInteraction.isFindNavigatorVisible {
            view.removeMark()
            selection.color = view.findYellow
            view.setCurrentSelection(selection, animate: !UIAccessibility.isReduceMotionEnabled)
        } else {
            view.flash(rect, on: page)
        }
    }

}

final class SyncPDFView: PDFView {
    var onInverse: (_ page: Int, _ point: CGPoint, _ click: PageClick?) -> Void = { _, _, _ in }
    var onResize: () -> Void = {}
    private var markView: UIView?
    /// PDFKit's colour round the pages, which its pane shows while dark paper's inversion would turn it.
    private(set) var surround = UIColor.clear

    /// Pages inverted by the pane, which lose their shadows as they would turn to glows.
    var darkPaper = false {
        didSet {
            guard darkPaper != oldValue else { return }
            backgroundColor = darkPaper ? .clear : surround
            pageShadowsEnabled = !darkPaper
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        surround = backgroundColor ?? .clear
        // A double tap goes to the source, as a double-click does on the Mac.
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        let size = bounds.size
        super.layoutSubviews()
        if size != laidOutSize {
            laidOutSize = size
            onResize()
        }
    }

    private var laidOutSize = CGSize.zero

    var shownHeight: CGFloat { bounds.height - safeAreaInsets.top - safeAreaInsets.bottom }
    var hasShownArea: Bool { bounds.width > 0 && shownHeight > 0 }

    var shownPlace: (index: Int, point: CGPoint)? {
        let top = CGPoint(x: bounds.minX, y: safeAreaInsets.top + 1)
        guard let page = page(for: top, nearest: true), let document else { return nil }
        return (index: document.index(for: page), point: convert(top, to: page))
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        let location = tap.location(in: self)
        guard let page = page(for: location, nearest: true), let number = document?.number(of: page) else { return }
        let point = convert(location, to: page)
        onInverse(number, SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox)), page.click(at: point))
    }

    /// Find's yellow, as it shows through dark paper's inversion.
    var findYellow: UIColor {
        let yellow = UIColor.systemYellow.resolvedColor(with: traitCollection)
        return darkPaper ? yellow.underDarkPaper : yellow
    }

    /// Fades after a moment; with Reduce Motion it fades too, as the HIG puts a fade in motion's place.
    func flash(_ rect: CGRect, on page: PDFPage) {
        removeMark()
        let topLeft = convert(CGPoint(x: rect.minX, y: rect.maxY), from: page)
        let bottomRight = convert(CGPoint(x: rect.maxX, y: rect.minY), from: page)
        let mark = UIView(frame: CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y))
        mark.backgroundColor = findYellow.withAlphaComponent(0.35)
        mark.layer.cornerRadius = 3
        mark.isUserInteractionEnabled = false
        addSubview(mark)
        markView = mark
        UIView.animate(withDuration: 0.6, delay: 2.2, options: []) { mark.alpha = 0 } completion: { _ in mark.removeFromSuperview() }
    }

    func removeMark() {
        markView?.removeFromSuperview()
        markView = nil
    }
}

struct PDFRepresentable: UIViewRepresentable {
    let project: ProjectModel
    let darkPaper: Bool

    func makeUIView(context: Context) -> SyncPDFView {
        let view = project.pdf.view
        view.onInverse = { [weak project] page, point, click in
            Task { await project?.inverseSync(page: page, x: point.x, y: point.y, click: click) }
        }
        return view
    }

    func updateUIView(_ view: SyncPDFView, context: Context) { view.darkPaper = darkPaper }
}

private extension UIColor {
    /// The colour that dark paper turns into this one: inverting and turning the hue 180° undoes itself, by SwiftUI's
    /// hue matrix (SVG's `hueRotate` at 180°).
    var underDarkPaper: UIColor {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        (r, g, b) = (1 - r, 1 - g, 1 - b)
        return UIColor(red: -0.574 * r + 1.43 * g + 0.144 * b, green: 0.426 * r + 0.43 * g + 0.144 * b,
                       blue: 0.426 * r + 1.43 * g - 0.856 * b, alpha: a)
    }
}
