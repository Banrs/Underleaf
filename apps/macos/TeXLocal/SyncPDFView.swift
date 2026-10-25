import AppKit
import CoreImage.CIFilterBuiltins
import PDFKit

final class SyncPDFView: PDFView, PDFPageOverlayViewProvider {
    var onInverse: (_ page: Int, _ point: CGPoint, _ click: PageClick?) -> Void = { _, _, _ in }
    var onResize: () -> Void = {}

    /// PDFKit's scroll view isn't in its interface: its document view leads to it.
    var pageScrollView: NSScrollView? { documentView?.enclosingScrollView }

    /// Settings' paper, white, dark, or the window's appearance's.
    private var paperWatch: (any NSObjectProtocol)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        matchPaper()
    }

    private func matchPaper() {
        let paper = PDFPaper(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.pdfPaper) ?? "") ?? .white
        darkPaper = paper.isDark(onDark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// Inverted with its hues turned back, as Smart Invert: Core Image over PDFKit's drawing, so a change redraws nothing.
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

    /// The knob is over the paper, whatever the window's appearance.
    func matchScroller() { pageScrollView?.scrollerKnobStyle = darkPaper ? .light : .dark }

    /// On white, off the main actor as PDFKit draws its tiles.
    override nonisolated func draw(_ page: PDFPage, to context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(.white)
        context.fill(page.bounds(for: .cropBox).applying(page.transform(for: .cropBox)))
        page.draw(with: .cropBox, to: context)
    }

    // MARK: - SyncTeX's mark

    /// In the page's overlay rather than an annotation, which would be printed and read by VoiceOver.
    private(set) var mark: (page: PDFPage, rect: CGRect, view: NSView, fading: Task<Void, Never>)?
    private let overlays = NSMapTable<PDFPage, NSView>.weakToWeakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pageOverlayViewProvider = self
        paperWatch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.matchPaper() }
        }
        matchPaper()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let paperWatch { NotificationCenter.default.removeObserver(paperWatch) }
        mark?.fading.cancel()
    }

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
        let scale = CGAffineTransform(scaleX: overlay.bounds.width / box.width, y: overlay.bounds.height / box.height)
        mark.frame = rect.applying(scale.translatedBy(x: -box.minX, y: -box.minY))
        mark.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin, .width, .height]
        overlay.addSubview(mark)
    }

    // MARK: - The view

    override func mouseMoved(with event: NSEvent) { if !updateDividerCursor(with: event) { super.mouseMoved(with: event) } }
    override func cursorUpdate(with event: NSEvent) { if !updateDividerCursor(with: event) { super.cursorUpdate(with: event) } }

    /// At the document's start, the first page's top stays at the toolbar's edge as the width or Fit Page changes.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        let widthChanged = newSize.width != frame.width, atStart = hasShownArea && atDocumentStart
        super.setFrameSize(newSize)
        onResize()
        if atStart, widthChanged || !atDocumentStart, let page = document?.page(at: 0) {
            go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: displayBox).maxY)))
        }
    }

    /// The first page's top at the shown area's top, give or take a device pixel for the clip view's rounding.
    private var atDocumentStart: Bool {
        guard let page = document?.page(at: 0) else { return false }
        let top = convert(CGPoint(x: 0, y: page.bounds(for: displayBox).maxY), from: page).y
        return top <= bounds.maxY - safeAreaInsets.top + pageBreakMargins.top * scaleFactor + 1 / (window?.backingScaleFactor ?? 1)
    }

    var shownHeight: CGFloat { bounds.height - safeAreaInsets.top - safeAreaInsets.bottom }

    var hasShownArea: Bool { bounds.width > 0 && shownHeight > 0 }

    /// At the top between the bars, where `currentDestination` lies behind them; a page whose top is there is under it.
    var shownPlace: (index: Int, point: CGPoint)? {
        let top = CGPoint(x: bounds.minX, y: bounds.maxY - safeAreaInsets.top)
        guard let page = page(for: CGPoint(x: top.x, y: top.y - 1 / (window?.backingScaleFactor ?? 1)), nearest: true),
              let document else { return nil }
        return (index: document.index(for: page), point: convert(top, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            goToSource(at: convert(event.locationInWindow, from: nil))
            return
        }
        super.mouseDown(with: event)
    }

    /// ⌃L, on the responder chain while the pages have the keyboard, as the text view's is.
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

    private func goToSource(at location: CGPoint) {
        guard let page = page(for: location, nearest: true), let number = document?.number(of: page) else { return }
        let point = convert(location, to: page)
        onInverse(number, SyncTeXGeometry.synctexPoint(point, pageBounds: page.bounds(for: displayBox)), page.click(at: point))
    }
}

/// A layer for dark paper's filters over the pages, which clicks go through.
private class FilterView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PageOverlay: FilterView {
    /// Over the page and everything PDFKit lays under its tiles, so no white is left at its edges.
    var dark = false { didSet { layer?.backgroundFilters = dark ? SyncPDFView.invert : nil } }
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
    /// The items before the text's own (Look Up and the like), and of the rest those with the actions, with their separators.
    func keep(_ actions: Set<Selector>) {
        func kept(_ item: NSMenuItem) -> Bool { item.action.map(actions.contains) == true || item.submenu?.items.contains(where: kept) == true }
        let word = items.firstIndex { $0.action == #selector(NSText.cut(_:)) || $0.action == #selector(NSText.copy(_:)) } ?? 0
        tidy(items[..<word] + items[word...].filter { $0.isSeparatorItem || kept($0) })
    }

    /// Shows these items with a separator only between two groups.
    func tidy(_ list: [NSMenuItem]) {
        var shown: [NSMenuItem] = []
        for item in list where !item.isSeparatorItem || shown.last?.isSeparatorItem == false { shown.append(item) }
        if shown.last?.isSeparatorItem == true { shown.removeLast() }
        items = shown
    }
}
