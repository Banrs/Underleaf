import AppKit
import CoreImage.CIFilterBuiltins
import PDFKit
import os

final class SyncPDFView: PDFView, PDFPageOverlayViewProvider {
    var onInverse: (_ page: Int, _ point: CGPoint, _ click: PageClick?, _ quietly: Bool) -> Void = { _, _, _, _ in }
    var onResize: () -> Void = {}

    var pageScrollView: NSScrollView? { documentView?.enclosingScrollView }
    var paper = PDFPaper.white { didSet { matchPaper() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        matchPaper()
    }

    private func matchPaper() {
        darkPaper = paper.isDark(inDarkAppearance: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    private(set) var darkPaper = false {
        didSet {
            guard darkPaper != oldValue else { return }
            for case let overlay as PageOverlay in overlays.objectEnumerator()?.allObjects ?? [] { overlay.dark = darkPaper }
            matchScroller()
        }
    }

    static var invert: [CIFilter] {
        let hue = CIFilter.hueAdjust()
        hue.angle = .pi
        return [CIFilter.colorInvert(), hue]
    }

    func matchScroller() { pageScrollView?.scrollerKnobStyle = darkPaper ? .light : .dark }

    /// The box pages show, fixed, as drawing off the main thread can't read `displayBox`.
    nonisolated static let box = PDFDisplayBox.cropBox

    override nonisolated func draw(_ page: PDFPage, to context: CGContext) { Self.paint(page, to: context) }

    private nonisolated static func paint(_ page: PDFPage, to context: CGContext) {
        context.saveGState()
        context.setFillColor(.white)
        context.fill(page.bounds(for: box).applying(page.transform(for: box)))
        context.restoreGState()
        page.draw(with: box, to: context)
    }

    /// The pages in view, by index, and the pixels per point they show at: what covers are drawn for.
    var coverPages: CoverPages {
        guard let document, hasShownArea, !UserDefaults.standard.bool(forKey: "PDFCoversOff") else { return CoverPages() }
        let shown = shownRect
        var indices: [Int] = []
        for y in [shown.maxY - 1, shown.midY, shown.minY + 1] {
            if let page = page(for: CGPoint(x: shown.midX, y: y), nearest: true), !indices.contains(document.index(for: page)) {
                indices.append(document.index(for: page))
            }
        }
        return CoverPages(indices: indices, scale: scaleFactor * (window?.backingScaleFactor ?? 2))
    }

    /// Whole pages drawn off the main thread, on a document no other thread touches, to stand in for its pages while
    /// PDFKit draws their tiles after a swap. Whole pages, rather than the parts in view, still fit if the view scrolls
    /// before the swap and need no rotation maths; together they're capped at 24 megapixels.
    nonisolated static func covers(_ wanted: CoverPages, of document: PDFDocument) -> [Int: CGImage] {
        signposts.withIntervalSignpost("covers") {
            let pages = wanted.indices.compactMap { index in document.page(ifAt: index).map { (index, $0) } }
            var covers: [Int: CGImage] = [:]
            for (index, page) in pages {
                let box = page.bounds(for: box).applying(page.transform(for: box))
                let scale = min(wanted.scale, (24e6 / Double(pages.count) / (box.width * box.height)).squareRoot())
                guard let context = CGContext(data: nil, width: Int((box.width * scale).rounded(.up)), height: Int((box.height * scale).rounded(.up)),
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { continue }
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -box.minX, y: -box.minY)
                paint(page, to: context)
                covers[index] = context.makeImage()
            }
            return covers
        }
    }

    private nonisolated static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private var covers: [Int: CGImage] = [:]
    private var uncovering: Task<Void, Never>?

    func covering(_ covers: [Int: CGImage], _ change: () -> Void) {
        self.covers = covers
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
        self.covers = [:]
        restart(&uncovering, after: .milliseconds(400)) { [weak self] in
            for case let overlay as PageOverlay in self?.overlays.objectEnumerator()?.allObjects ?? [] { overlay.uncover() }
        }
    }

    private(set) var mark: (page: PDFPage, rect: CGRect, view: NSView, fading: Task<Void, Never>)?
    private let overlays = NSMapTable<PDFPage, NSView>.weakToWeakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayBox = Self.box
        pageOverlayViewProvider = self
        matchPaper()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { mark?.fading.cancel() }

    func flash(_ rect: CGRect, on page: PDFPage) {
        removeMark()
        let view = MarkView(onDarkPaper: darkPaper)
        let fading = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2.2)) } catch { return }
            await NSAnimationContext.runAnimationGroup { _ in view.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            self?.removeMark()
        }
        mark = (page, rect, view, fading)
        if let overlay = overlays.object(forKey: page) { place(view, at: rect, on: page, in: overlay) }
    }

    func removeMark() {
        mark?.fading.cancel()
        mark?.view.removeFromSuperview()
        mark = nil
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PageOverlay()
        overlay.dark = darkPaper
        overlays.setObject(overlay, forKey: page)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlay: NSView, for page: PDFPage) {
        if let cover = document.flatMap({ covers[$0.index(for: page)] }) { (overlay as? PageOverlay)?.cover(cover) }
        if let mark, mark.page === page { place(mark.view, at: mark.rect, on: page, in: overlay) }
    }

    private func place(_ mark: NSView, at rect: CGRect, on page: PDFPage, in overlay: NSView) {
        let box = page.bounds(for: displayBox)
        let scale = CGAffineTransform(scaleX: overlay.bounds.width / box.width, y: overlay.bounds.height / box.height)
        mark.frame = rect.applying(scale.translatedBy(x: -box.minX, y: -box.minY))
        mark.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin, .width, .height]
        overlay.addSubview(mark)
    }

    override func mouseMoved(with event: NSEvent) { if !updateDividerCursor(with: event) { super.mouseMoved(with: event) } }
    override func cursorUpdate(with event: NSEvent) { if !updateDividerCursor(with: event) { super.cursorUpdate(with: event) } }

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        let place = hasShownArea ? shownPlace : nil
        super.setFrameSize(newSize)
        onResize()
        if let place {
            go(to: place)
            lastPlace = place
        }
    }

    /// The place shown before the last resize, which is the one to keep while the pane is collapsed.
    private(set) var lastPlace: (index: Int, point: CGPoint)?

    func goToStart() {
        guard let page = document?.page(at: 0) else { return }
        go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: displayBox).maxY)))
    }

    /// Puts the place's point at the top left of the shown area, on its page or the last one.
    func go(to place: (index: Int, point: CGPoint)) {
        guard let document, let page = document.page(ifAt: min(max(place.index, 0), document.pageCount - 1)) else { return }
        go(to: PDFDestination(page: page, at: place.point))
    }

    var shownHeight: CGFloat { bounds.height - safeAreaInsets.top - safeAreaInsets.bottom }

    var shownRect: CGRect { CGRect(x: bounds.minX, y: bounds.minY + safeAreaInsets.bottom, width: bounds.width, height: shownHeight) }

    var hasShownArea: Bool { bounds.width > 0 && shownHeight > 0 }

    var shownPlace: (index: Int, point: CGPoint)? {
        let top = CGPoint(x: bounds.minX, y: bounds.maxY - safeAreaInsets.top)
        // Pages have no top margin, so the page whose top edge meets the bar is the one under it, not the one above.
        guard let page = page(for: CGPoint(x: top.x, y: top.y - 1 / (window?.backingScaleFactor ?? 1)), nearest: true),
              let document else { return nil }
        return (index: document.index(for: page), point: convert(top, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if isDoubleClick(event) { goToSource(at: convert(event.locationInWindow, from: nil), quietly: true) }
    }

    override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let selection = currentSelection, let page = selection.pages.first else { return }
        let box = selection.bounds(for: page)
        go(to: PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.midY + shownHeight / 2 / scaleFactor)))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        menu?.keep([#selector(copy(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:))])
        guard let menu, document != nil else { return menu }
        let item = NSMenuItem(title: MenuCommand.syncInverse.title, action: #selector(goToSource(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = convert(event.locationInWindow, from: nil)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func goToSource(_ item: NSMenuItem) { if let location = item.representedObject as? CGPoint { goToSource(at: location) } }

    private func goToSource(at location: CGPoint, quietly: Bool = false) {
        guard let page = page(for: location, nearest: true), let number = document?.number(of: page) else { return }
        let point = convert(location, to: page)
        onInverse(number, SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox)), page.click(at: point), quietly)
    }
}

nonisolated struct CoverPages: Sendable {
    var indices: [Int] = []
    var scale: CGFloat = 0
}

final class PageOverlay: NSView {
    private let drawing = CALayer()

    var dark = false {
        didSet {
            layer?.backgroundFilters = dark ? SyncPDFView.invert : nil
            drawing.filters = layer?.backgroundFilters
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        drawing.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(drawing)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { uncover() }
        super.setFrameSize(newSize)
    }

    func cover(_ image: CGImage) {
        drawing.contents = image
        drawing.frame = bounds
    }

    func uncover() { drawing.contents = nil }

    var covered: Bool { drawing.contents != nil }
}

private final class MarkView: NSView {
    private let paper: NSAppearance.Name

    init(onDarkPaper dark: Bool) {
        paper = dark ? .darkAqua : .aqua
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let find = NSColor.findHighlightColor
        layer?.backgroundColor = find.withAlphaComponent(0.4).cgColor
        layer?.borderColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? find.legibleAsText(in: paper, ratio: 3).cgColor : find.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 1
    }
}

extension NSMenu {
    func keep(_ actions: Set<Selector>) {
        func kept(_ item: NSMenuItem) -> Bool { item.action.map(actions.contains) == true || item.submenu?.items.contains(where: kept) == true }
        let word = items.firstIndex { $0.action == #selector(NSText.cut(_:)) || $0.action == #selector(NSText.copy(_:)) } ?? 0
        tidy(items[..<word] + items[word...].filter { $0.isSeparatorItem || kept($0) })
    }

    func tidy(_ list: [NSMenuItem]) {
        var shown: [NSMenuItem] = []
        for item in list where !item.isSeparatorItem || shown.last?.isSeparatorItem == false { shown.append(item) }
        if shown.last?.isSeparatorItem == true { shown.removeLast() }
        items = shown
    }
}
