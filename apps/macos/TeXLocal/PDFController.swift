import PDFKit
import SwiftUI
import Synchronization

/// PDF view state and actions for the toolbar, find bar and menus.
@Observable
final class PDFController: NSObject, @MainActor PDFDocumentDelegate {
    /// Read whole: the next build rewrites the file in place.
    @concurrent nonisolated static func loadDocument(_ url: URL) async -> sending PDFDocument? {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        // Keep hyperlinks active without hyperref's visible annotation boxes.
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
            }
        }
        return document
    }

    @ObservationIgnored let view = SyncPDFView()
    @ObservationIgnored private var magnification: NSKeyValueObservation?
    var page = 0
    /// The page a reopened project's first PDF opens at.
    @ObservationIgnored var restorePage: Int?
    /// A forward search's spot, until the view has a size to show it in.
    @ObservationIgnored private var pendingReveal: (loc: ForwardLoc, word: SyncTeXWord?)?
    var pageCount = 0
    /// The field text can be ahead of the completed PDFKit query.
    var finding = false
    var findText = ""
    @ObservationIgnored let findField = FieldHandle()
    /// The query the matches are for, normalised.
    private(set) var query = ""
    var matches: [PDFSelection] = []
    var matchIndex = 0
    var limited = false
    private(set) var scale: CGFloat = 1
    var zoomLabel: String { Self.label(scale) }
    /// The longest label of the scales PDFKit allows.
    var widestZoomLabel: String {
        [view.minScaleFactor, view.maxScaleFactor].map(Self.label).max { $0.count < $1.count } ?? zoomLabel
    }
    private(set) var canZoomIn = true
    private(set) var canZoomOut = true
    /// 999%, so the toolbar's scale reserves a three-digit label's width (`widestZoomLabel`):
    /// PDFKit would go to 10,000%, and Pages' zoom stops at 400%.
    private static let maxScale: CGFloat = 9.99
    private static func label(_ scale: CGFloat) -> String {
        Double(scale).formatted(.percent.precision(.fractionLength(0)))
    }
    /// How the page is fitted to the view, or nil at a set scale.
    enum Fit { case width, page }
    private(set) var fit: Fit? = .width

    override init() {
        super.init()
        // Preview's canvas color; the PDF's paper keeps its own colors.
        view.backgroundColor = .controlBackgroundColor
        // From before the first PDF, so the toolbar reserves its scale's width from the start.
        // Before fitting, which a set limit turns off.
        view.maxScaleFactor = Self.maxScale
        view.autoScales = true
        view.onResize = { [weak self] in
            guard let self else { return }
            if fit == .page { fitPage() }
            restorePageIfReady()
            if let pending = pendingReveal { reveal(pending.loc, word: pending.word) }
        }
        // PDFViewScaleChanged comes only as a pinch ends; magnification follows each step.
        magnification = view.subviews.lazy.compactMap { $0 as? NSScrollView }.first?
            .observe(\.magnification, options: .initial) { [weak self] _, _ in MainActor.assumeIsolated { self?.scaleChanged() } }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
    }

    @objc func pageChanged() {
        guard let document = view.document, let page = view.currentPage else { return }
        self.page = document.index(for: page) + 1
        pageCount = document.pageCount
    }

    func scaleChanged() {
        guard view.document != nil, view.bounds.width > 0, view.shownHeight > 0 else { return }
        scale = view.scaleFactor
        canZoomIn = view.canZoomIn
        canZoomOut = view.canZoomOut
        // Any other scale than the fitted one (a pinch, a zoom command) ends fitting. A pinch keeps
        // autoScales on until it ends: one back at the width fits again, one ending off it doesn't.
        if view.autoScales, abs(view.scaleFactor - view.scaleFactorForSizeToFit) < 0.001 {
            fit = .width
        } else if fit == .width || (fit == .page && abs(view.scaleFactor - pageScale(view)) > 0.001) {
            fit = nil
        }
    }

    /// The whole page, as Pages' and Keynote's Fit Page: the smaller of the scales that fit
    /// its width (PDFKit's own) and its height, with its page-break margins, which scale
    /// with it, in the height it shows in.
    private func pageScale(_ view: PDFView) -> CGFloat {
        guard let page = view.currentPage else { return view.scaleFactor }
        let margins = view.pageBreakMargins
        let height = view.shownHeight / (page.bounds(for: view.displayBox).height + margins.top + margins.bottom)
        return min(height, view.scaleFactorForSizeToFit)
    }

    func setScale(_ scale: CGFloat) {
        fit = nil
        view.autoScales = false
        view.scaleFactor = scale
    }

    func zoom(in zoomIn: Bool) {
        fit = nil
        view.autoScales = false
        if zoomIn { view.zoomIn(nil) } else { view.zoomOut(nil) }
    }

    /// One-based, as the page shows it; clamped to the document.
    func go(toPage number: Int) {
        guard let document = view.document, document.pageCount > 0,
              let page = document.page(at: min(max(number, 1), document.pageCount) - 1) else { return }
        view.go(to: page)
    }

    /// In a continuous single-page layout, auto-scaling fits the page width.
    func fitWidth() {
        fit = .width
        view.autoScales = true
    }

    /// Sets the fit after the scale, since the scale's change ends a fit.
    func fitPage() {
        guard view.currentPage != nil, view.shownHeight > 0 else { return }
        if view.autoScales { view.autoScales = false }
        let scale = pageScale(view)
        if view.scaleFactor != scale { view.scaleFactor = scale }
        fit = .page
    }

    func setDarkPaper(_ dark: Bool) {
        guard dark != view.darkPaper else { return }
        let fit = fit, scale = view.scaleFactor, place = view.shownDestination
        view.darkPaper = dark
        guard view.document != nil else { return }
        // PDFKit caches page tiles; changing the display box refreshes them.
        let box = view.displayBox
        view.displayBox = box == .mediaBox ? .cropBox : .mediaBox
        view.displayBox = box
        switch fit {
        case .width: fitWidth()
        case .page: fitPage()
        case nil: setScale(scale)
        }
        if let place { view.go(to: place) }
    }

    /// PDFKit searches off the main thread; the first query extracts page text.
    @ObservationIgnored private var search: (document: PDFDocument, query: String, keepingPlace: Bool, found: [PDFSelection])?

    isolated deinit {
        search?.document.delegate = nil
        search?.document.cancelFindString()
    }

    /// Once typing pauses: the field's text, unless it is what's being searched or was found.
    func findTyped() {
        if PDFFind.normalize(findText) != search?.query ?? query { find(findText) }
    }

    /// During rebuild, keep the selected match and page where possible.
    func find(_ value: String, keepingPlace: Bool = false) {
        guard let document = view.document else { return }
        let query = PDFFind.normalize(value)
        // A rebuild can start this query before the field's typing delay ends.
        guard search?.document !== document || search?.query != query else { return }
        // Cancelling posts its end at once, unheard as `search` is cleared first.
        let superseded = search?.document
        search = nil
        superseded?.cancelFindString()
        guard !query.isEmpty else { return found(query, [], keepingPlace: keepingPlace) }
        document.delegate = self
        search = (document, query, keepingPlace, [])
        document.beginFindString(query, withOptions: .caseInsensitive)
    }

    // PDFKit delivers document-find delegate callbacks on the main thread.
    func documentDidFindMatch(_ note: Notification) {
        guard note.object as? PDFDocument === search?.document,
              let match = note.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else { return }
        search?.found.append(match)
        if search?.found.count ?? 0 > PDFFind.maxMatches { search?.document.cancelFindString() }
    }

    func documentDidEndDocumentFind(_ note: Notification) {
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
        view.highlightedSelections = matches.isEmpty ? nil : matches
        if matches.isEmpty { view.clearSelection() }
        show(scrolling: !keepingPlace)
    }

    /// Clear highlights; return focus to the PDF only when the bar had it.
    func closeFind() {
        let fromBar = findField.hasFocus
        finding = false
        findText = ""
        find("")
        if fromBar { view.window?.makeFirstResponder(view) }
    }

    /// A rebuilt PDF at the same place and zoom.
    func show(_ document: PDFDocument) {
        // Read before the swap: a page keeps its document only weakly.
        let place = restorePage == nil ? view.shownDestination.flatMap { destination in
            destination.page.flatMap { view.document?.index(for: $0) }.map { (index: $0, point: destination.point) }
        } : nil
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        view.document = document
        // A document resets the limit (27.2).
        view.maxScaleFactor = Self.maxScale
        view.documentView?.enclosingScrollView?.setAccessibilityLabel("PDF")
        view.matchScroller()
        if autoScales { view.autoScales = true } else { view.scaleFactor = scale }
        if let place, let page = document.page(at: min(place.index, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: place.point))
        } else {
            restorePageIfReady()
        }
        pageChanged()
        // A rebuild uses the field's current text, which may be ahead of the last result.
        if finding { find(findText, keepingPlace: true) }
    }

    private func restorePageIfReady() {
        // A destination cannot land until the PDF view has a visible size.
        guard let number = restorePage, view.document != nil, view.bounds.width > 0, view.shownHeight > 0 else { return }
        restorePage = nil
        go(toPage: number)
    }

    /// A forward search's spot a third of the way down the view, the source's word
    /// marked as Find marks a match; or SyncTeX's box, when the word can't be told
    /// from its neighbours or the find bar holds the selection.
    func reveal(_ loc: ForwardLoc, word: SyncTeXWord?) {
        guard view.bounds.width > 0, view.shownHeight > 0 else {
            pendingReveal = (loc, word)
            return
        }
        pendingReveal = nil
        guard let document = view.document, let locatedPage = document.page(at: Int(loc.page) - 1) else { return }
        // The source occurrence can wrap beyond the first SyncTeX box.
        let match = word.flatMap { document.bounds(of: $0, near: loc.matches ?? [loc]) }
        let page = match?.page ?? locatedPage
        let rect = match?.rect ?? SyncTeXGeometry.highlightRect(loc, pageBounds: page.bounds(for: view.displayBox))
        // A destination lands below the toolbar, a rect under it.
        view.go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY + view.shownHeight / 3 / view.scaleFactor)))
        if let selection = match?.selection, !finding {
            selection.color = .findHighlightColor
            view.setCurrentSelection(selection, animate: true)
        } else {
            view.flash(rect, on: page)
        }
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        show()
    }

    private func show(scrolling: Bool = true) {
        guard matches.indices.contains(matchIndex) else { return }
        view.setCurrentSelection(matches[matchIndex], animate: scrolling)
        if scrolling { view.scrollSelectionToVisible(nil) }
    }

    /// A SyncTeX point on a line of text: SyncTeX resolves only points on a glyph
    /// box, and the page centre is usually whitespace.
    func sourcePoint() -> (Int, CGPoint)? {
        guard let document = view.document else { return nil }
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

/// Double-click inverse search runs after PDFKit selects the clicked word.
final class SyncPDFView: PDFView, PDFPageOverlayViewProvider {
    var onInverse: (_ page: Int, _ point: CGPoint, _ word: SyncTeXWord?) -> Void = { _, _, _ in }
    var onResize: () -> Void = {}
    private let pagesDark = Atomic(false)

    var darkPaper = false {
        didSet {
            guard darkPaper != oldValue else { return }
            pagesDark.store(darkPaper, ordering: .relaxed)
            pageShadowsEnabled = !darkPaper
            matchScroller()
        }
    }

    func matchScroller() {
        documentView?.enclosingScrollView?.scrollerKnobStyle = darkPaper ? .light : .default
    }

    /// PDFKit draws page tiles off the main actor; only page pixels change.
    override nonisolated func draw(_ page: PDFPage, to context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let box = page.bounds(for: .cropBox).applying(page.transform(for: .cropBox))
        func drawPage() {
            context.setFillColor(.white)
            context.fill(box)
            page.draw(with: .cropBox, to: context)
        }
        drawPage()
        guard pagesDark.load(ordering: .relaxed) else { return }
        context.setBlendMode(.difference)
        context.setFillColor(.white)
        context.fill(box)
        context.setBlendMode(.color)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setBlendMode(.normal)
        drawPage()
        context.endTransparencyLayer()
    }

    /// Forward search's marks, in the pages' overlays rather than on the pages: an
    /// annotation would be printed and read by VoiceOver.
    private var marks: [(page: PDFPage, rect: CGRect, view: NSView)] = []
    /// The overlays PDFKit has asked for, which it keeps while their pages show.
    private let overlays = NSMapTable<PDFPage, NSView>.weakToWeakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pageOverlayViewProvider = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        pageOverlayViewProvider = self
    }

    /// Marks `rect` on `page` for 2.2 seconds.
    func flash(_ rect: CGRect, on page: PDFPage) {
        let view = MarkView()
        marks.append((page, rect, view))
        if let overlay = overlays.object(forKey: page) { place(view, at: rect, on: page, in: overlay) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            view.removeFromSuperview()
            self?.marks.removeAll { $0.view === view }
        }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PageOverlay()
        overlays.setObject(overlay, forKey: page)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlay: NSView, for page: PDFPage) {
        for mark in marks where mark.page === page { place(mark.view, at: mark.rect, on: page, in: overlay) }
    }

    /// An overlay spans the page's box, unrotated (PDFKit rotates the overlay itself).
    private func place(_ mark: NSView, at rect: CGRect, on page: PDFPage, in overlay: NSView) {
        let box = page.bounds(for: displayBox)
        let x = overlay.bounds.width / box.width, y = overlay.bounds.height / box.height
        mark.frame = CGRect(x: (rect.minX - box.minX) * x, y: (rect.minY - box.minY) * y,
                            width: rect.width * x, height: rect.height * y)
        mark.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin, .width, .height]
        overlay.addSubview(mark)
    }

    override func mouseMoved(with event: NSEvent) {
        if updateDividerCursor(with: event) { return }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if !updateDividerCursor(with: event) { super.cursorUpdate(with: event) }
    }

    /// SwiftUI reassigns unchanged frames during layout. PDFView would refit
    /// the width and undo a pinch while auto-scaling is still active.
    override var frame: NSRect {
        get { super.frame }
        set { if newValue != super.frame { super.frame = newValue } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI reassigns the same frame on scroll; only a new size counts.
        guard newSize != frame.size else { return }
        // At the document start, width changes or Fit Page can lose the first
        // page's visible top beneath the toolbar; restore it after resizing.
        let widthChanged = newSize.width != frame.width
        let atStart = bounds.width > 0 && shownHeight > 0 && atDocumentStart
        super.setFrameSize(newSize)
        onResize()
        if atStart, widthChanged || !atDocumentStart, let page = document?.page(at: 0) {
            go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: displayBox).maxY)))
        }
    }

    /// A divider or window drag refits the page each step, and every step would flash the
    /// overlay scrollers; they stay out of sight until the drag ends.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        documentView?.enclosingScrollView?.hideOverlayScrollers(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        documentView?.enclosingScrollView?.hideOverlayScrollers(false)
    }

    /// Allow the scaled page-break margin when checking the first page's top.
    private var atDocumentStart: Bool {
        guard let page = document?.page(at: 0) else { return false }
        let top = convert(CGPoint(x: 0, y: page.bounds(for: displayBox).maxY), from: page).y
        return top <= bounds.maxY - safeAreaInsets.top + pageBreakMargins.top * scaleFactor
    }

    /// Use the visible top below the bars; `currentDestination` lies behind them.
    var shownDestination: PDFDestination? {
        let top = CGPoint(x: bounds.minX, y: bounds.maxY - safeAreaInsets.top)
        return page(for: top, nearest: true).map { PDFDestination(page: $0, at: convert(top, to: $0)) }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { goToSource(at: convert(event.locationInWindow, from: nil)) }
    }

    /// Go to Source Position for the clicked point, above PDFKit's own items.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        // The app fixes the page layout, and scrolling turns the pages.
        menu?.keep([#selector(copy(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:))])
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
        onInverse(document.index(for: page) + 1, SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox)), page.syncWord(at: point))
    }
}

/// A page's overlay, which takes no clicks: the PDF view keeps them all.
private final class PageOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The square annotation the mark once was, as PDFKit drew it: Find's colour as a fill
/// and, over it, a 1 pt border at half the fill's strength.
private final class MarkView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.findHighlightColor.withAlphaComponent(0.4).cgColor
        layer?.borderColor = NSColor.findHighlightColor.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 1
    }
}

struct PDFRepresentable: NSViewRepresentable {
    let project: ProjectModel
    let darkPaper: Bool

    func makeNSView(context: Context) -> SyncPDFView {
        let view = project.pdf.view
        view.onInverse = { [weak project] page, point, word in
            Task { await project?.inverseSync(page: page, x: point.x, y: point.y, word: word) }
        }
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        project.pdf.setDarkPaper(darkPaper)
    }
}

extension PDFPage {
    /// PDFKit's characterIndex is inaccurate for pdfTeX's T1 fonts on 27.2;
    /// measure each letter's selection to retain the clicked source occurrence.
    func syncWord(at point: CGPoint) -> SyncTeXWord? {
        // PDFKit's word lookup crashes on a page whose document has gone (it holds it weakly).
        guard document != nil, let word = selectionForWord(at: point), let text = word.string, let context = string else { return nil }
        let range = word.range(at: 0, on: self)
        let offset = (0..<range.length).first { i in
            selection(for: NSRange(location: range.location + i, length: 1)).map { $0.bounds(for: self).maxX > point.x } ?? false
        }
        return SyncTeXWord(text: text, offset: offset ?? 0, context: context, contextOffset: range.location)
    }

}

extension PDFDocument {
    typealias SyncMatch = (page: PDFPage, rect: CGRect, selection: PDFSelection)

    /// Align the source line with rendered text first, so equal words retain their occurrence.
    /// SyncTeX boxes delimit the fallback when commands prevent an exact text alignment.
    func bounds(of word: SyncTeXWord, near locations: [ForwardLoc]) -> SyncMatch? {
        guard !locations.isEmpty, pageCount > 0 else { return nil }
        let first = max(0, Int(locations.map(\.page).min()!) - 2)
        let last = min(pageCount - 1, Int(locations.map(\.page).max()!))
        guard first <= last else { return nil }
        var letters: [Character] = [], positions: [(page: PDFPage, range: NSRange)] = []
        for index in first...last {
            guard let page = page(at: index), let text = page.string else { continue }
            let normalized = SyncText(text)
            letters += normalized.letters
            positions += normalized.ranges.map { (page, $0) }
        }
        let source = SyncText(word.context, source: true), target = SyncText(word.text).letters
        guard !target.isEmpty else { return nil }
        let at = source.ranges.firstIndex { $0.location >= word.contextOffset } ?? source.letters.count
        func rect(at start: Int, length: Int) -> SyncMatch? {
            guard start >= 0, start + length <= positions.count else { return nil }
            let first = positions[start]
            let samePage = positions[start..<start + length].prefix { $0.page === first.page }
            guard let end = samePage.last,
                  let selection = first.page.selection(for: NSRange(location: first.range.location,
                                                                    length: NSMaxRange(end.range) - first.range.location)) else { return nil }
            return (first.page, selection.bounds(for: first.page), selection)
        }
        func distance(_ hit: SyncMatch) -> CGFloat {
            let index = index(for: hit.page) + 1
            return locations.map { loc in
                let box = SyncTeXGeometry.highlightRect(loc, pageBounds: hit.page.bounds(for: .cropBox))
                let x = max(0, box.minX - hit.rect.maxX, hit.rect.minX - box.maxX)
                let y = max(0, box.minY - hit.rect.maxY, hit.rect.minY - box.maxY)
                return CGFloat(abs(Double(index) - loc.page)) * 100_000 + x + y
            }.min() ?? .greatestFiniteMagnitude
        }
        if at + target.count <= source.letters.count,
           source.letters[at..<at + target.count].elementsEqual(target) {
            let exact = SyncText.matches(source.letters, in: letters).compactMap { start -> (target: SyncMatch, distance: CGFloat, anchor: CGFloat)? in
                guard let anchor = rect(at: start, length: 1), let end = rect(at: start + source.letters.count - 1, length: 1),
                      let target = rect(at: start + at, length: target.count) else { return nil }
                // Both context ends constrain rotations of identical sentences across paragraphs.
                return (target, distance(target), distance(anchor) + distance(end))
            }
            if let best = exact.min(by: { a, b in a.distance == b.distance ? a.anchor < b.anchor : a.distance < b.distance }) {
                let tied = exact.filter { abs($0.distance - best.distance) < 0.001 && abs($0.anchor - best.anchor) < 0.001 }
                return tied.count == 1 ? best.target : nil
            }
        }
        let before = Array(source.letters.prefix(at)), after = Array(source.letters.dropFirst(min(at + target.count, source.letters.count)))
        let candidates = SyncText.matches(target, in: letters).compactMap { start -> (hit: SyncMatch, context: Int, distance: CGFloat)? in
            guard let hit = rect(at: start, length: target.count) else { return nil }
            let page = Double(index(for: hit.page) + 1)
            let boxes = locations.filter { $0.page == page }.map { SyncTeXGeometry.highlightRect($0, pageBounds: hit.page.bounds(for: .cropBox)) }
            guard let top = boxes.map(\.maxY).max(), let bottom = boxes.map(\.minY).min(),
                  hit.rect.maxY >= bottom - hit.rect.height, hit.rect.minY <= top + hit.rect.height else { return nil }
            let prefix = zip(before.reversed(), letters[..<start].reversed()).prefix { $0 == $1 }.count
            let suffix = zip(after, letters[(start + target.count)...]).prefix { $0 == $1 }.count
            return (hit, prefix + suffix, distance(hit))
        }
        guard let best = candidates.max(by: { a, b in a.context == b.context ? a.distance > b.distance : a.context < b.context }) else { return nil }
        // Equal evidence cannot identify which duplicate was clicked; keep SyncTeX's box.
        let tied = candidates.filter { $0.context == best.context && abs($0.distance - best.distance) < 0.001 }
        return tied.count == 1 ? best.hit : nil
    }
}

/// Comparison ignores layout whitespace, punctuation and font ligatures, while keeping glyph ranges.
private nonisolated struct SyncText {
    var letters: [Character] = []
    var ranges: [NSRange] = []

    init(_ text: String, source: Bool = false) {
        var offset = 0, command = false, escaped = false
        let ligatures = ["ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl"]
        for character in text {
            let value = String(character), length = value.utf16.count
            defer { offset += length }
            if source {
                if character == "\\" { command = true; escaped = true; continue }
                if command, character.isLetter { continue }
                command = false
                if character == "%", !escaped { break }
                escaped = false
            }
            for letter in (ligatures[value] ?? value.precomposedStringWithCanonicalMapping) where letter.isLetter || letter.isNumber {
                letters.append(letter)
                ranges.append(NSRange(location: offset, length: length))
            }
        }
    }

    static func matches(_ target: [Character], in text: [Character]) -> [Int] {
        guard !target.isEmpty, text.count >= target.count else { return [] }
        return (0...text.count - target.count).filter { start in
            text[start] == target[0] && text[start..<start + target.count].elementsEqual(target)
        }
    }
}

private extension PDFView {
    /// The height clear of the toolbar, find bar and bottom status bar.
    var shownHeight: CGFloat { bounds.height - safeAreaInsets.top - safeAreaInsets.bottom }
}

extension NSMenu {
    /// Keep word actions before Cut/Copy, then only allowed actions or submenus.
    func keep(_ actions: Set<Selector>) {
        func kept(_ item: NSMenuItem) -> Bool {
            item.action.map(actions.contains) == true || item.submenu?.items.contains(where: kept) == true
        }
        let word = items.firstIndex { $0.action == #selector(NSText.cut(_:)) || $0.action == #selector(NSText.copy(_:)) } ?? 0
        var shown = Array(items[..<word])
        for item in items[word...] where item.isSeparatorItem ? shown.last?.isSeparatorItem == false : kept(item) { shown.append(item) }
        if shown.last?.isSeparatorItem == true { shown.removeLast() }
        items = shown
    }
}
