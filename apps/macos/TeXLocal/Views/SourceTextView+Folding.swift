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

    func drawFolds(in rect: CGRect) {
        foldMarks.removeAll(keepingCapacity: true)
        guard !folds.isEmpty || gutterHovered else { return }
        let foldedLines = foldedLines, offered = gutterHovered ? foldable : [:]
        let middle = (gutter.numbersEnd + sourceTextStart) / 2
        let down = Self.symbol("chevron.down", size: gutter.font.capHeight, scale: .small)
        let right = Self.symbol("chevron.right", size: gutter.font.capHeight, scale: .small)
        let badge = Self.foldBadge
        badge.image = Self.symbol("ellipsis", size: fontSize, scale: .large)
        let badgeSize = badge.cellSize
        for (offset, fragment) in fragments {
            let line = document.line(at: offset)
            let hiddenRange = foldedLines[line]
            guard hiddenRange != nil || offered[line] != nil, let first = fragment.textLineFragments.first else { continue }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let image = hiddenRange == nil ? down : right
            let y = frame.minY + first.typographicBounds.midY - image.size.height / 2
            let arrow = CGRect(origin: CGPoint(x: middle - image.size.width / 2, y: y), size: image.size)
            image.draw(in: centerScanRect(arrow), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            guard let hiddenRange, let last = fragment.textLineFragments.last(where: { $0.characterRange.length > 0 })
                    ?? fragment.textLineFragments.first else { continue }
            let origin = CGPoint(x: frame.minX + last.typographicBounds.maxX + linePadding,
                                 y: frame.minY + last.typographicBounds.midY - badgeSize.height / 2)
            let mark = centerScanRect(CGRect(origin: origin, size: badgeSize))
            foldMarks.append((mark, hiddenRange))
            if mark.intersects(rect) { badge.draw(withFrame: mark, in: self) }
        }
    }

    private static let foldBadge: NSButtonCell = {
        let badge = NSButtonCell(imageCell: nil)
        badge.bezelStyle = .badge
        badge.imagePosition = .imageOnly
        return badge
    }()
    private static var symbols: [String: NSImage] = [:]

    private static func symbol(_ name: String, size: CGFloat, scale: NSImage.SymbolScale) -> NSImage {
        let key = "\(name) \(size) \(scale.rawValue)"
        if let made = symbols[key] { return made }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold, scale: scale)
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
        guard let line = foldLine(at: point) else { return false }
        toggleFold(line: line)
        return true
    }

    func foldLine(at point: NSPoint) -> Int? {
        guard point.x >= gutter.numbersEnd, point.x < sourceTextStart else { return nil }
        let line = document.line(at: characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x, y: point.y)))
        return foldable[line] != nil || foldedLines[line] != nil ? line : nil
    }

    func gutterHover(_ hovering: Bool) {
        guard hovering != gutterHovered else { return }
        gutterHovered = hovering
        let shown = visibleRect
        setNeedsDisplay(NSRect(x: 0, y: shown.minY, width: sourceTextStart, height: shown.height))
    }
}
