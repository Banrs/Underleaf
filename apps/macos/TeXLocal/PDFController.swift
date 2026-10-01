import PDFKit
import SwiftUI
import Synchronization

/// What the toolbar, the find bar and the menus ask of the PDF view.
@Observable
final class PDFController {
    @ObservationIgnored weak var view: SyncPDFView? {
        didSet {
            // PDFView keeps a set scale as it resizes: Fit Height sets it again.
            view?.onResize = { [weak self] in if self?.fit == .height { self?.fitHeight() } }
            // The scale is PDFKit's scroll view's magnification, step by step through a pinch
            // (PDFViewScaleChanged comes only as it ends). The view has it from the start.
            magnification = view?.subviews.lazy.compactMap { $0 as? NSScrollView }.first?
                .observe(\.magnification, options: .initial) { [weak self] _, _ in MainActor.assumeIsolated { self?.scaleChanged() } }
        }
    }
    @ObservationIgnored private var magnification: NSKeyValueObservation?
    var page = 0
    /// The page a reopened project's first PDF opens at.
    @ObservationIgnored var restorePage: Int?
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
        // Any other scale than the fitted one (a pinch, a zoom command) ends fitting. A pinch keeps
        // autoScales on until it ends: one back at the width fits again, one ending off it doesn't.
        if view.autoScales, abs(view.scaleFactor - view.scaleFactorForSizeToFit) < 0.001 {
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
    }

    /// Sets the fit after the scale, since the scale's change ends a fit.
    func fitHeight() {
        guard let view, view.currentPage != nil else { return }
        view.autoScales = false
        view.scaleFactor = heightScale(view)
        fit = .height
    }

    /// PDFKit's own search, off the main thread (a first query extracts the text:
    /// 445 ms in 392 pages), and what it has found.
    @ObservationIgnored private var search: (document: PDFDocument, query: String, keepingPlace: Bool, found: [PDFSelection])?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        search?.document.cancelFindString()
    }

    /// Keeping place: a rebuilt PDF's matches, the current one kept where it still
    /// is, and the pages left where they are (a build follows every pause in typing).
    func find(_ value: String, keepingPlace: Bool = false) {
        guard let view, let document = view.document else { return }
        // Cancelling posts its end at once, unheard as `search` is cleared first.
        let superseded = search?.document
        search = nil
        superseded?.cancelFindString()
        let query = PDFFind.normalize(value)
        guard !query.isEmpty else { return found(query, [], keepingPlace: keepingPlace) }
        if observers.isEmpty { observeFinds() }
        search = (document, query, keepingPlace, [])
        document.beginFindString(query, withOptions: .caseInsensitive)
    }

    /// PDFKit posts these on the main queue; taken there as posted, so in order.
    private func observeFinds() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: nil, queue: nil) { [weak self] note in
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated { self?.matched(note) }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: nil, queue: nil) { [weak self] note in
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated { self?.ended(note) }
            },
        ]
    }

    private func matched(_ note: Notification) {
        guard note.object as? PDFDocument === search?.document,
              let match = note.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else { return }
        search?.found.append(match)
        // One more than is kept says there are more.
        if search?.found.count ?? 0 > PDFFind.maxMatches { search?.document.cancelFindString() }
    }

    private func ended(_ note: Notification) {
        guard let search, note.object as? PDFDocument === search.document else { return }
        self.search = nil
        found(search.query, search.found, keepingPlace: search.keepingPlace)
    }

    /// The count stays the last query's until its search ends.
    private func found(_ query: String, _ all: [PDFSelection], keepingPlace: Bool) {
        self.query = query
        matches = Array(all.prefix(PDFFind.maxMatches))
        limited = all.count > matches.count
        if !keepingPlace || matchIndex >= matches.count { matchIndex = 0 }
        matches.forEach { $0.color = .findHighlightColor }
        view?.highlightedSelections = matches.isEmpty ? nil : matches
        view?.clearSelection()
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

/// PDFView where a double-click goes to the source (inverse search), as in
/// Overleaf, after PDFKit's own word selection marks the word it sends.
final class SyncPDFView: PDFView {
    var onInverse: (_ page: Int, _ point: CGPoint, _ word: (String, offset: Int)?) -> Void = { _, _, _ in }
    var onResize: () -> Void = {}

    /// SwiftUI sets the frame again, unchanged, as the window lays out (the toolbar's scale
    /// changing): PDFView fits the width again on each, which would undo a pinch under way
    /// (auto-scaling stays on until it ends).
    override var frame: NSRect {
        get { super.frame }
        set { if newValue != super.frame { super.frame = newValue } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI sets the frame again, unchanged, on each scroll step: only a new size counts.
        guard newSize != frame.size else { return super.setFrameSize(newSize) }
        // PDFKit holds the view's top, which runs on under the toolbar, in place; at the
        // document's start, the first page's top stays in view instead.
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

    /// The top of what shows, under the toolbar and the find bar, where `go(to:)` puts a destination
    /// (in a page break, at the page's edge: a margin off, once); `currentDestination` is behind them.
    var shownDestination: PDFDestination? {
        let top = CGPoint(x: bounds.minX, y: bounds.maxY - safeAreaInsets.top)
        return page(for: top, nearest: true).map { PDFDestination(page: $0, at: convert(top, to: $0)) }
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
    /// `document` would be called on PDFKit's form-filling queue). VoiceOver
    /// reads the scroll view's label, not the PDF view's.
    func matchScroller() {
        documentView?.enclosingScrollView?.scrollerKnobStyle = darkPaper ? .light : .dark
        documentView?.enclosingScrollView?.setAccessibilityLabel("PDF")
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
        super.mouseDown(with: event)
        if event.clickCount == 2 { goToSource(at: convert(event.locationInWindow, from: nil)) }
    }

    /// Go to Source Position for the clicked point, above PDFKit's Copy when there's a selection
    /// (a right-click on a word selects it).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        // Copy a selection: the app fixes the page layout, scrolling turns the pages, and the
        // zooms are the toolbar's and View's.
        menu?.keep([#selector(copy(_:))])
        guard let menu, document != nil else { return menu }
        let item = NSMenuItem(title: MenuCommand.syncInverse.title, action: #selector(goToSource(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = convert(event.locationInWindow, from: nil)
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(item, at: 0)
        return menu
    }

    @objc private func goToSource(_ item: NSMenuItem) {
        if let location = item.representedObject as? CGPoint { goToSource(at: location) }
    }

    private func goToSource(at location: CGPoint) {
        guard let document, let page = page(for: location, nearest: true) else { return }
        let point = convert(location, to: page)
        onInverse(document.index(for: page) + 1, SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox)), page.word(at: point))
    }
}

struct PDFRepresentable: NSViewRepresentable {
    let project: ProjectModel
    private var controller: PDFController { project.pdf }
    let darkPaper: Bool
    let document: PDFDocument?
    /// Whether `document` is the current build's.
    let current: Bool

    final class Coordinator {
        var highlightToken = 0
        /// Following the view's page, until the view goes.
        var pages: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.onInverse = { [project] page, point, word in
            Task { await project.inverseSync(page: page, x: point.x, y: point.y, word: word) }
        }
        controller.view = view
        // Read once as it starts watching too.
        context.coordinator.pages = Task { [controller] in
            let changes = NotificationCenter.default.notifications(named: .PDFViewPageChanged, object: view)
            controller.pageChanged()
            for await _ in changes { controller.pageChanged() }
        }
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        view.darkPaper = darkPaper
        if let document, view.document !== document { show(document, in: view) }
        // Only on the current build's pages: the jump would be lost to the swap.
        if current, let highlight = project.highlight, highlight.token != context.coordinator.highlightToken {
            context.coordinator.highlightToken = highlight.token
            flash(highlight.loc, word: highlight.word, in: view)
        }
    }

    static func dismantleNSView(_ view: SyncPDFView, coordinator: Coordinator) {
        coordinator.pages?.cancel()
    }

    /// A rebuilt PDF at the same place and zoom.
    private func show(_ document: PDFDocument, in view: SyncPDFView) {
        // Read before the swap: a page keeps its document only weakly.
        let place = view.shownDestination.flatMap { destination in
            destination.page.flatMap { view.document?.index(for: $0) }.map { (index: $0, point: destination.point) }
        }
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        view.document = document
        view.matchScroller()
        if autoScales { view.autoScales = true } else { view.scaleFactor = scale }
        let restore = controller.restorePage
        controller.restorePage = nil
        if let place, let page = document.page(at: min(place.index, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: place.point))
        } else if let restore {
            controller.go(toPage: restore)
        }
        controller.pageChanged()
        controller.documentShown()
    }

    /// Scroll to a forward-search result and flash it: `word`, the word at the
    /// caret, where it is nearest SyncTeX's box, else the whole box.
    private func flash(_ loc: ForwardLoc, word: String?, in view: SyncPDFView) {
        guard let page = view.document?.page(at: Int(loc.page) - 1) else { return }
        let box = SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        let rect = word.flatMap { page.bounds(of: $0, near: box) } ?? box
        // A filled square: PDFKit multiplies a highlight, which dark paper hides.
        let mark = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        mark.color = NSColor.systemYellow.withAlphaComponent(0.4)
        mark.interiorColor = mark.color
        mark.border = nil
        page.addAnnotation(mark)
        // A third of the way down what shows: a destination lands below the toolbar, a rect under it.
        view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY + view.shownHeight / 3 / view.scaleFactor)))
        Task {
            // web/styles.css .sync-flash
            try? await Task.sleep(for: .seconds(2.2))
            page.removeAnnotation(mark)
        }
    }
}

extension PDFPage {
    /// The word at `point`, and where in it the point falls (in UTF-16 units), as
    /// PDF text may run together words TeX sets close. By each letter's selection:
    /// `characterIndex(at:)` is letters out in pdfTeX's T1 fonts (27.2).
    func word(at point: CGPoint) -> (String, offset: Int)? {
        guard let word = selectionForWord(at: point), let text = word.string else { return nil }
        let range = word.range(at: 0, on: self)
        let offset = (0..<range.length).first { i in
            selection(for: NSRange(location: range.location + i, length: 1)).map { $0.bounds(for: self).maxX > point.x } ?? false
        }
        return (text, offset ?? 0)
    }

    /// The bounds of `word` nearest `box` on this page: on its line, or one either
    /// side (SyncTeX gives the first of a source line's boxes). PDF text runs
    /// together words TeX sets close, so on a line a whole word comes first, then
    /// one run into others.
    func bounds(of word: String, near box: CGRect) -> CGRect? {
        guard let text = string else { return nil }
        let found = text.ranges(of: word).compactMap { range -> (CGRect, Int)? in
            let joined = text[..<range.lowerBound].last?.isLetter == true || text[range.upperBound...].first?.isLetter == true
            return selection(for: NSRange(range, in: text)).map { ($0.bounds(for: self), joined ? 1 : 0) }
        }
        // Above or below the box, whether run into others, then beside the box.
        func rank(_ hit: (rect: CGRect, joined: Int)) -> (CGFloat, Int, CGFloat) {
            (max(0, box.minY - hit.rect.maxY, hit.rect.minY - box.maxY), hit.joined, max(0, box.minX - hit.rect.maxX, hit.rect.minX - box.maxX))
        }
        return found.filter { rank($0).0 < box.height }.min { rank($0) < rank($1) }?.0
    }
}

private extension PDFView {
    /// The height the pages show in: the view runs on under the toolbar and the
    /// find bar, which the system's scroll edge effect covers.
    var shownHeight: CGFloat { bounds.height - safeAreaInsets.top }
}
