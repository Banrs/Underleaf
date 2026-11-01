import AppKit

extension SourceTextView: NSTextContentStorageDelegate {
    func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard !folds.isEmpty, let range = textElement.elementRange else { return true }
        return !folds.hides(offset(range.location))
    }

    var foldable: [Int: Fold] {
        if let foldCache { return foldCache }
        let found = Dictionary(document.folds().map { ($0.line, $0) }) { first, _ in first }
        foldCache = found
        return found
    }

    func hidden(_ fold: Fold) -> NSRange { fold.hidden(in: document, length: length) }

    var foldedLines: [Int: NSRange] { folds.headers(in: document) }

    func foldAtCaret() {
        let line = document.line(at: caret)
        let over = foldable.values.filter { $0.line <= line && line <= $0.end && !folds.ranges.contains(hidden($0)) }
        guard let fold = over.max(by: { $0.line < $1.line }) else { return NSSound.beep() }
        setFolds(folds.ranges + [hidden(fold)], keeping: fold.line)
    }

    func unfoldAtCaret() {
        let line = document.line(at: caret)
        let own = foldable[line].map(hidden)
        let opening = folds.ranges.filter { $0 == own || NSIntersectionRange($0, selection).length > 0 }
        guard !opening.isEmpty else { return NSSound.beep() }
        setFolds(folds.ranges.filter { !opening.contains($0) })
    }

    func foldAll() {
        let all = foldable.values.sorted { $0.line < $1.line }
        guard !all.isEmpty else { return NSSound.beep() }
        let line = document.line(at: caret)
        let outer = all.first { $0.line < line && line <= $0.end }
        setFolds(all.map(hidden), keeping: outer?.line)
    }

    func unfoldAll() {
        guard !folds.isEmpty else { return NSSound.beep() }
        setFolds([])
    }

    func toggleFold(line: Int) {
        if let range = foldedLines[line] { return setFolds(folds.ranges.filter { $0 != range }) }
        guard let fold = foldable[line] else { return }
        setFolds(folds.ranges + [hidden(fold)], keeping: line)
    }

    private func setFolds(_ ranges: [NSRange], keeping line: Int? = nil) {
        let set = FoldSet(ranges)
        if let line, let header = set.caret(on: line, hiding: selection, in: document) {
            folds = FoldSet()
            setSelectedRange(header)
        }
        folds = set
        relayOutFolds()
    }

    func relayOutFolds() {
        guard let manager = textLayoutManager else { return }
        manager.invalidateLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }

    private var chevronX: CGFloat { (gutter.numbersEnd + textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)) / 2 }

    func inChevrons(_ point: NSPoint) -> Bool { point.x >= gutter.numbersEnd && point.x < textContainerOrigin.x }

    func drawFolds(in rect: CGRect) {
        foldMarks.removeAll(keepingCapacity: true)
        guard !folds.isEmpty || gutterHovered else { return }
        let foldedLines = foldedLines, offered = gutterHovered ? foldable : [:]
        for (offset, fragment) in fragments {
            let line = document.line(at: offset)
            let hiddenRange = foldedLines[line]
            guard hiddenRange != nil || offered[line] != nil, let first = fragment.textLineFragments.first else { continue }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let height = first.typographicBounds.height
            let chevron = Self.symbol(hiddenRange != nil ? "chevron.right" : "chevron.down", size: max(8, fontSize * 0.62))
            let y = frame.minY + first.typographicBounds.minY + rowShift + (height - 2 * rowShift - chevron.size.height) / 2
            draw(chevron, at: CGPoint(x: (chevronX - chevron.size.width / 2).rounded(), y: onPixels(y)))
            guard let hiddenRange, let last = fragment.textLineFragments.last(where: { $0.characterRange.length > 0 })
                    ?? fragment.textLineFragments.first else { continue }
            let lineTop = frame.minY + last.typographicBounds.minY + rowShift
            let lineHeight = last.typographicBounds.height - 2 * rowShift
            let mark = CGRect(x: frame.minX + last.typographicBounds.maxX + 6, y: lineTop + 2,
                              width: (fontSize * 1.9).rounded(), height: max(lineHeight - 4, 8))
            foldMarks.append((mark, hiddenRange))
            guard mark.intersects(rect) else { continue }
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(roundedRect: mark, xRadius: mark.height / 2, yRadius: mark.height / 2).fill()
            let dots = Self.symbol("ellipsis", size: max(8, fontSize * 0.7))
            draw(dots, at: CGPoint(x: mark.midX - dots.size.width / 2, y: mark.midY - dots.size.height / 2))
        }
    }

    private func draw(_ image: NSImage, at origin: CGPoint) {
        image.draw(in: CGRect(origin: origin, size: image.size), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }

    private static var symbols: [String: NSImage] = [:]

    private static func symbol(_ name: String, size: CGFloat) -> NSImage {
        let key = "\(name) \(size)"
        if let made = symbols[key] { return made }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
        symbols[key] = made
        return made
    }

    func foldClick(at point: NSPoint) -> Bool {
        if let mark = foldMarks.first(where: { $0.rect.contains(point) }) {
            setFolds(folds.ranges.filter { $0 != mark.range })
            return true
        }
        guard inChevrons(point) else { return false }
        let line = document.line(at: characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x, y: point.y)))
        guard foldedLines[line] != nil || foldable[line] != nil else { return false }
        toggleFold(line: line)
        return true
    }

    func gutterHover(_ hovering: Bool) {
        guard hovering != gutterHovered else { return }
        gutterHovered = hovering
        let shown = visibleRect
        setNeedsDisplay(NSRect(x: gutter.numbersEnd, y: shown.minY, width: textContainerOrigin.x - gutter.numbersEnd, height: shown.height))
    }
}
