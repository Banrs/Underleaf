import PDFKit
import SwiftUI
import Synchronization

/// What the toolbar, the find bar and the menus ask of the PDF view.
@Observable
final class PDFController {
    @ObservationIgnored weak var view: SyncPDFView? {
        // PDFView keeps a set scale as it resizes: Fit Height sets it again.
        didSet { view?.onResize = { [weak self] in if self?.fit == .height { self?.fitHeight() } } }
    }
    var page = 0
    var pageCount = 0
    /// Find in PDF: whether its bar shows, and what's typed in it (searched
    /// once typing pauses).
    var finding = false
    var findText = ""
    @ObservationIgnored let findField = FieldHandle()
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

    /// The page and its page-break margins, which scale with it, the height it shows in.
    private func heightScale(_ view: PDFView) -> CGFloat {
        guard let page = view.currentPage else { return view.scaleFactor }
        let margins = view.pageBreakMargins
        return view.shownHeight / (page.bounds(for: view.displayBox).height + margins.top + margins.bottom)
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

    /// Keeping place: a rebuilt PDF's matches, the current one kept where it still
    /// is, and the pages left where they are (a build follows every pause in typing).
    func find(_ value: String, keepingPlace: Bool = false) {
        guard let view, let document = view.document else { return }
        query = PDFFind.normalize(value)
        let all = query.isEmpty ? [] : document.findString(query, withOptions: .caseInsensitive)
        matches = Array(all.prefix(PDFFind.maxMatches))
        limited = all.count > matches.count
        if !keepingPlace || matchIndex >= matches.count { matchIndex = 0 }
        matches.forEach { $0.color = .findHighlightColor }
        view.highlightedSelections = matches.isEmpty ? nil : matches
        view.clearSelection()
        show(scrolling: !keepingPlace)
    }

    /// web/src/workspace.js `closePdfFind`: the bar goes, and its query and
    /// highlights with it. The keyboard goes back to the pages only from the bar:
    /// its close button can be clicked while the editor has the keyboard.
    func closeFind() {
        let fromBar = findField.hasFocus
        finding = false
        findText = ""
        find("")
        if fromBar, let view { view.window?.makeFirstResponder(view) }
    }

    /// A menu's request for pages not shown yet (a column that never showed, a
    /// document still loading) waits for them.
    @ObservationIgnored private var pending: [() -> Void] = []

    func whenShown(_ action: @escaping () -> Void) {
        if view?.document != nil { action() } else { pending.append(action) }
    }

    func documentShown() {
        // The query last searched: text still being typed gets a search of its own.
        if finding { find(query, keepingPlace: true) }
        let run = pending
        pending = []
        run.forEach { $0() }
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        show()
    }

    private func show(scrolling: Bool = true) {
        guard let view, matches.indices.contains(matchIndex) else { return }
        view.setCurrentSelection(matches[matchIndex], animate: scrolling)
        if scrolling { view.scrollSelectionToVisible(nil) }
    }

    /// A SyncTeX point on a line of text: SyncTeX resolves only points on a glyph
    /// box, and the page centre is usually whitespace.
    func sourcePoint() -> (Int, CGPoint)? {
        guard let view, let document = view.document else { return nil }
        // "The text you are looking at": the first line at or below a fifth of the way down.
        let probe = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - view.safeAreaInsets.top - view.shownHeight * 0.2)
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
            point.y -= 6
        }
        return (document.index(for: page) + 1, SyncTeXGeometry.synctexPoint(point, pageBounds: bounds))
    }
}

/// PDFView where Command-click jumps to the source (inverse search), as in the
/// Mac's TeX apps; a double-click stays PDFKit's, selecting a word.
final class SyncPDFView: PDFView {
    var onInverse: (Int, CGPoint) -> Void = { _, _ in }
    var onResize: () -> Void = {}

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI sets the frame again, unchanged, whenever PDFKit's own scrolling
        // lays out the pane (each step): only a new size counts.
        guard newSize != frame.size else { return }
        // PDFKit keeps the point at the view's top, which runs on under the
        // toolbar: at the start of the document, a new scale slid the first page
        // under it. There it stays at the start.
        let atStart = atDocumentStart
        super.setFrameSize(newSize)
        onResize()
        if atStart, let page = document?.page(at: 0) {
            go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: displayBox).maxY)))
        }
    }

    /// The first page's top no higher than the top of what shows, give or take its
    /// page-break margin (which scales with the page, and PDFKit's own `go(to:)`
    /// leaves). In view points.
    private var atDocumentStart: Bool {
        guard let page = document?.page(at: 0) else { return false }
        let top = convert(CGPoint(x: 0, y: page.bounds(for: displayBox).maxY), from: page).y
        return top <= bounds.maxY - safeAreaInsets.top + pageBreakMargins.top * scaleFactor
    }

    /// Read on PDFKit's tile queue.
    private let pagesDark = Atomic(false)

    /// As the web draws it (`.pdf-dark`): lightness inverted, hues kept. Drawn
    /// into PDFKit's tiles, so sharp at any scale, and only the pages.
    var darkPaper = false {
        didSet {
            guard darkPaper != oldValue else { return }
            pagesDark.store(darkPaper, ordering: .relaxed)
            pageShadowsEnabled = !darkPaper
            matchScroller()
            // PDFKit keeps the tiles it drew until the box they show changes.
            let box = displayBox
            displayBox = box == .mediaBox ? .cropBox : .mediaBox
            displayBox = box
        }
    }

    /// The knob runs over the pages: light on dark paper, dark on white. Again
    /// for the first document, which brings the scroll view (an override of
    /// `document` would be called on PDFKit's form-filling queue).
    func matchScroller() {
        guard let scroll = documentView?.enclosingScrollView else { return }
        scroll.scrollerKnobStyle = darkPaper ? .light : .dark
        scroll.verticalScrollElasticity = .allowed
    }

    /// PDFView's own (the page on white, in the crop box it shows), then for dark
    /// paper the page inverted and given back its own hue and saturation. PDFKit
    /// calls this for each tile, on its own queue.
    override nonisolated func draw(_ page: PDFPage, to context: CGContext) {
        let box = page.bounds(for: .cropBox)
        context.setFillColor(.white)
        context.fill(box)
        page.draw(with: .cropBox, to: context)
        guard pagesDark.load(ordering: .relaxed) else { return }
        context.setBlendMode(.difference)
        context.fill(box)
        context.setBlendMode(.color)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setBlendMode(.normal)
        context.fill(box)
        page.draw(with: .cropBox, to: context)
        context.endTransparencyLayer()
    }

    override func mouseDown(with event: NSEvent) {
        // Command alone of the keys held, Caps Lock aside.
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, document != nil else {
            super.mouseDown(with: event)
            return
        }
        goToSource(at: convert(event.locationInWindow, from: nil))
    }

    /// Go to Source Position for the clicked point, above PDFKit's own items.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
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
        guard let document, let page = page(for: location, nearest: true) else { return }
        let point = convert(location, to: page)
        onInverse(document.index(for: page) + 1, SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox)))
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
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.onInverse = { [project] page, point in
            Task { await project.inverseSync(page: page, x: point.x, y: point.y) }
        }
        controller.view = view
        let center = NotificationCenter.default
        // Each read once as it starts watching too: the first fitted scale is set before.
        context.coordinator.watches = [(Notification.Name.PDFViewPageChanged, controller.pageChanged),
                                       (.PDFViewScaleChanged, controller.scaleChanged)].map { name, changed in
            Task {
                let changes = center.notifications(named: name, object: view)
                changed()
                for await _ in changes { changed() }
            }
        }
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
        view.matchScroller()
        if autoScales { view.autoScales = true } else { view.scaleFactor = scale }
        // A reopened project's first PDF opens at the page it was left at.
        let restore = project.restorePDFPage
        project.restorePDFPage = nil
        if let place, let page = document.page(at: min(place.index, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: place.point))
        } else if let restore {
            controller.go(toPage: restore)
        }
        controller.pageCount = document.pageCount
        controller.pageChanged()
        controller.scaleChanged()
        controller.documentShown()
    }

    /// Scroll to a forward-search result and flash it.
    private func flash(_ loc: ForwardLoc, in view: SyncPDFView) {
        guard let page = view.document?.page(at: Int(loc.page) - 1) else { return }
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        let mark = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        mark.color = NSColor.systemYellow.withAlphaComponent(0.4)
        page.addAnnotation(mark)
        // A third of the way down the pages: a destination goes to the top of
        // what shows, below the toolbar, where a rect went under it.
        view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY + view.shownHeight / 3 / view.scaleFactor)))
        Task {
            // web/styles.css .sync-flash
            try? await Task.sleep(for: .seconds(2.2))
            page.removeAnnotation(mark)
        }
    }
}

private extension PDFView {
    /// The height the pages show in: the view runs on under the toolbar and the
    /// find bar, which the system's scroll edge effect covers.
    var shownHeight: CGFloat { bounds.height - safeAreaInsets.top }
}
