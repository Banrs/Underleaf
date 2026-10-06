import AppKit

/// Native TextKit 2 handles typing, undo and accessibility. `SourceDocument`
/// supplies LaTeX syntax; this view adds the gutter, colours, completion,
/// brackets and indentation, with core edits grouped into undo steps.
final class SourceTextView: NSTextView, NSTextStorageDelegate {
    /// A plain-text document view, as `scrollablePlainDocumentContentTextView` sets one up, to go
    /// in SwiftUI's scroll view: that is an NSScrollView underneath (27.2), so TextKit 2's viewport
    /// stays bounded by its clip and the scrolling code here finds it as `enclosingScrollView`.
    static func plainDocument() -> SourceTextView {
        let view = SourceTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.importsGraphics = false
        view.usesRuler = false
        view.allowsImageEditing = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        return view
    }

    /// The view has a new scroll view, or none (`SourceEditor` watches its scrolling). SwiftUI
    /// puts the view in its scroll view after its superview (27.2), so it's told as it's sized.
    var attached: () -> Void = {}
    private weak var attachedTo: NSScrollView?

    private func noteScrollView() {
        guard enclosingScrollView !== attachedTo else { return }
        attachedTo = enclosingScrollView
        attached()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        noteScrollView()
        reportContentHeight()
    }

    /// The height the text takes, as the view sizes itself to it by TextKit 2's estimates where it
    /// hasn't laid out, and at least what shows, so it takes clicks under a short document.
    /// SwiftUI's scroll view sizes it by this (`SourceColumn`), told through `heightChanged`:
    /// SwiftUI doesn't measure a representable again on its own.
    var heightChanged: (CGFloat) -> Void = { _ in }

    private var reportedHeight: CGFloat = 0, sizing = false

    func reportContentHeight() {
        guard !sizing else { return }
        sizing = true
        defer { sizing = false }
        if let clip = enclosingScrollView?.contentView {
            minSize = NSSize(width: 0, height: clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom)
        }
        sizeToFit()
        let height = frame.height
        guard height != reportedHeight else { return }
        reportedHeight = height
        heightChanged(height)
    }

    override func mouseMoved(with event: NSEvent) {
        if updateDividerCursor(with: event) { return }
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if !updateDividerCursor(with: event) { super.mouseEntered(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !updateDividerCursor(with: event) { super.cursorUpdate(with: event) }
    }

    /// The open file's text as the core mirrors it; every change reaches it.
    private(set) var document = SourceDocument(text: "")
    /// Only active IME composition needs a snapshot; ordinary edits and undo are live.
    private var beforeMarkedText: String?
    var committedString: String { hasMarkedText() ? beforeMarkedText ?? string : string }
    var symbols = Symbols(citations: [], labels: [])
    /// What dropping a file does, or nil to refuse it.
    var fileDrop: (URL) -> (() -> Void)? = { _ in nil }
    /// Go to PDF Position, or nil while there's no PDF or no TeX open.
    var forwardSync: () -> (() -> Void)? = { nil }

    /// The text is being replaced whole: no edit of the user's.
    private(set) var loading = false

    /// Replaces the text, which starts a new mirror; nothing to undo.
    func load(_ text: String) {
        loading = true
        // Typing coalesced into the last file's undo would go on in its.
        breakUndoCoalescing()
        fragments.removeAll(keepingCapacity: true)
        inputContext?.discardMarkedText()
        unmarkText()
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
        document = SourceDocument(text: text)
        lastMath = nil
        snippet = nil
        closers.removeAll()
        closeCompletions()
        updateGutterWidth()
        recolour()
        reportContentHeight()
    }

    // MARK: edits reach the core

    /// The range the text view is about to change; the storage's edited range runs past it.
    private var changing: NSRange?

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else { return false }
        changing = affectedRanges.count == 1 && replacementStrings != nil ? affectedRanges[0].rangeValue : nil
        return true
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !loading else { return }
        let old = NSRange(location: edited.location, length: edited.length - delta)
        document.edit(old, with: (textStorage.string as NSString).substring(with: edited))
        edits += 1
        // The fields follow the change itself, when it's the one expected.
        let changed = changing.flatMap { $0.location == old.location && NSMaxRange($0) <= NSMaxRange(old) ? $0 : nil }
        changing = nil
        follow(changed ?? old, delta)
        if lineCountDigits != digits(document.lineCount) {
            // After the edit: a layout change mid-edit would lay out stale text.
            Task { self.updateGutterWidth() }
        }
    }

    /// Apply core edits from the last in one undo step, remapping selection unless specified.
    func apply(_ edits: [TextEdit], named name: String, select: NSRange? = nil) {
        guard !edits.isEmpty else { return }
        let selections = selectedRanges.map(\.rangeValue)
        undoManager?.beginUndoGrouping()
        for edit in edits.reversed() {
            if shouldChangeText(in: edit.range, replacementString: edit.text) {
                textStorage?.replaceCharacters(in: edit.range, with: edit.text)
                didChangeText()
            }
        }
        undoManager?.setActionName(name)
        undoManager?.endUndoGrouping()
        if let select {
            setSelectedRange(select)
        } else {
            let map = { (p: Int) in Self.map(p, through: edits) }
            setSelectedRanges(selections.map { r in
                let start = map(r.location)
                return NSValue(range: NSRange(location: start, length: max(0, map(NSMaxRange(r)) - start)))
            }, affinity: .downstream, stillSelecting: false)
        }
        scrollRangeToVisible(selectedRange())
    }

    private static func map(_ position: Int, through edits: [TextEdit]) -> Int {
        var shift = 0
        for edit in edits {
            let inserted = (edit.text as NSString).length
            if NSMaxRange(edit.range) <= position {
                shift += inserted - edit.length
            } else if edit.start < position {
                return edit.start + shift + inserted
            }
        }
        return position + shift
    }

    // MARK: the colours

    /// Settings' Colour Theme.
    var syntaxTheme = SyntaxTheme.overleaf {
        didSet {
            guard syntaxTheme != oldValue else { return }
            recolour(redrawing: true)
        }
    }

    // MARK: the font

    /// Settings' size; the weight follows the appearance.
    var fontSize = NSFont.systemFontSize {
        didSet { applyFont() }
    }
    /// How far the current line's highlight sits below its line's top: the
    /// extra line height goes above the glyphs, Xcode centres them.
    private var rowShift: CGFloat = 0
    private var applied: NSFont?

    /// SF Mono as Xcode's Default themes give it, regular in Light and medium in
    /// Dark, its lines 1.1 times the font's (DVTLineSpacing) to whole points: 18 at 13.
    private func applyFont() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: dark ? .medium : .regular)
        guard font != applied else { return }
        let resized = applied?.pointSize != font.pointSize
        applied = font
        self.font = font
        typingAttributes[.font] = font
        // The weights share their metrics: an appearance change leaves the lines and gutter as they are.
        guard resized else { return }
        let natural = font.ascender.rounded(.up) - font.descender.rounded(.down) + font.leading
        let style = NSMutableParagraphStyle()
        // A minimum, so taller fallback glyphs and input methods still fit.
        style.minimumLineHeight = (natural * 1.1).rounded()
        rowShift = (style.minimumLineHeight - natural) / 2
        defaultParagraphStyle = style
        if let storage = textStorage {
            storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
        }
        typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style]
        // Xcode's numbers, measured: semi-condensed SF a point under the text, tabular.
        let numbers = NSFont.systemFont(ofSize: fontSize - 1, weight: .regular, width: NSFont.Width(rawValue: -0.1))
        numberFont = NSFont(descriptor: numbers.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector]]]), size: 0) ?? numbers
        gutterWidth = 0
        updateGutterWidth()
    }

    /// The colours are dynamic and the views redraw in the new appearance; only the weight changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFont()
    }

    // MARK: the gutter

    private var gutterWidth: CGFloat = 0
    private var lineCountDigits = 0
    private var numberFont = NSFont.systemFont(ofSize: NSFont.systemFontSize) {
        didSet {
            numberLines.removeAll()
            digitWidth = Self.digitWidth(numberFont)
        }
    }
    private lazy var digitWidth = Self.digitWidth(numberFont)
    private static func digitWidth(_ font: NSFont) -> CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
    /// Where the line numbers end.
    private var numbersEnd: CGFloat = 0
    /// The fragments laid out for the viewport: where each starts, its frame.
    private var fragments: [(offset: Int, fragment: NSTextLayoutFragment)] = []
    /// The lines the last build has issues on, true for an error: their numbers are marked.
    var issueLines: [Int: Bool] = [:] {
        didSet { if issueLines != oldValue { redrawLineAndGutter() } }
    }

    private func digits(_ n: Int) -> Int { max(4, String(n).count) }

    /// Xcode's, measured at 13 pt (2026-10-05): one width up to 9,999 lines, the numbers
    /// ending 19.5 pt plus three digits in, a digit more for each digit past four, and the
    /// text 11 pt after.
    func updateGutterWidth() {
        lineCountDigits = digits(document.lineCount)
        numbersEnd = 19.5 + CGFloat(lineCountDigits - 1) * digitWidth
        let width = numbersEnd + 11 - (textContainer?.lineFragmentPadding ?? 0)
        guard width != gutterWidth else { return }
        gutterWidth = width
        // Account for the gutter at the start and 8 pt at the end.
        textContainerInset.width = (textContainerOrigin.x + 8) / 2
        needsDisplay = true
    }

    /// TextKit supplies the line fragment's padding after the gutter.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: gutterWidth, y: textContainerInset.height)
    }

    // The top paragraph stays put: TextKit 2 keeps the offset, over heights a new width re-estimates (27.2).
    override func setFrameSize(_ size: NSSize) {
        noteScrollView()
        defer { reportContentHeight() }
        guard size.width != frame.width else { return super.setFrameSize(size) }
        keepingTopLine {
            super.setFrameSize(size)
            // As it goes: scrolled down, AppKit's tracking waits for a live resize's end (27.2).
            textContainer?.size.width = max(0, size.width - 2 * textContainerInset.width)
        }
        layOutViewportOnceSettled()
    }

    private var viewportPending = false

    /// Widths changing faster than a frame (a divider dragged quickly) can leave the viewport laid
    /// out for one of the passing widths, its text gone until it next scrolls (27.2): once they
    /// settle, TextKit lays the shown text out for the last.
    private func layOutViewportOnceSettled() {
        guard !viewportPending else { return }
        viewportPending = true
        Task { [weak self] in
            self?.viewportPending = false
            self?.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    private func keepingTopLine(_ change: () -> Void) {
        let top = shownTop
        change()
        top.map(scroll(toShownTop:))
    }

    /// The first paragraph showing below the bars, and how far its top is below the clip's.
    /// From the fragments last laid out: asked by point, TextKit answers from its new estimates.
    var shownTop: (offset: Int, below: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView,
              let top = fragments.first(where: { $0.fragment.layoutFragmentFrame.maxY + textContainerOrigin.y > clip.bounds.minY + clip.contentInsets.top })?.fragment
        else { return nil }
        return (offset(top.rangeInElement.location), top.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.minY)
    }

    /// Edit › Find › Jump to Selection: the selection's line in the middle of what shows below the
    /// bars. AppKit's own lands lines off where TextKit 2 has only estimated the heights above (27.2).
    override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let scrollView = enclosingScrollView, let manager = textLayoutManager,
              let location = textRange(NSRange(location: selectedRange().location, length: 0))?.location
        else { return super.centerSelectionInVisibleArea(sender) }
        let insets = scrollView.contentInsets
        let shown = scrollView.contentView.bounds.height - insets.top - insets.bottom
        scroll(location) { [unowned self] paragraph in
            guard let fragment = manager.textLayoutFragment(for: location) else { return paragraph.midY - insets.top - shown / 2 }
            let inParagraph = offset(location) - offset(fragment.rangeInElement.location)
            let line = fragment.textLineFragments.last { $0.characterRange.location <= inParagraph } ?? fragment.textLineFragments.first
            return paragraph.minY + (line?.typographicBounds.midY ?? paragraph.height / 2) - insets.top - shown / 2
        }
    }

    /// The caret's autoscroll as it moves or text is typed: SwiftUI's clip view takes no
    /// `scrollToVisible` from a view inside it (27.2), so the clip is scrolled here, the least
    /// that shows the rect between the bars.
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard let scroll = enclosingScrollView else { return super.scrollToVisible(rect) }
        let clip = scroll.contentView, insets = clip.contentInsets
        let target = convert(rect, to: clip)
        let shown = NSRect(x: clip.bounds.minX, y: clip.bounds.minY + insets.top, width: clip.bounds.width,
                           height: clip.bounds.height - insets.top - insets.bottom)
        var origin = clip.bounds.origin
        if target.minY < shown.minY { origin.y -= shown.minY - target.minY }
        else if target.maxY > shown.maxY { origin.y += min(target.maxY - shown.maxY, target.minY - shown.minY) }
        origin = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard origin != clip.bounds.origin else { return false }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }

    /// Laying the range out first: far from the viewport it has no rect yet, and TextKit 2's
    /// estimates above it settle as it's shown, so in two passes, as `scroll(_:to:)`.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let manager = textLayoutManager, enclosingScrollView != nil, let target = textRange(range)
        else { return super.scrollRangeToVisible(range) }
        for _ in 0..<2 {
            manager.ensureLayout(for: target)
            var rect = NSRect.null
            manager.enumerateTextSegments(in: target, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
                rect = rect.union(frame)
                return true
            }
            guard !rect.isNull else { return }
            guard scrollToVisible(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)) else { return }
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    /// Back to a `shownTop`.
    func scroll(toShownTop top: (offset: Int, below: CGFloat)) {
        guard let location = textRange(NSRange(location: min(top.offset, (string as NSString).length), length: 0))?.location else { return }
        scroll(location) { $0.minY - top.below }
    }

    /// Scrolls to where `y` puts the clip for the location's paragraph (its frame in the view),
    /// laying out only that paragraph, in two passes; only in a window (27.2).
    func scroll(_ location: any NSTextLocation, to y: (NSRect) -> CGFloat) {
        guard let manager = textLayoutManager, let scroll = enclosingScrollView, window != nil else { return }
        let clip = scroll.contentView
        for _ in 0..<2 {
            manager.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = manager.textLayoutFragment(for: location) else { return }
            let origin = NSPoint(x: 0, y: y(fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerOrigin.y)))
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    override func textViewportLayoutControllerWillLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerWillLayout(controller)
        fragments.removeAll(keepingCapacity: true)
    }

    override func textViewportLayoutController(_ controller: NSTextViewportLayoutController,
                                               configureRenderingSurfaceFor fragment: NSTextLayoutFragment) {
        super.textViewportLayoutController(controller, configureRenderingSurfaceFor: fragment)
        fragments.append((offset(fragment.rangeInElement.location), fragment))
    }

    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        fragments.sort { $0.offset < $1.offset }
        reportContentHeight()
        // Invalidated, the fragments laid out before keep no colours until validated again.
        if needsColours, let manager = textLayoutManager {
            needsColours = false
            for (_, fragment) in fragments { manager.renderingAttributesValidator?(manager, fragment) }
        }
        // Scrolled, it follows the text.
        if offered != nil { showCompletions(reload: false) }
        redrawLineAndGutter()
    }

    /// The document's last line when it's empty: TextKit lays it out as an extra line of the paragraph before.
    private func extraLine(of fragment: NSTextLayoutFragment) -> NSTextLineFragment? {
        let lines = fragment.textLineFragments
        guard lines.count > 1, let last = lines.last, last.characterRange.length == 0 else { return nil }
        return last
    }

    /// The current line's highlight, as Xcode's, measured: for a caret only, its paragraph
    /// from 14 pt to 8 pt from the right edge, with 4 pt corners round the line number.
    private var currentLine: (number: Int, rect: NSRect)? {
        let selection = selectedRange(), length = (string as NSString).length
        guard let entry = fragments.last(where: { $0.offset <= selection.location }) else { return nil }
        let end = offset(entry.fragment.rangeInElement.endLocation)
        guard selection.location < end || end == length else { return nil }
        let frame = entry.fragment.layoutFragmentFrame
        var lines = entry.fragment.textLineFragments[...]
        // The caret at the document's end is on the extra line, and elsewhere in the paragraph not.
        if extraLine(of: entry.fragment) != nil { lines = selection.location == length ? lines.suffix(1) : lines.dropLast() }
        let top = frame.minY + (lines.first?.typographicBounds.minY ?? 0)
        let bottom = frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height)
        return (document.line(at: selection.location),
                NSRect(x: 14, y: textContainerOrigin.y + top + rowShift, width: bounds.width - 22, height: bottom - top))
    }
    /// Where the highlight was last drawn.
    private var drawnLine: NSRect?

    /// Only what the caret and an edit change in the background: the numbers, and the current
    /// line where it was and is. The text draws in TextKit's own views.
    private func redrawLineAndGutter() {
        let shown = visibleRect
        setNeedsDisplay(NSRect(x: shown.minX, y: shown.minY, width: numbersEnd + 4 - shown.minX, height: shown.height))
        if let drawnLine { setNeedsDisplay(drawnLine) }
        if let rect = currentLine?.rect { setNeedsDisplay(rect) }
    }

    /// Typeset line numbers, drawn in the context's colour (`numberFont` resets them).
    private var numberLines: [Int: (line: CTLine, width: CGFloat)] = [:]

    private func numberLine(_ number: Int) -> (line: CTLine, width: CGFloat) {
        if let cached = numberLines[number] { return cached }
        if numberLines.count > 4096 { numberLines.removeAll(keepingCapacity: true) }
        let text = NSAttributedString(string: String(number), attributes: [
            .font: numberFont, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(text)
        let typeset = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        numberLines[number] = typeset
        return typeset
    }

    /// Draw the current line, and the numbers on each paragraph's first baseline.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let origin = textContainerOrigin
        let current = selectedRange().length == 0 ? currentLine : nil
        drawnLine = current?.rect
        if let current, current.rect.intersects(rect) {
            // Grey in Xcode 27 whatever its theme says, as the system's fill (measured, 2026-10-05).
            NSColor.secondarySystemFill.setFill()
            NSBezierPath(roundedRect: current.rect, xRadius: 4, yRadius: 4).fill()
        }
        guard rect.minX < numbersEnd + 4, let context = NSGraphicsContext.current?.cgContext else { return }
        // The current line's number as a label, the others tertiary, as Xcode's; the system
        // raises both for Increase Contrast.
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (offset, fragment) in fragments {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: origin.y)
            guard frame.maxY >= rect.minY, frame.minY <= rect.maxY, let line = fragment.textLineFragments.first else { continue }
            let lineNumber = document.line(at: offset), issue = issueLines[lineNumber]
            if let issue {
                // The number on the issue's colour, in the highlight's shape and place.
                (issue ? NSColor.systemRed : .systemYellow).withAlphaComponent(0.3).setFill()
                let bounds = line.typographicBounds
                NSBezierPath(roundedRect: NSRect(x: 14, y: frame.minY + bounds.minY + rowShift, width: numbersEnd - 10, height: bounds.height),
                             xRadius: 4, yRadius: 4).fill()
            }
            func draw(_ lineNumber: Int, on line: NSTextLineFragment) {
                (lineNumber == current?.number || issueLines[lineNumber] != nil ? NSColor.labelColor : .tertiaryLabelColor).setFill()
                let number = numberLine(lineNumber)
                context.textPosition = CGPoint(x: numbersEnd - number.width, y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                CTLineDraw(number.line, context)
            }
            draw(lineNumber, on: line)
            if let extra = extraLine(of: fragment) { draw(lineNumber + 1, on: extra) }
        }
    }

    // MARK: colours

    /// The shown fragments' colours were invalidated (`recolour`).
    private var needsColours = false

    /// TextKit validates colours when it renders a fragment, without editing the
    /// document's attributes or disturbing its estimated scroll geometry.
    private func recolour(redrawing: Bool = false) {
        guard let manager = textLayoutManager else { return }
        if manager.renderingAttributesValidator == nil {
            manager.renderingAttributesValidator = { [weak self] manager, fragment in
                guard let self else { return }
                let range = fragment.rangeInElement
                let start = offset(range.location), end = offset(range.endLocation)
                manager.setRenderingAttributes([.foregroundColor: NSColor.textColor], for: range)
                for run in document.highlights(in: NSRange(location: start, length: end - start)) {
                    let clipped = NSIntersectionRange(run.range, NSRange(location: start, length: end - start))
                    if clipped.length > 0, let range = textRange(clipped) {
                        manager.setRenderingAttributes([.foregroundColor: run.kind.color(in: syntaxTheme)], for: range)
                    }
                }
            }
        }
        manager.invalidateRenderingAttributes(for: manager.documentRange)
        // TextKit validates only the fragments it lays out anew; the rest, after the next layout.
        needsColours = true
        needsLayout = true
        if redrawing {
            for (_, fragment) in fragments { manager.renderingAttributesValidator?(manager, fragment) }
            // Each shown fragment draws in a view of its own, which new rendering attributes don't
            // redraw, nor does the text view's own display (27.2).
            func redraw(_ view: NSView) {
                view.needsDisplay = true
                view.subviews.forEach(redraw)
            }
            redraw(self)
        }
    }

    // MARK: the selection

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !loading else { return }
        if !typing { closeCompletions() }
        previewMath()
        if let snippet, !mirroring, !snippet.contains(selectedRange()) { self.snippet = nil }
        let lineStart = (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
        closers = closers.filter { $0 >= lineStart }
        redrawLineAndGutter()
    }

    override func becomeFirstResponder() -> Bool {
        // Once the window has made it first responder.
        defer { Task { self.previewMath() } }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer {
            mathPopover?.close()
            closeCompletions()
        }
        return super.resignFirstResponder()
    }

    /// Its window's key changes (`keyChanged`).
    private var keyWatches: [NotificationCenter.ObservationToken] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyWatches.forEach { NotificationCenter.default.removeObserver($0) }
        keyWatches = []
        guard let window else { return }
        keyWatches = [
            NotificationCenter.default.addObserver(of: window, for: .didBecomeKey) { [weak self] _ in self?.keyChanged() },
            NotificationCenter.default.addObserver(of: window, for: .didResignKey) { [weak self] _ in self?.keyChanged() },
        ]
    }

    deinit {
        keyWatches.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// The background draws the same with and without the keyboard: only these follow it.
    private func keyChanged() {
        if !hasKeyboard { closeCompletions() }
        previewMath()
    }

    private var hasKeyboard: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    // MARK: the maths preview

    private var mathPopover: MathPopover?
    /// The core's answer for a caret and text (`edits` counts the text's changes): scrolling,
    /// focus and completions ask again for the same, and only its place changes.
    private var lastMath: (caret: Int, edits: Int, value: MathPreview?)?
    private var edits = 0

    private func math(at caret: Int) -> MathPreview? {
        if let lastMath, lastMath.caret == caret, lastMath.edits == edits { return lastMath.value }
        let value = document.mathAt(caret: caret)
        lastMath = (caret, edits, value)
        return value
    }

    /// Preview maths at the caret only while the caret is visible and focused:
    /// over its line, as Overleaf's, or under it while completions show over it.
    func previewMath() {
        guard let window, hasKeyboard, !loading,
              let maths = math(at: selectedRange().location),
              let clip = enclosingScrollView?.contentView else {
            mathPopover?.close()
            return
        }
        let screen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        // A point wide: NSPopover takes an empty rect for the whole view.
        var rect = convert(window.convertFromScreen(screen), from: nil)
        rect.size.width = max(rect.width, 1)
        // Below the toolbar and the find bar, and above the scroll view's foot.
        let insets = enclosingScrollView?.contentInsets ?? NSEdgeInsetsZero
        var shown = convert(clip.bounds, from: clip)
        shown.origin.y += insets.top
        shown.size.height -= insets.top + insets.bottom
        guard shown.contains(NSPoint(x: rect.minX, y: rect.midY)) else {
            mathPopover?.close()
            return
        }
        if mathPopover == nil { mathPopover = MathPopover() }
        mathPopover?.show(maths, size: fontSize, at: rect, of: self,
                          edge: offered != nil && completionList.isAbove ? .maxY : .minY)
    }

    /// The character at a UTF-16 offset, if there's one there.
    private func character(at i: Int) -> Character? {
        let text = string as NSString
        guard i >= 0, i < text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: i)).first
    }

    /// Where the bracket at `at` is matched, within 10,000 UTF-16 units. Brackets are ASCII,
    /// so code units compare exactly.
    private func partner(of at: Int) -> Int? {
        let text = string as NSString
        guard at >= 0, at < text.length, let c = Unicode.Scalar(text.character(at: at)).map(Character.init) else { return nil }
        let close = Self.pairs[c], open = Self.pairs.first { $0.value == c }?.key
        guard let other = (close ?? open)?.utf16.first, let unit = c.utf16.first else { return nil }
        var depth = 0, i = at
        while abs(i - at) <= 10_000, i >= 0, i < text.length {
            let d = text.character(at: i)
            if d == unit { depth += 1 } else if d == other { depth -= 1 }
            if depth == 0 { return i }
            i += close != nil ? 1 : -1
        }
        return nil
    }

    /// As Xcode: typing a bracket, or moving the caret over one, shows its
    /// partner for a moment, when that's on screen.
    private func showPartner(of at: Int) {
        guard let i = partner(of: at), let first = fragments.first, let last = fragments.last,
              first.offset <= i, i < offset(last.fragment.rangeInElement.endLocation) else { return }
        showFindIndicator(for: NSRange(location: i, length: 1))
    }

    override func moveRight(_ sender: Any?) {
        let before = selectedRange()
        super.moveRight(sender)
        if before.length == 0, selectedRange() == NSRange(location: before.location + 1, length: 0) { showPartner(of: before.location) }
    }

    override func moveLeft(_ sender: Any?) {
        let before = selectedRange()
        super.moveLeft(sender)
        if before.length == 0, selectedRange() == NSRange(location: before.location - 1, length: 0) { showPartner(of: before.location - 1) }
    }

    // MARK: typing

    /// Closing brackets this view put in, which typing one steps over.
    private var closers: Set<Int> = []
    /// Auto-close an opening bracket before these characters.
    private static let closeBefore: Set<Character> = [")", "]", "}", ":", ";", ">"]

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() { beforeMarkedText = self.string }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if !hasMarkedText() { beforeMarkedText = nil }
    }

    override func unmarkText() {
        super.unmarkText()
        beforeMarkedText = nil
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasTyping = typing
        typing = true
        defer {
            typing = wasTyping
            if !hasMarkedText() { beforeMarkedText = nil }
        }
        guard let typed = string as? String, typed.count == 1, let c = typed.first,
              replacementRange.location == NSNotFound, !hasMarkedText(), selectedRanges.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            closeCompletions()
            return
        }
        let selection = selectedRange()
        let text = self.string as NSString
        let next = character(at: selection.location)
        if selection.length == 0, Self.pairs.values.contains(c), next == c, closers.contains(selection.location) {
            closers.remove(selection.location)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            showPartner(of: selection.location)
            return
        }
        if let close = Self.pairs[c] {
            if selection.length > 0 {
                super.insertText("\(c)\(text.substring(with: selection))\(close)", replacementRange: selection)
                closers.insert(NSMaxRange(selection) + 1)
                setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
                return
            }
            if next.map({ $0.isWhitespace || Self.closeBefore.contains($0) }) ?? true {
                super.insertText("\(c)\(close)", replacementRange: selection)
                closers.insert(selection.location + 1)
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                offerCompletions()
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
        if Self.pairs.values.contains(c) { showPartner(of: selectedRange().location - 1) }
        offerCompletions()
    }

    /// Delete an empty bracket pair or backspace to the last indent stop;
    /// an open completion list filters again.
    override func deleteBackward(_ sender: Any?) {
        let wasTyping = typing, completing = offered != nil
        typing = true
        defer {
            typing = wasTyping
            if completing { offerCompletions() }
        }
        let selection = selectedRange(), text = string as NSString
        guard selection.length == 0, selection.location > 0, selectedRanges.count == 1 else { return super.deleteBackward(sender) }
        let caret = selection.location
        if let before = character(at: caret - 1), let close = Self.pairs[before], character(at: caret) == close {
            insertText("", replacementRange: NSRange(location: caret - 1, length: 2))
            return
        }
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let indent = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        if !indent.isEmpty, indent.allSatisfy({ $0 == " " }) {
            let drop = indent.count % 2 == 0 ? 2 : 1
            insertText("", replacementRange: NSRange(location: caret - drop, length: drop))
            return
        }
        super.deleteBackward(sender)
    }

    /// Keep indentation on a new line; move an empty pair's closer down one line.
    override func insertNewline(_ sender: Any?) {
        guard selectedRanges.count == 1 else { return super.insertNewline(sender) }
        let text = string as NSString
        var range = selectedRange()
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = text.substring(with: line).trimmingCharacters(in: .newlines)
        let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
        let lineEnd = line.location + (lineText as NSString).length
        let between = range.length == 0 && range.location > 0 && range.location < text.length
            && ["()", "[]", "{}"].contains(text.substring(with: NSRange(location: range.location - 1, length: 2)))
        var insert = "\n" + indent
        if between {
            insert += "\n" + indent
        } else {
            // The spaces after the caret go; a caret in the indentation moves it down.
            while NSMaxRange(range) < lineEnd, text.substring(with: NSRange(location: NSMaxRange(range), length: 1)) == " " {
                range.length += 1
            }
            if range.location > line.location, text.substring(with: NSRange(location: line.location, length: range.location - line.location)).allSatisfy(\.isWhitespace) {
                range = NSRange(location: line.location, length: NSMaxRange(range) - line.location)
            }
        }
        insertText(insert, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + 1 + (indent as NSString).length, length: 0))
    }

    override func insertTab(_ sender: Any?) {
        if snippet != nil { return moveField(1) }
        indent(by: 1)
    }

    override func insertBacktab(_ sender: Any?) {
        if snippet != nil { return moveField(-1) }
        indent(by: -1)
    }

    private func indent(by direction: Int) {
        let edits = document.indent(selectedRanges.map(\.rangeValue), more: direction > 0)
        apply(edits, named: direction > 0 ? String(localized: "Indent") : String(localized: "Outdent"))
    }

    /// Kept for the next file and launch, as a setting.
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        EditorPrefs.spellCheck = isContinuousSpellCheckingEnabled
    }

    override func cancelOperation(_ sender: Any?) {
        if snippet != nil {
            snippet = nil
            return
        }
        // NSTextView doesn't implement it, so super would throw; pass it on as NSResponder would
        // have (the window's, which leaves full screen).
        nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
    }

    // MARK: completion: the core's items in a list under the caret

    /// What the list offers, while it's open; the document keeps the keyboard.
    private(set) var offered: Completions?
    private lazy var completionList: CompletionList = {
        let list = CompletionList()
        list.clicked = { [unowned self] in acceptCompletion($0) }
        return list
    }()
    /// Typing filters the open list; any other selection change closes it.
    private var typing = false

    private var caret: Int { selectedRange().location }

    /// Offer core completions after typing when the caret has candidates.
    private func offerCompletions() { complete(explicit: false) }

    override func complete(_ sender: Any?) { complete(explicit: true) }

    private func complete(explicit: Bool) {
        guard selectedRange().length == 0, selectedRanges.count == 1, !hasMarkedText(),
              let found = document.completions(caret: caret, explicit: explicit, symbols: symbols) else {
            return closeCompletions()
        }
        offered = found
        showCompletions(reload: true)
    }

    func closeCompletions() {
        guard offered != nil else { return }
        offered = nil
        completionList.close()
    }

    /// Under the typed text's start while its line shows, or closed. Without a
    /// window it holds its items unseen, as the tests use it.
    private func showCompletions(reload: Bool) {
        guard let offered else { return }
        var start = NSRect.zero, host: NSWindow?
        if let window, let clip = enclosingScrollView?.contentView {
            host = window
            start = firstRect(forCharacterRange: NSRange(location: offered.start, length: 0), actualRange: nil)
            let insets = enclosingScrollView?.contentInsets ?? NSEdgeInsetsZero
            var shown = window.convertToScreen(clip.convert(clip.bounds, to: nil))
            shown.origin.y += insets.bottom
            shown.size.height -= insets.top + insets.bottom
            guard shown.contains(NSPoint(x: start.minX, y: start.midY)) else { return closeCompletions() }
            guard reload else { return completionList.place(under: start) }
        }
        let rows = offered.items.map { item -> (label: String, kind: CompletionKind) in
            let kind: CompletionKind = item.label.hasPrefix("\\") ? .command
                : item.label.hasPrefix("@") ? .entryType
                : symbols.citations.contains(item.label) ? .citation
                : symbols.labels.contains(item.label) ? .label : .environment
            return (item.label, kind)
        }
        completionList.show(rows, font: font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                            theme: syntaxTheme, under: start, in: host)
        // Out of the list's way.
        if host != nil { previewMath() }
    }

    /// Arrows move through the open list, Return and Tab accept, Escape closes it.
    override func doCommand(by selector: Selector) {
        guard offered != nil else { return super.doCommand(by: selector) }
        switch selector {
        case #selector(moveUp(_:)): completionList.move(-1)
        case #selector(moveDown(_:)): completionList.move(1)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)): acceptCompletion(completionList.selection)
        case #selector(cancelOperation(_:)): closeCompletions()
        default: super.doCommand(by: selector)
        }
    }

    /// Only a chosen completion goes in, replacing what's typed of it.
    private func acceptCompletion(_ index: Int) {
        guard let offered, offered.items.indices.contains(index), caret >= offered.start else { return closeCompletions() }
        let item = offered.items[index]
        closeCompletions()
        insertText(item.text, replacementRange: NSRange(location: offered.start, length: caret - offered.start))
        startSnippet(item.fields, at: offered.start)
    }

    // MARK: snippet fields

    /// Fields with the same index are one field in several places.
    private struct Snippet {
        var fields: [(index: Int, range: NSRange)]
        var active: Int

        func contains(_ selection: NSRange) -> Bool {
            fields.contains { $0.range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.range) }
        }

        var typed: NSRange? { fields.first { $0.index == active }?.range }
    }

    private var snippet: Snippet?
    private var mirroring = false
    private var needsMirror = false

    func startSnippet(_ fields: [SnippetField], at location: Int) {
        let fields = fields.map { (index: $0.index, range: NSRange(location: location + $0.start, length: $0.length)) }
        guard let first = fields.first(where: { $0.index == 0 }) else { return }
        // A session only while there's somewhere to Tab to, or a field in two places.
        snippet = fields.count > 1 ? Snippet(fields: fields, active: 0) : nil
        setSelectedRange(first.range)
    }

    private func moveField(_ step: Int) {
        guard var snippet else { return }
        let next = snippet.active + step
        guard let field = snippet.fields.first(where: { $0.index == next }) else { return }
        snippet.active = next
        let last = snippet.fields.allSatisfy { $0.index <= next }
        self.snippet = last ? nil : snippet
        setSelectedRange(field.range)
    }

    /// Follows an edit: the fields move with the text, the one typed in
    /// grows, and an edit anywhere else ends the session.
    private func follow(_ old: NSRange, _ delta: Int) {
        closers = Set(closers.compactMap { p in
            p >= NSMaxRange(old) ? p + delta : (p < old.location ? p : nil)
        })
        guard var snippet else { return }
        let inField = { (r: NSRange) in r.location <= old.location && NSMaxRange(old) <= NSMaxRange(r) }
        if !mirroring {
            guard let typed = snippet.typed, inField(typed) else {
                self.snippet = nil
                return
            }
            needsMirror = snippet.fields.filter { $0.index == snippet.active }.count > 1
        }
        for i in snippet.fields.indices {
            let r = snippet.fields[i].range
            if inField(r) && (mirroring || r == snippet.typed) {
                snippet.fields[i].range.length += delta
            } else if r.location >= NSMaxRange(old) {
                snippet.fields[i].range.location += delta
            }
        }
        self.snippet = snippet
    }

    /// What's typed in a field goes in its other places too, in the same undo step.
    override func didChangeText() {
        super.didChangeText()
        // The lines an edit made show their colours: their first layout drops them.
        defer { recolour() }
        guard needsMirror, !mirroring, let snippet, let typed = snippet.typed else { return }
        needsMirror = false
        let text = (string as NSString).substring(with: typed)
        let selection = selectedRange()
        mirroring = true
        for field in snippet.fields.reversed() where field.index == snippet.active && field.range != typed {
            // Looked up again: each replacement moves the fields after it.
            guard let range = self.snippet?.fields.first(where: { $0.index == field.index && $0.range.location == field.range.location })?.range,
                  shouldChangeText(in: range, replacementString: text) else { continue }
            textStorage?.replaceCharacters(in: range, with: text)
            super.didChangeText()
        }
        mirroring = false
        setSelectedRange(selection)
    }

    /// A double-click goes to the PDF, as one in the PDF comes here.
    override func mouseDown(with event: NSEvent) {
        // Let AppKit select the word before SyncTeX reads the source position.
        super.mouseDown(with: event)
        if event.type == .leftMouseDown, event.clickCount == 2 { forwardSync()?() }
    }

    // MARK: file drops open

    private func files(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Nil for a drag without files, which is the text view's.
    private func fileOperation(_ info: any NSDraggingInfo) -> NSDragOperation? {
        let files = files(info)
        guard !files.isEmpty else { return nil }
        guard files.contains(where: { fileDrop($0) != nil }) else { return [] }
        return info.draggingSourceOperationMask.contains(.generic) ? .generic : .copy
    }

    override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation {
        fileOperation(info) ?? super.draggingEntered(info)
    }

    override func draggingUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
        fileOperation(info) ?? super.draggingUpdated(info)
    }

    override func performDragOperation(_ info: any NSDraggingInfo) -> Bool {
        let files = files(info)
        guard !files.isEmpty else { return super.performDragOperation(info) }
        guard let drop = files.lazy.compactMap(fileDrop).first else { return false }
        drop()
        return true
    }

    // MARK: offsets

    func offset(_ location: any NSTextLocation) -> Int {
        guard let storage = textContentStorage else { return 0 }
        return storage.offset(from: storage.documentRange.location, to: location)
    }

    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let storage = textContentStorage, let start = storage.location(storage.documentRange.location, offsetBy: range.location),
              let end = storage.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

/// The editor's syntax colours: Settings' Colour Theme. Text, braces and brackets are plain in all of them.
enum SyntaxTheme: String, CaseIterable, Identifiable {
    case overleaf, texstudio, system

    var id: Self { self }

    var title: String {
        switch self {
        case .overleaf: "Overleaf"
        case .texstudio: "TeXstudio"
        case .system: "System"
        }
    }

    struct Colours {
        /// `\command`, `\begin`, `\end`, escapes.
        let command: NSColor
        /// `\documentclass`, `\cite` and the like; for now only BibTeX's `@article` badge.
        let keyword: NSColor
        /// Environment, label, reference, citation, file and package-option names.
        let argument: NSColor
        /// Maths' delimiters and what is in it, verbatim.
        let maths: NSColor
        let comment: NSColor
        /// Foreground only: a stray brace, what maths can't hold.
        let invalid: NSColor
    }

    var colours: Colours {
        switch self {
        case .overleaf: Self.overleafColours
        case .texstudio: Self.texstudioColours
        case .system: Self.systemColours
        }
    }

    /// With Increase Contrast, each raised to WCAG's enhanced 7:1 on the text's background: the
    /// themes' own colours fall short of the HIG's 4.5:1 in places (Overleaf's comments, 4.2:1).
    private static func rgb(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func srgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let light = srgb(light), dark = srgb(dark)
        let raised = (light: light.contrasting(in: .aqua, by: 7), dark: dark.contrasting(in: .darkAqua, by: 7))
        return NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: raised.light
            case .accessibilityHighContrastDarkAqua: raised.dark
            default: light
            }
        }
    }

    /// Overleaf's source editor themes (services/web/frontend/js/features/source-editor/themes/cm6/): "textmate",
    /// its default, in Light and "overleaf_dark" in Dark, with the lezer tags extensions/class-highlighter.ts and
    /// languages/latex/latex-language.ts give LaTeX's nodes. Its text is black / #F8F8F2.
    /// command: .tok-typeName (`\command`, `\begin`, `\end`), italic in Dark here only; keyword: .tok-keyword
    /// (`\documentclass`, `\cite`, `\ref`, `\label`, `~`, `&`, `\\`; BibTeX's `@article`); argument: .tok-attributeValue,
    /// italic in Dark; maths: .tok-string; comment: .tok-comment; invalid: .tok-invalid, which Dark fills behind
    /// #F8F8F0 text and Light tints behind at 10%.
    private static let overleafColours = Colours(
        command: rgb(0x0000FF, 0x8BE9FD), keyword: rgb(0x0000FF, 0xFF79C6), argument: rgb(0x318495, 0xFFB86C),
        maths: rgb(0x036A07, 0xF1FA8C), comment: rgb(0x4C886B, 0x6272A4), invalid: rgb(0xFF0000, 0xFF79C6))

    /// TeXstudio's own formats, utilities/qxs/defaultFormats.qxf (Light) and defaultFormatsDark.qxf (Dark), with
    /// which format the LaTeX highlighter gives what from utilities/qxs/tex.qnfa and samples/colortest.tex.
    /// command: "keyword"; keyword: "extra-keyword" (bold there), TeXstudio's `\begin`, `\end` and sectioning;
    /// argument: "referencePresent", "citationPresent" and "packagePresent", which are one colour (its environment
    /// names are #000080 / #60CDF2, which Dark shares with its commands); maths: "math-delimiter";
    /// comment: "comment"; invalid: "braceMismatch", which fills #C00000 behind #FFFF7F text in Light and #8D0B0B
    /// behind #F2F218 in Dark; the fill is not drawn here, so Light takes the fill and Dark the text.
    private static let texstudioColours = Colours(
        command: rgb(0x800000, 0x60CDF2), keyword: rgb(0x0095FF, 0xA960F2), argument: rgb(0x008000, 0x60F260),
        maths: rgb(0x509600, 0x85F218), comment: rgb(0x808080, 0x667299), invalid: rgb(0xC00000, 0xF2F218))

    /// The system's colours, which follow the accent and appearance; what the editor used before Overleaf's.
    private static let systemColours = Colours(
        command: .systemPink, keyword: .systemBrown, argument: .systemTeal,
        maths: .systemPurple, comment: .secondaryLabelColor, invalid: .systemRed)
}

private extension HighlightKind {
    func color(in theme: SyntaxTheme) -> NSColor {
        let colours = theme.colours
        return switch self {
        case .command: colours.command
        case .argument, .builtin: colours.argument
        case .mathDelimiter, .mathIdentifier, .number, .stringLiteral: colours.maths
        case .comment: colours.comment
        case .invalid: colours.invalid
        }
    }
}
