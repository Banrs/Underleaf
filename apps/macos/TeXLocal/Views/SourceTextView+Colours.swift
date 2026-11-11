import AppKit

extension SourceTextView {
    private static let structure: Set<String> = [
        "\\documentclass", "\\usepackage", "\\RequirePackage", "\\input", "\\include", "\\subfile", "\\import", "\\subimport",
        "\\part", "\\chapter", "\\section", "\\subsection", "\\subsubsection", "\\paragraph", "\\subparagraph",
        "\\begin", "\\end", "\\item", "\\def", "\\newcommand", "\\renewcommand", "\\providecommand",
        "\\newenvironment", "\\renewenvironment", "\\DeclareMathOperator",
    ]

    func structuralCommands(in range: NSRange, of paragraph: NSString,
                            among highlights: [(range: NSRange, kind: HighlightKind)]? = nil) -> [NSRange] {
        guard paragraph.range(of: "\\").location != NSNotFound else { return [] }
        return (highlights ?? document.highlights(in: range)).compactMap { run in
            guard run.kind == .command, run.range.location >= range.location, NSMaxRange(run.range) <= NSMaxRange(range) else { return nil }
            let command = NSRange(location: run.range.location - range.location, length: run.range.length)
            return Self.structure.contains(paragraph.substring(with: command)) ? command : nil
        }
    }

    func installColouring() {
        textLayoutManager?.renderingAttributesValidator = { [weak self] manager, fragment in
            guard let self else { return }
            let range = fragment.rangeInElement
            let start = offset(range.location), end = offset(range.endLocation)
            let span = NSRange(location: start, length: end - start)
            let highlights = document.highlights(in: span)
            manager.setRenderingAttributes([.foregroundColor: NSColor.textColor], for: range)
            var runs: [Any] = []
            for run in highlights {
                let clipped = NSIntersectionRange(run.range, span)
                if clipped.length > 0, let range = textRange(clipped) {
                    manager.setRenderingAttributes([.foregroundColor: run.kind.color], for: range)
                    runs += [clipped.location - start, clipped.length, run.kind.rawValue]
                }
            }
            fragmentColours.setObject(runs as NSArray, forKey: fragment)
            checkStructuralWeight(of: fragment, in: span, among: highlights)
        }
    }

    private func checkStructuralWeight(of fragment: NSTextLayoutFragment, in span: NSRange,
                                       among highlights: [(range: NSRange, kind: HighlightKind)]) {
        guard let structuralFont, structuralFont != font, let paragraph = fragment.textElement as? NSTextParagraph else { return }
        let text = paragraph.attributedString
        let string = text.string as NSString
        guard text.length == span.length, string.range(of: "\\").location != NSNotFound else { return }
        var wanted = IndexSet(), shown = IndexSet()
        for command in structuralCommands(in: span, of: string, among: highlights) {
            wanted.insert(integersIn: command.location..<NSMaxRange(command))
        }
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { weight, range, _ in
            if weight as? NSFont == structuralFont { shown.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        guard wanted != shown else { return }
        let pending = staleStructuralRange
        staleStructuralRange = pending?.union(span) ?? span
        guard pending == nil else { return }
        // Changing a multiline mode can restyle untouched paragraphs. Rebuild those elements outside the layout pass.
        Task { [weak self] in self?.restyleStructuralParagraphs() }
    }

    private func restyleStructuralParagraphs() {
        guard let pending = staleStructuralRange else { return }
        staleStructuralRange = nil
        guard let storage = textStorage else { return }
        let clipped = NSIntersectionRange(pending, NSRange(location: 0, length: storage.length))
        guard clipped.length > 0 else { return }
        storage.edited(.editedAttributes, range: storage.mutableString.lineRange(for: clipped), changeInLength: 0)
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    /// TextKit doesn't redraw a fragment whose rendering attributes change. Redrawing only those whose runs differ cut
    /// typing CPU by 41%.
    func colour(from start: Int) {
        guard let manager = textLayoutManager else { return }
        staleColours = nil
        let line = document.lineStart(document.line(at: start))
        let stale = textRange(.caret(line)).flatMap { NSTextRange(location: $0.location, end: manager.documentRange.endLocation) }
        manager.invalidateRenderingAttributes(for: stale ?? manager.documentRange)
        // A fragment laid out but not shown keeps runs that may now be stale, so it's coloured again when it scrolls in.
        let shown = Set(fragments.map { ObjectIdentifier($0.fragment) })
        for case let fragment as NSTextLayoutFragment in fragmentColours.keyEnumerator().allObjects
        where !shown.contains(ObjectIdentifier(fragment)) {
            fragmentColours.removeObject(forKey: fragment)
        }
        let first = fragments.lastIndex { $0.offset <= line } ?? 0
        var changed: [CGRect] = []
        for (index, (_, fragment)) in fragments.enumerated().dropFirst(first) {
            let before = fragmentColours.object(forKey: fragment)
            manager.renderingAttributesValidator?(manager, fragment)
            // The edited fragment always: TextKit may have coloured it anew while laying it out.
            if index == first || before == nil || before != fragmentColours.object(forKey: fragment) {
                changed.append(fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            }
        }
        redrawFragments(in: changed)
    }

    func segments(_ marked: NSRange) -> CGRect? {
        guard NSMaxRange(marked) <= length, let manager = textLayoutManager, let range = textRange(marked) else { return nil }
        var rect = CGRect.null
        manager.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
            rect = rect.union(frame)
            return true
        }
        return rect.isNull ? nil : rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// TextKit draws each shown fragment in its own view, which neither new rendering attributes nor the text view's
    /// display redraw.
    func redrawFragments(in rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        func redraw(_ view: NSView) {
            let frame = view.convert(view.bounds, to: self)
            guard rects.contains(where: { $0.intersects(frame) }) else { return }
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        subviews.filter { !($0 is IssueMessageView) }.forEach(redraw)
    }

    func showPartner(of at: Int) {
        guard at >= 0, at < length, let i = document.partner(of: at) else { return }
        let range = NSRange(location: i, length: 1)
        guard let rect = segments(range), visibleRect.intersects(rect) else { return }
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return showFindIndicator(for: range) }
        mark(range)
    }

    func mark(_ range: NSRange?) {
        for rect in [partnerDrawn, range.flatMap(segments)] { if let rect { setNeedsDisplay(rect) } }
        (partnerMark, partnerDrawn) = (range, nil)
    }

    func drawPartner(in rect: NSRect) {
        partnerDrawn = partnerMark.flatMap(segments)
        guard let partnerDrawn, partnerDrawn.intersects(rect) else { return }
        NSColor.unemphasizedSelectedTextBackgroundColor.setFill()
        partnerDrawn.fill()
    }
}
