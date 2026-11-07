import AppKit
import PDFKit

/// A bar in the margin beside a bad box, as LaTeX's draft option draws one: red beside each line of an overfull box that
/// runs past the text, orange beside an underfull one. Clicking it goes to the box's source line.
final class BadBoxMark: NSView {
    let badBox: BadBoxArea
    private let press: (BadBoxArea) -> Void

    init(_ badBox: BadBoxArea, press: @escaping (BadBoxArea) -> Void) {
        (self.badBox, self.press) = (badBox, press)
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = badBox.message
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(badBox.message)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (badBox.tooWide == nil ? NSColor.systemOrange : .systemRed).cgColor
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { press(badBox) }
    override func accessibilityPerformPress() -> Bool {
        press(badBox)
        return true
    }

    /// Where the bars go on `page`, in its coordinates: beside each line in the box's area whose text runs past the margin,
    /// or beside the whole area when no line does, as for an underfull box or an overfull one of no text. The area reaches
    /// as far as the overfull line runs, which the log says is past the margin by `tooWide`.
    static func rects(for badBox: BadBoxArea, on page: PDFPage) -> [CGRect] {
        let bounds = page.bounds(for: SyncPDFView.box), loc = badBox.area
        guard let h = loc.h, let v = loc.v, let width = loc.width, let height = loc.height else { return [] }
        let area = CGRect(x: bounds.minX + h, y: bounds.maxY - v, width: width, height: height)
        // At least a click's height, as beside a thin rule.
        let beside = { (rect: CGRect) in
            let height = max(rect.height, 8)
            return CGRect(x: rect.maxX + 2, y: rect.midY - height / 2, width: 3, height: height)
        }
        guard let tooWide = badBox.tooWide else { return [beside(area)] }
        let margin = area.maxX - tooWide
        let probe = CGRect(x: area.minX, y: area.minY, width: bounds.maxX - area.minX, height: area.height)
        let lines = (page.selection(for: probe)?.selectionsByLine() ?? []).map { $0.bounds(for: page) }
        let over = lines.filter { $0.maxX > margin + 0.5 && area.minY...area.maxY ~= $0.midY }
        return over.isEmpty ? [beside(area)] : over.map(beside)
    }
}

extension SyncPDFView {
    /// Marks the bad boxes of the document shown, by the index of the page each is on.
    func mark(_ badBoxes: [Int: [BadBoxArea]], press: @escaping (BadBoxArea) -> Void) {
        badBoxMarks = (badBoxes, press)
        remarkBadBoxes()
    }

    func clearBadBoxes() {
        badBoxMarks = nil
        remarkBadBoxes()
    }

    /// Marks again the pages PDFKit shows; it asks for the others' overlays as it shows them.
    func remarkBadBoxes() {
        for case let page as PDFPage in overlays.keyEnumerator().allObjects {
            if let overlay = overlays.object(forKey: page) { markBadBoxes(on: page, in: overlay) }
        }
    }

    func markBadBoxes(on page: PDFPage, in overlay: NSView) {
        overlay.subviews.filter { $0 is BadBoxMark }.forEach { $0.removeFromSuperview() }
        guard showsBadBoxes, let (marks, press) = badBoxMarks, let index = document?.index(for: page) else { return }
        for badBox in marks[index] ?? [] {
            for rect in BadBoxMark.rects(for: badBox, on: page) { place(BadBoxMark(badBox, press: press), at: rect, on: page, in: overlay) }
        }
    }
}
