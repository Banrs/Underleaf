import AppKit
import CoreImage.CIFilterBuiltins
import PDFKit

final class SyncPDFView: PDFView, PDFPageOverlayViewProvider {
    var onInverse: (_ page: Int, _ point: CGPoint, _ click: PageClick?) -> Void = { _, _, _ in }
    var onResize: () -> Void = {}

    /// PDFKit's scroll view isn't in its interface: its document view leads to it.
    var pageScrollView: NSScrollView? { documentView?.enclosingScrollView }

    /// Each page inverted with its hues turned back, as Smart Invert shows it: Core Image over what PDFKit has drawn, so its tiles,
    /// selection and highlights stay its own and a change redraws nothing.
    var darkPaper = false {
        didSet {
            guard darkPaper != oldValue else { return }
            for case let overlay as PageOverlay in overlays.objectEnumerator()?.allObjects ?? [] { overlay.dark = darkPaper }
            liveCanvas.layer?.filters = darkPaper ? Self.invert : nil
            matchScroller()
        }
    }

    static var invert: [CIFilter] {
        let hue = CIFilter.hueAdjust()
        hue.angle = .pi
        return [CIFilter.colorInvert(), hue]
    }

    /// The knob is over the paper, whatever the window's appearance.
    func matchScroller() {
        pageScrollView?.scrollerKnobStyle = darkPaper ? .light : .dark
    }

    override func zoomIn(_ sender: Any?) {
        autoScales = false
        super.zoomIn(sender)
    }

    override func zoomOut(_ sender: Any?) {
        autoScales = false
        super.zoomOut(sender)
    }

    /// PDFKit draws page tiles off the main actor, here as a live page is drawn (`drawLive`).
    override nonisolated func draw(_ page: PDFPage, to context: CGContext) {
        Self.drawPaper(page.bounds(for: .cropBox).applying(page.transform(for: .cropBox)), to: context) {
            page.draw(with: .cropBox, to: context)
        }
    }

    private nonisolated static func drawPaper(_ box: CGRect, to context: CGContext, page draw: () -> Void) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(.white)
        context.fill(box)
        draw()
    }

    // MARK: - Live preview

    /// A page given to PDFKit fades in over an eighth of a second (27.2), and a layer's contents change in one frame.
    private let liveCanvas = LiveCanvas()
    private var liveLayers: [Int: CALayer] = [:]
    private var liveScale: CGFloat = 0
    private var shownScale: CGFloat { pageScrollView?.magnification ?? scaleFactor }
    var liveScaleChanged: Bool { !liveLayers.isEmpty && shownScale != liveScale }

    /// PDFKit rounds a page's frame to the display's pixels and draws at the view's scale from the frame's corner (27.2),
    /// so its page can take the layer's place unseen. Only the part in view is drawn: the whole grows with the square of
    /// the zoom, to half a gigabyte for A4 at 800% on a 2x display.
    func showLive(_ page: PDFPage, over shown: PDFPage, at index: Int) -> Bool {
        guard let documentView, let window, let overlay = overlays.object(forKey: shown), overlay.window != nil else { return false }
        let visible = overlay.visibleRect
        guard !visible.isEmpty else { return false }
        if liveCanvas.superview !== documentView {
            liveCanvas.frame = documentView.bounds
            documentView.addSubview(liveCanvas)
        }
        // PDFKit's scale is its scroll view's magnification: the size on screen is the one in the window.
        let onScreen = overlay.convert(overlay.bounds, to: nil).size, pixel = window.backingScaleFactor
        let box = page.bounds(for: .cropBox), scale = scaleFactor * pixel
        let whole = CGSize(width: (onScreen.width * pixel).rounded(), height: (onScreen.height * pixel).rounded())
        let unit = CGSize(width: overlay.bounds.width / (onScreen.width * pixel), height: overlay.bounds.height / (onScreen.height * pixel))
        let part = CGRect(x: (visible.minX - overlay.bounds.minX) / unit.width, y: (visible.minY - overlay.bounds.minY) / unit.height,
                          width: visible.width / unit.width, height: visible.height / unit.height)
            .integral.intersection(CGRect(origin: .zero, size: whole))
        let width = Int(part.width), height = Int(part.height)
        // Drawn into a surface the window server takes as it is: a bitmap of the layer's own is redrawn into the display's colours on its way to the screen (27.2).
        guard width >= 1, height >= 1,
              let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                   .pixelFormat: kCVPixelFormatType_32BGRA]),
              surface.lock(options: [], seed: nil) == KERN_SUCCESS else { return false }
        Self.drawLive(page, to: surface, box: box, scale: scale, from: part.origin)
        surface.unlock(options: [], seed: nil)
        if let name = Self.liveSpace.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, name) }
        let layer = liveLayers[index] ?? {
            let layer = CALayer()
            // A layer animates what changes by default; these change with the page they show.
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            liveCanvas.layer?.addSublayer(layer)
            liveLayers[index] = layer
            return layer
        }()
        layer.contents = surface
        layer.frame = liveCanvas.convert(CGRect(x: overlay.bounds.minX + part.minX * unit.width, y: overlay.bounds.minY + part.minY * unit.height,
                                                width: part.width * unit.width, height: part.height * unit.height), from: overlay)
        liveScale = shownScale
        return true
    }

    private nonisolated static let liveSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Halves drawn at once by Core Graphics itself: most of a page's time is its fonts', and PDFKit draws a page for
    /// one caller at a time (27.2). A page whose box PDFKit would turn or move is drawn in one, by PDFKit.
    private nonisolated static func drawLive(_ page: PDFPage, to surface: IOSurface, box: CGRect, scale: CGFloat, from corner: CGPoint) {
        // Drawing a page is safe from any thread, as PDFKit's own tiles are drawn.
        nonisolated(unsafe) let page = page
        nonisolated(unsafe) let ref = page.rotation == 0 && box.origin == .zero && page.bounds(for: .mediaBox) == box ? page.pageRef : nil
        let (width, height, halves) = (surface.width, surface.height, ref == nil ? 1 : 2)
        DispatchQueue.concurrentPerform(iterations: halves) { half in
            let rows = (height * half / halves)..<(height * (half + 1) / halves)
            guard let context = CGContext(data: surface.baseAddress + rows.lowerBound * surface.bytesPerRow, width: width,
                                          height: rows.count, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: liveSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            // A context counts from its own bottom row, the picture's rows from its top.
            context.translateBy(x: -corner.x, y: CGFloat(rows.upperBound - height) - corner.y)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            drawPaper(box, to: context) {
                if let ref { context.drawPDFPage(ref) } else { page.draw(with: .cropBox, to: context) }
            }
        }
    }

    func hasLive(at index: Int) -> Bool { liveLayers[index] != nil }

    func removeLive(at index: Int) {
        liveLayers.removeValue(forKey: index)?.removeFromSuperlayer()
    }

    func removeLive() {
        for layer in liveLayers.values { layer.removeFromSuperlayer() }
        liveLayers.removeAll()
    }

    /// In the page's overlay rather than an annotation, which would be printed and read by VoiceOver.
    private(set) var mark: (page: PDFPage, rect: CGRect, view: NSView, fading: Task<Void, Never>)?
    private let overlays = NSMapTable<PDFPage, NSView>.weakToWeakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pageOverlayViewProvider = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A fade is what the HIG puts in motion's place, so Reduce Motion keeps it.
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
        if let mark, mark.page === page { place(mark.view, at: mark.rect, on: page, in: overlay) }
    }

    /// Unrotated: PDFKit rotates the overlay itself.
    private func place(_ mark: NSView, at rect: CGRect, on page: PDFPage, in overlay: NSView) {
        let box = page.bounds(for: displayBox)
        let x = overlay.bounds.width / box.width, y = overlay.bounds.height / box.height
        mark.frame = CGRect(x: (rect.minX - box.minX) * x, y: (rect.minY - box.minY) * y,
                            width: rect.width * x, height: rect.height * y)
        mark.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin, .width, .height]
        overlay.addSubview(mark)
    }

    override func mouseMoved(with event: NSEvent) {
        if !updateDividerCursor(with: event) { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !updateDividerCursor(with: event) { super.cursorUpdate(with: event) }
    }

    /// SwiftUI reassigns unchanged frames during layout; PDFView would refit the width and undo a pinch in its own
    /// `setFrame:` while auto-scaling is active (27.2).
    override var frame: NSRect {
        get { super.frame }
        set { if newValue != super.frame { super.frame = newValue } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI reassigns the same frame on scroll; only a new size counts.
        guard newSize != frame.size else { return }
        // At the document start, width changes or Fit Page can lose the first page's visible top beneath the toolbar.
        let widthChanged = newSize.width != frame.width
        let atStart = hasShownArea && atDocumentStart
        super.setFrameSize(newSize)
        onResize()
        if atStart, widthChanged || !atDocumentStart, let page = document?.page(at: 0) {
            go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: displayBox).maxY)))
        }
    }

    private var atDocumentStart: Bool {
        guard let page = document?.page(at: 0) else { return false }
        let top = convert(CGPoint(x: 0, y: page.bounds(for: displayBox).maxY), from: page).y
        return top <= bounds.maxY - safeAreaInsets.top + pageBreakMargins.top * scaleFactor
    }

    /// Between the bars, which PDFKit's pages scroll beneath.
    var shownHeight: CGFloat { bounds.height - safeAreaInsets.top - safeAreaInsets.bottom }

    var hasShownArea: Bool { bounds.width > 0 && shownHeight > 0 }

    /// `currentDestination` lies behind the bars.
    var shownDestination: PDFDestination? {
        let top = CGPoint(x: bounds.minX, y: bounds.maxY - safeAreaInsets.top)
        return page(for: top, nearest: true).map { PDFDestination(page: $0, at: convert(top, to: $0)) }
    }

    /// A double-click whose pointer has moved by the time PDFKit's handling returns was dragged on to select by words.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, let up = window?.mouseLocationOutsideOfEventStream else { return }
        let down = event.locationInWindow
        if abs(up.x - down.x) <= 4, abs(up.y - down.y) <= 4 { goToSource(at: convert(down, from: nil)) }
    }

    func jumpToSelection() {
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

    @objc private func goToSource(_ item: NSMenuItem) {
        if let location = item.representedObject as? CGPoint { goToSource(at: location) }
    }

    private func goToSource(at location: CGPoint) {
        guard let page = page(for: location, nearest: true), let number = document?.number(of: page) else { return }
        let point = convert(location, to: page)
        onInverse(number, SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox)), page.click(at: point))
    }
}

private final class LiveCanvas: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        autoresizingMask = [.width, .height]
        // Over the page views PDFKit adds after it.
        layer?.zPosition = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PageOverlay: NSView {
    /// Over the page and everything PDFKit lays under its tiles, so no white is left at its edges.
    var dark = false {
        didSet { layer?.backgroundFilters = dark ? SyncPDFView.invert : nil }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class MarkView: NSView {
    private let paper: NSAppearance.Name

    init(onDarkPaper dark: Bool) {
        paper = dark ? .darkAqua : .aqua
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
