import AppKit

/// Native TextKit 2 handles typing, undo and accessibility. `SourceDocument`
/// supplies LaTeX syntax; this view adds the gutter, colours, completion,
/// brackets and indentation, with core edits grouped into undo steps.
final class SourceTextView: NSTextView, NSTextStorageDelegate, NSAccessibilityCustomRotorItemSearchDelegate {
    /// A plain-text document view for a scroll view, as `scrollablePlainDocumentContentTextView` sets one up.
    /// A new text view already takes no graphics, grows downwards only, has no least size and a container
    /// that follows its width (27.2), which `aPlainDocumentIsSetUpForAScrollView` checks.
    static func plainDocument() -> SourceTextView {
        let view = SourceTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.usesRuler = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // Its own storage's delegate: every edit reaches the core's mirror through it.
        view.textStorage?.delegate = view
        NSWorkspace.shared.notificationCenter.addObserver(view, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        return view
    }

    /// One of the display's accessibility options changed: the line numbers, the issues' messages
    /// and the completion list's rows follow Increase Contrast.
    @objc private func displayOptionsChanged() {
        needsDisplay = true
        for issue in issueRows { issue.message?.view.needsDisplay = true }
        if offered != nil { completionList.restyle() }
    }

    /// The pointer is the split divider's by it and the arrow over the gutter, where a click
    /// selects lines, and over an issue's message, where one shows the issue; elsewhere the text
    /// view sets its own, on every move.
    private func setsCursor(with event: NSEvent) -> Bool {
        if updateDividerCursor(with: event) { return true }
        guard inGutter(event) || issueMessage(at: event) != nil else { return false }
        NSCursor.arrow.set()
        return true
    }

    private func inGutter(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return visibleRect.contains(point) && point.x < textContainerOrigin.x
    }

    override func mouseMoved(with event: NSEvent) {
        if !setsCursor(with: event) { super.mouseMoved(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        if !setsCursor(with: event) { super.mouseEntered(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !setsCursor(with: event) { super.cursorUpdate(with: event) }
    }

    /// The open file's text as the core mirrors it; every change reaches it.
    private(set) var document = SourceDocument(text: "")
    /// Only active IME composition needs a snapshot; ordinary edits and undo are live.
    private var beforeMarkedText: String?
    var committedString: String { hasMarkedText() ? beforeMarkedText ?? string : string }
    /// The storage's own UTF-16 units, read in place: `string` bridges the whole text to a Swift
    /// string each time it's asked, and a caret move, a key and a draw all ask.
    private var text: NSString { textStorage?.mutableString ?? "" }
    var symbols = Symbols(citations: [], labels: [])
    /// What dropping a file does, or nil to refuse it.
    var fileDrop: (URL) -> FileDrop? = { _ in nil }

    enum FileDrop {
        case open(() -> Void)
        /// LaTeX to put in where it's dropped: a figure's `\includegraphics`.
        case insert(String)
    }
    /// Each edit as it is made, for live preview: the range of the text before it, and what replaced it.
    var textEdited: (NSRange, String) -> Void = { _, _ in }
    /// Go to PDF Position, or nil while there's no PDF or no TeX open. Asked quietly, it says
    /// nothing where the PDF has no such place.
    var forwardSync: (_ quietly: Bool) -> (() -> Void)? = { _ in nil }

    /// The text is being replaced whole: no edit of the user's.
    private(set) var loading = false

    /// Replaces the text, which starts a new mirror; nothing to undo.
    func load(_ text: String) {
        loading = true
        // Typing coalesced into the last file's undo would go on in its.
        breakUndoCoalescing()
        fragments.removeAll(keepingCapacity: true)
        placeIssues()
        inputContext?.discardMarkedText()
        unmarkText()
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
        document = SourceDocument(text: text)
        lastMath = nil
        dismissedMath = nil
        snippet = nil
        closers.removeAll()
        closeCompletions()
        updateGutterWidth()
        staleColours = 0
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
        let text = textStorage.mutableString.substring(with: edited)
        document.edit(old, with: text)
        textEdited(old, text)
        edits += 1
        staleColours = min(staleColours ?? edited.location, edited.location)
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
            setSelectedRanges(selections.map { r in
                let start = Self.map(r.location, through: edits)
                return NSValue(range: NSRange(location: start, length: max(0, Self.map(NSMaxRange(r), through: edits) - start)))
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

    // MARK: the font

    /// Settings' size; the weight follows the appearance.
    var fontSize = NSFont.systemFontSize {
        didSet { applyFont() }
    }
    /// Settings' fixed-pitch family; empty, the system's monospaced font.
    var fontName = "" {
        didSet { if fontName != oldValue { applyFont() } }
    }
    /// How far the current line's highlight sits below its line's top: the
    /// extra line height goes above the glyphs, Xcode centres them.
    private var rowShift: CGFloat = 0
    private var applied: NSFont?

    /// SF Mono as Xcode's Default themes give it, regular in Light and medium in
    /// Dark, or the family chosen in Settings; its lines 1.1 times the font's
    /// (DVTLineSpacing) to whole points: 18 at 13.
    private func applyFont() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let chosen = fontName.isEmpty ? nil : NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: fontSize)
        let font = chosen ?? .monospacedSystemFont(ofSize: fontSize, weight: dark ? .medium : .regular)
        guard font != applied else { return }
        let resized = applied?.pointSize != font.pointSize || applied?.familyName != font.familyName
        applied = font
        // The issues are placed again once all here is the new font's and the text is laid out in it.
        defer {
            issuesStale = true
            if !issueLines.isEmpty { layOutViewportOnceSettled() }
        }
        self.font = font
        typingAttributes[.font] = font
        // The system font's weights share their metrics: an appearance change leaves the lines and gutter as they are.
        guard resized else { return }
        let natural = font.ascender.rounded(.up) - font.descender.rounded(.down) + font.leading
        let style = NSMutableParagraphStyle()
        // A minimum, so taller fallback glyphs and input methods still fit.
        style.minimumLineHeight = (natural * 1.1).rounded()
        rowShift = (style.minimumLineHeight - natural) / 2
        defaultParagraphStyle = style
        textStorage?.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style]
        // Xcode's numbers as near as the system font's faces come: semi-condensed SF (a width of -0.1,
        // between the SDK's condensed and standard) a point under the text, tabular, a digit 6.7 pt
        // wide at 12. Xcode 27.1's own are 6.25 pt apart and a little taller (its capture,
        // 2026-10-12), which the condensed face matches worse at every size. Never under the 10
        // points the HIG gives as the Mac's smallest text.
        let numbers = NSFont.systemFont(ofSize: max(10, fontSize - 1), weight: .regular, width: NSFont.Width(rawValue: -0.1))
        numberFont = NSFont(descriptor: numbers.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector]]]), size: 0) ?? numbers
        // An issue's message in the system font, as Xcode's, a point under the text as the numbers are.
        issueFont = .systemFont(ofSize: max(10, fontSize - 1))
        issueGap = 3 * ("0" as NSString).size(withAttributes: [.font: font]).width
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
        didSet { numberLines.removeAll() }
    }
    /// The numbers are tabular: every digit is this wide.
    private var digitWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: numberFont]).width }
    /// Where the line numbers end.
    private var numbersEnd: CGFloat = 0
    /// The fragments laid out for the viewport: where each starts, its frame.
    private var fragments: [(offset: Int, fragment: NSTextLayoutFragment)] = []
    /// The lines the last build has issues on, true for an error: each is marked in the gutter
    /// and banded, with what its issue says at its end.
    var issueLines: [Int: Bool] = [:] {
        didSet { if issueLines != oldValue { issuesChanged() } }
    }
    /// What the issue on each of those lines says, for the line's end and the Issues rotor; a line
    /// without is named by its kind alone.
    var issueMessages: [Int: String] = [:] {
        didSet { if issueMessages != oldValue { issuesChanged() } }
    }
    /// What a line's other issues say, where it has more than the one in `issueMessages`: they are
    /// counted after its message.
    var issueOthers: [Int: [String]] = [:] {
        didSet { if issueOthers != oldValue { issuesChanged() } }
    }
    /// A click on a marked line's gutter or on its message: the build panel shows the issue.
    var issueClicked: (Int) -> Void = { _ in }
    /// The build panel's symbols, an error's and a warning's, at the smallest text style's 10 pt
    /// to fit the gutter's 14 pt margin.
    private static let issueSymbols = [true: "xmark.octagon.fill", false: "exclamationmark.triangle.fill"].compactMapValues {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(textStyle: .caption1).applying(.preferringMulticolor()))
    }

    /// Settings' Show Line Numbers. Off, the gutter is a margin that keeps the issues' marks.
    var showsLineNumbers = true {
        didSet { if showsLineNumbers != oldValue { updateGutterWidth() } }
    }

    private func digits(_ n: Int) -> Int { max(4, String(n).count) }

    /// Xcode's, measured at 13 pt (2026-10-05): one width up to 9,999 lines, the numbers
    /// ending 19.5 pt plus three digits in, a digit more for each digit past four, and the
    /// text 11 pt after.
    func updateGutterWidth() {
        lineCountDigits = digits(document.lineCount)
        numbersEnd = showsLineNumbers ? 19.5 + CGFloat(lineCountDigits - 1) * digitWidth : 14
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
        guard size.width != frame.width else { return super.setFrameSize(size) }
        let top = shownTop
        super.setFrameSize(size)
        // As it goes: scrolled down, AppKit's tracking waits for a live resize's end (27.2).
        textContainer?.size.width = max(0, size.width - 2 * textContainerInset.width)
        top.map(scroll(toShownTop:))
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
        guard let location = textRange(NSRange(location: min(top.offset, text.length), length: 0))?.location else { return }
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
        if let from = staleColours { colour(from: from) }
        // Scrolled, it follows the text.
        if offered != nil { showCompletions(reload: false) }
        placeIssues()
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
        let selection = selectedRange(), length = text.length
        guard let entry = fragments.last(where: { $0.offset <= selection.location }) else { return nil }
        let end = offset(entry.fragment.rangeInElement.endLocation)
        guard selection.location < end || end == length else { return nil }
        var lines = entry.fragment.textLineFragments[...]
        // The caret at the document's end is on the extra line, and elsewhere in the paragraph not.
        if extraLine(of: entry.fragment) != nil { lines = selection.location == length ? lines.suffix(1) : lines.dropLast() }
        return (document.line(at: selection.location), row(lines, of: entry.fragment))
    }

    /// The highlight's place for a paragraph's lines: the current line's, and an issue's.
    private func row(_ lines: ArraySlice<NSTextLineFragment>, of fragment: NSTextLayoutFragment) -> NSRect {
        let frame = fragment.layoutFragmentFrame
        let top = frame.minY + (lines.first?.typographicBounds.minY ?? 0)
        let bottom = frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height)
        return NSRect(x: 14, y: textContainerOrigin.y + top + rowShift, width: bounds.width - 22, height: bottom - top)
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

    /// The line numbers' colour with Increase Contrast.
    private static let legibleNumbers = NSColor.tertiaryLabelColor.legibleAsText

    /// Draw the current line and the issues' lines, and the numbers on each paragraph's first baseline.
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for issue in issueRows where issue.band.maxY >= rect.minY && issue.band.minY <= rect.maxY {
            // The caret's line has the current line's fill, which is the same shape, and not both.
            if issue.line != current?.number {
                Self.issueFill.setFill()
                issue.shape.fill()
            }
            // The build panel's symbol in the gutter's margin: a line's kind never rests on colour
            // alone, and shows where the line has no room for words.
            if let symbol = Self.issueSymbols[issue.isError] {
                let size = symbol.size
                symbol.draw(in: NSRect(x: 7 - size.width / 2, y: issue.mark.midY - size.height / 2, width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if !issue.tokens.isEmpty {
                NSColor.systemRed.setFill()
                issue.tokens.forEach { $0.fill() }
            }
        }
        guard rect.minX < numbersEnd + 4, showsLineNumbers else { return }
        // The current line's number as a label, as an issue's, the others tertiary, as Xcode's:
        // 1.9:1 in Light and 2.3:1 in Dark, which the HIG allows where Increase Contrast gives more.
        // With that on they are raised as the syntax colours are (`displayOptionsChanged` redraws them).
        let faint = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Self.legibleNumbers : .tertiaryLabelColor
        for (offset, fragment) in fragments {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: origin.y)
            guard frame.maxY >= rect.minY, frame.minY <= rect.maxY, let line = fragment.textLineFragments.first else { continue }
            let lineNumber = document.line(at: offset)
            func draw(_ lineNumber: Int, on line: NSTextLineFragment) {
                (lineNumber == current?.number || issueLines[lineNumber] != nil ? .labelColor : faint).setFill()
                let number = numberLine(lineNumber)
                context.textPosition = CGPoint(x: numbersEnd - number.width, y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                CTLineDraw(number.line, context)
            }
            draw(lineNumber, on: line)
            if let extra = extraLine(of: fragment) { draw(lineNumber + 1, on: extra) }
        }
    }

    // MARK: the build's issues

    /// A line of the viewport with an issue, as it is drawn: its band, which is the current line's
    /// highlight for its paragraph; the first of its wrapped lines in the gutter, which the symbol
    /// is beside; and what the issue says, where the last of them has room after its text.
    struct IssueRow {
        let line: Int
        let isError: Bool
        let band: NSRect
        /// The band's shape, kept for every frame it is filled in.
        let shape: NSBezierPath
        let mark: NSRect
        /// The message in a view of its own, and where a click is the message's.
        var message: (view: IssueMessageView, rect: NSRect, cut: Bool)?
        /// All that the line's issues say, where the row doesn't show it: a help tag's.
        var tip: String?
        /// The underline of each command on the line that its issues name as undefined.
        var tokens: [NSRect] = []
        /// Where its paragraph's line break is: a selection that has it runs over the line's end,
        /// and the message.
        var end: Int?
        /// What it was placed on. A scroll lays the viewport out again with the same paragraphs
        /// where they were, and their rows are then kept as they are.
        let fragment: NSTextLayoutFragment
        let frame: NSRect
        let width: CGFloat
        let origin: NSPoint
    }

    /// The viewport's issues, placed when the text is laid out and not when it is drawn, which is
    /// every frame of a scroll.
    private(set) var issueRows: [IssueRow] = []
    /// The rows there were, while the viewport's are placed.
    private var formerRows: [IssueRow] = []
    /// What a row has besides its paragraph changed, the issues or the font or the display's
    /// scale: none is kept the next time they are placed.
    private var issuesStale = false
    /// The messages as typeset, by line: for these issues and this font.
    private var issueLabels: [Int: IssueLabel] = [:]
    private var issueFont = NSFont.systemFont(ofSize: NSFont.systemFontSize - 1) {
        didSet { issueLabels.removeAll() }
    }
    /// The least between a line's text and its issue's message: three of the text's digits.
    private var issueGap: CGFloat = 0
    /// All that each line's issues say, a line each: its help tag's words.
    private var issueSays: [Int: String] = [:]
    /// The help tags of the rows that don't show all that their issues say, with where each is.
    private var issueTips: [(tag: NSView.ToolTipTag, rect: NSRect, text: NSString)] = []
    /// The commands each line's issues name as undefined, which the line underlines in the
    /// system's red, as Xcode does an issue's token. Drawn here, under the text: TextKit 2 draws
    /// no underline it is given as a rendering attribute, as the syntax colours are given (27.2:
    /// of an underline, a strikethrough, a spelling state and a background colour set on shown
    /// text, it drew the last two).
    private var undefined: [Int: [String]] = [:]

    /// The band's fill: the named system fill nearest Xcode 27.1's for a line with an issue, which
    /// is 245 over white where its current line is 235 (a 2x capture, 2026-10-12). Resolved on
    /// 27.2 the tertiary fill gives 243 there and the quaternary 248, the current line's secondary
    /// 235; in Dark, over the text background's 30, they give 41, 36 and 48. Neutral for an error
    /// and a warning alike: the symbol says which, and a dozen tinted lines in view are noise.
    private static let issueFill = NSColor.tertiarySystemFill
    /// The message's colour: a secondary label, raised to 4.5:1 on the band and on the current
    /// line's fill, which is greyer, and to 7:1 with Increase Contrast.
    fileprivate static let issueText = NSColor.secondaryLabelColor.legibleAsText

    private func issuesChanged() {
        issueLabels.removeAll()
        undefined.removeAll()
        issueSays.removeAll()
        for line in issueLines.keys {
            guard let message = issueMessages[line] else { continue }
            let all = [message] + (issueOthers[line] ?? [])
            issueSays[line] = all.joined(separator: "\n")
            let commands = all.compactMap(UndefinedCommand.named)
            if !commands.isEmpty { undefined[line] = commands }
        }
        issuesStale = true
        placeIssues()
        redrawLineAndGutter()
    }

    /// The pixels are another display's: the underlines are set to them.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        issuesStale = true
        placeIssues()
    }

    /// Places the issues on the fragments laid out. A row whose paragraph is the one it was placed
    /// on, where it was and in a view as wide, is kept as it is, which is every row through a
    /// scroll; the others are placed and marked to be drawn again, where they were and where
    /// they are.
    private func placeIssues() {
        guard !issueLines.isEmpty || !issueRows.isEmpty else { return }
        let anew = issuesStale
        issuesStale = false
        swap(&issueRows, &formerRows)
        var changed = false
        func place(_ number: Int, on fragment: NSTextLayoutFragment, extra: Bool = false) {
            guard let isError = issueLines[number] else { return }
            let former = formerRows.firstIndex { $0.line == number }.map { formerRows.remove(at: $0) }
            if let former, !anew, former.fragment === fragment, former.frame == fragment.layoutFragmentFrame,
               former.width == bounds.width, former.origin == textContainerOrigin {
                return issueRows.append(former)
            }
            changed = true
            // The document's last empty line is the last of the lines of the paragraph before it.
            var lines = fragment.textLineFragments[...]
            if extra { lines = lines.suffix(1) } else if extraLine(of: fragment) != nil { lines = lines.dropLast() }
            let placed = row(number, isError, on: lines, of: fragment, in: former?.message?.view)
            if let former {
                setNeedsDisplay(former.band.union(former.mark))
                if former.message?.view !== placed?.message?.view { former.message?.view.removeFromSuperview() }
            }
            guard let placed else { return }
            setNeedsDisplay(placed.band.union(placed.mark))
            issueRows.append(placed)
        }
        if !issueLines.isEmpty {
            for (offset, fragment) in fragments {
                let number = document.line(at: offset)
                place(number, on: fragment)
                if issueLines[number + 1] != nil, extraLine(of: fragment) != nil { place(number + 1, on: fragment, extra: true) }
            }
        }
        for former in formerRows {
            changed = true
            setNeedsDisplay(former.band.union(former.mark))
            former.message?.view.removeFromSuperview()
        }
        formerRows.removeAll(keepingCapacity: true)
        guard changed else { return }
        updateIssueTips()
        coverIssues()
    }

    /// A line's row on its paragraph's lines. The message is on the last wrapped line, where a
    /// paragraph has room and which is the line TeX reports, set right to the text's trailing
    /// edge on the band, in the view the line's message had if it had one.
    private func row(_ number: Int, _ isError: Bool, on lines: ArraySlice<NSTextLineFragment>, of fragment: NSTextLayoutFragment,
                     in view: IssueMessageView?) -> IssueRow? {
        guard let first = lines.first, let last = lines.last else { return nil }
        let band = row(lines, of: fragment)
        var issue = IssueRow(line: number, isError: isError, band: band, shape: NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4),
                             mark: NSRect(x: 0, y: band.minY, width: numbersEnd + 4, height: first.typographicBounds.height),
                             fragment: fragment, frame: fragment.layoutFragmentFrame, width: bounds.width, origin: textContainerOrigin)
        // The document's last empty line has no line break, and no paragraph of its own.
        if extraLine(of: fragment) !== last {
            let end = offset(fragment.rangeInElement.endLocation) - 1
            if end >= 0, end < text.length, text.character(at: end) == 0x0A { issue.end = end }
        }
        // The fragment's lines in the view: its frame has the line fragment's padding in it.
        let left = textContainerOrigin.x + fragment.layoutFragmentFrame.minX
        let top = textContainerOrigin.y + fragment.layoutFragmentFrame.minY
        if let message = issueMessages[number] {
            let others = issueOthers[number]?.count ?? 0
            let trailing = bounds.width - 8 - (textContainer?.lineFragmentPadding ?? 0)
            var label = issueLabels[number] ?? IssueLabel(message, others: others, font: issueFont)
            let fitted = label.line(in: trailing - (left + last.typographicBounds.maxX) - issueGap)
            issueLabels[number] = label
            if let fitted {
                // On the text's baseline, in the band's rows: they are `rowShift` below the lines'.
                let rect = NSRect(x: trailing - fitted.width, y: top + last.typographicBounds.minY + rowShift,
                                  width: fitted.width, height: last.typographicBounds.height)
                let view = view ?? IssueMessageView()
                view.show(fitted.line, baseline: last.glyphOrigin.y - rowShift, in: rect)
                if view.superview !== self { addSubview(view) }
                issue.message = (view, rect, fitted.cut)
            }
            if fitted?.cut != false || others > 0 { issue.tip = issueSays[number] }
        }
        if let commands = undefined[number], let font {
            // As far under the baseline as the font puts an underline and a point thick at the
            // least, as Xcode's is (the font's own is a pixel at 13 points), its edges on whole
            // pixels, the ends as the top and bottom.
            let scale = window?.backingScaleFactor ?? 1
            func whole(_ length: CGFloat) -> CGFloat { (length * scale).rounded() / scale }
            let thickness = max(1, whole(font.underlineThickness))
            let paragraph = first.attributedString.string as NSString
            for range in commands.flatMap({ UndefinedCommand.ranges(of: $0, in: paragraph) }) {
                // A command a line is too narrow for is on two.
                for line in lines {
                    let part = NSIntersectionRange(range, line.characterRange)
                    guard part.length > 0 else { continue }
                    let lineLeft = left + line.typographicBounds.minX
                    let start = whole(lineLeft + line.locationForCharacter(at: part.location).x)
                    let end = whole(lineLeft + line.locationForCharacter(at: NSMaxRange(part)).x)
                    let under = top + line.typographicBounds.minY + line.glyphOrigin.y - font.underlinePosition
                    issue.tokens.append(NSRect(x: start, y: whole(under), width: end - start, height: thickness))
                }
            }
        }
        return issue
    }

    /// A help tag with all that a line's issues say, on a message that is cut short or counts
    /// others, and on the gutter's mark of such a line and of one with no room for a message.
    /// Asked for when a row is placed, and kept as they are where the tags are where they were.
    private func updateIssueTips() {
        var tips: [(rect: NSRect, text: String)] = []
        for issue in issueRows {
            guard let tip = issue.tip else { continue }
            tips.append((issue.mark, tip))
            if let message = issue.message { tips.append((message.rect, tip)) }
        }
        guard tips.count != issueTips.count || !zip(tips, issueTips).allSatisfy({ $0.rect == $1.rect && $1.text.isEqual(to: $0.text) }) else { return }
        for tip in issueTips { removeToolTip(tip.tag) }
        // The string is the tag's owner, which AppKit asks for its description and doesn't keep.
        issueTips = tips.map { tip in
            let text = tip.text as NSString
            return (addToolTip(tip.rect, owner: text, userData: nil), tip.rect, text)
        }
    }

    /// A selection that has a paragraph's line break is drawn to the text's trailing edge, over
    /// the band: the message on it is then in the selected text's colour, not the band's grey.
    private func coverIssues() {
        guard !issueRows.isEmpty else { return }
        let selected = selectedRanges
        for issue in issueRows {
            guard let view = issue.message?.view else { continue }
            view.covered = issue.end.map { end in selected.contains { NSLocationInRange(end, $0.rangeValue) } } ?? false
        }
    }

    /// The issue whose message is under the pointer.
    private func issueMessage(at event: NSEvent) -> IssueRow? {
        guard !issueRows.isEmpty else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return nil }
        return issueRows.first { $0.message?.rect.contains(point) == true }
    }

    // MARK: the colours

    /// Settings' Colour Theme.
    var syntaxTheme = SyntaxTheme.overleaf {
        didSet { if syntaxTheme != oldValue { colour(from: 0) } }
    }

    /// Where the text first changed since it was last coloured, or 0 for all of it: coloured
    /// again once it's laid out, which every edit leads to, an undone one too.
    private var staleColours: Int?

    /// Colours the text from an offset's line on, as an edit changes no colour before its own
    /// line. TextKit validates colours when it lays a fragment out anew, without editing the
    /// document's attributes; the fragments already shown keep none until validated here, and
    /// show none until redrawn: display maths opened on one line recolours those under it.
    private func colour(from start: Int) {
        guard let manager = textLayoutManager else { return }
        staleColours = nil
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
        let line = document.lineStart(document.line(at: start))
        let stale = textRange(NSRange(location: line, length: 0)).flatMap { NSTextRange(location: $0.location, end: manager.documentRange.endLocation) }
        manager.invalidateRenderingAttributes(for: stale ?? manager.documentRange)
        for (_, fragment) in fragments[(fragments.lastIndex { $0.offset <= line } ?? 0)...] {
            manager.renderingAttributesValidator?(manager, fragment)
        }
        redrawFragments()
    }

    /// Each shown fragment draws in a view of its own, which new rendering attributes don't
    /// redraw, nor does the text view's own display (27.2).
    private func redrawFragments() {
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        subviews.forEach(redraw)
    }

    // MARK: the selection

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !loading else { return }
        if !typing { closeCompletions() }
        if partnerMarked, let manager = textLayoutManager {
            partnerMarked = false
            manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
            redrawFragments()
        }
        previewMath()
        if let snippet, !mirroring, !snippet.contains(selectedRange()) { self.snippet = nil }
        let lineStart = text.lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
        closers = closers.filter { $0 >= lineStart }
        redrawLineAndGutter()
        coverIssues()
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

    /// Its window's key changes (`keyChanged`), watched for as long as their tokens are held.
    private var keyWatches: [NotificationCenter.ObservationToken] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The window it left, before the one it joins.
        keyWatches = []
        guard let window else { return }
        keyWatches = [
            NotificationCenter.default.addObserver(of: window, for: .didBecomeKey) { [weak self] _ in self?.keyChanged() },
            NotificationCenter.default.addObserver(of: window, for: .didResignKey) { [weak self] _ in self?.keyChanged() },
        ]
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
    /// Where the maths starts whose preview Escape dismissed, while the caret stays in it.
    private var dismissedMath: Int?

    private func math(at caret: Int) -> MathPreview? {
        if let lastMath, lastMath.caret == caret, lastMath.edits == edits { return lastMath.value }
        let value = document.mathAt(caret: caret)
        lastMath = (caret, edits, value)
        return value
    }

    /// Preview maths at the caret only while the caret is visible and focused:
    /// over its line, as Overleaf's, or under it while completions show over it.
    func previewMath() {
        // Asked for whether or not it shows: Escape's dismissal lasts while the caret is in that maths.
        let maths = loading ? nil : math(at: selectedRange().location)
        if maths?.start != dismissedMath { dismissedMath = nil }
        guard let window, hasKeyboard, let maths, dismissedMath == nil, let scroll = enclosingScrollView else {
            mathPopover?.close()
            return
        }
        let screen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        // A point wide: NSPopover takes an empty rect for the whole view.
        var rect = convert(window.convertFromScreen(screen), from: nil)
        rect.size.width = max(rect.width, 1)
        // Below the toolbar and the find bar, and above the scroll view's foot.
        let insets = scroll.contentInsets, clip = scroll.contentView
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
        guard i >= 0, i < text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: i)).first
    }

    /// Where the bracket at `at` is matched, within 10,000 UTF-16 units. Brackets are ASCII,
    /// so code units compare exactly.
    private func partner(of at: Int) -> Int? {
        let text = self.text
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
        let range = NSRange(location: i, length: 1)
        guard reducesMotion(), let manager = textLayoutManager, let marked = textRange(range) else { return showFindIndicator(for: range) }
        // The find indicator bounces: with Reduce Motion the partner is filled where it is,
        // until the selection next changes.
        manager.addRenderingAttribute(.backgroundColor, value: NSColor.unemphasizedSelectedTextBackgroundColor, for: marked)
        partnerMarked = true
        redrawFragments()
    }

    var reducesMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var partnerMarked = false

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
        let next = character(at: selection.location)
        if selection.length == 0, closers.contains(selection.location), Self.pairs.values.contains(c) {
            if next == c {
                closers.remove(selection.location)
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                showPartner(of: selection.location)
                return
            }
            // A closer put in as \] or \}: its bracket steps over both, and a backslash typed for it
            // goes. A backslash alone is typed in, being a command's as often as the closer's.
            if next == "\\", character(at: selection.location + 1) == c {
                closers.remove(selection.location)
                var bracket = selection.location + 1
                if isEscaped(selection.location) {
                    insertText("", replacementRange: NSRange(location: selection.location - 1, length: 1))
                    bracket -= 1
                }
                setSelectedRange(NSRange(location: bracket + 1, length: 0))
                showPartner(of: bracket)
                return
            }
        }
        if EditorPrefs.autoPair, let close = Self.pairs[c] {
            if selection.length > 0 {
                super.insertText("\(c)\(text.substring(with: selection))\(close)", replacementRange: selection)
                closers.insert(NSMaxRange(selection) + 1)
                setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
                return
            }
            if next.map({ $0.isWhitespace || Self.closeBefore.contains($0) }) ?? true {
                // \[ closes with \], \{ with \} and \( with \).
                super.insertText(isEscaped(selection.location) ? "\(c)\\\(close)" : "\(c)\(close)", replacementRange: selection)
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

    /// Whether the character at `at` follows an unescaped backslash, as the bracket of `\[` does.
    private func isEscaped(_ at: Int) -> Bool {
        var slashes = 0
        while at - slashes > 0, text.character(at: at - slashes - 1) == 0x5C { slashes += 1 }
        return slashes % 2 == 1
    }

    /// How long the closer after the caret is, between an empty pair: 1, or 2 between `\[` and `\]`.
    private func closer(after caret: Int) -> Int? {
        guard let close = character(at: caret - 1).flatMap({ Self.pairs[$0] }) else { return nil }
        if character(at: caret) == close { return 1 }
        return isEscaped(caret - 1) && character(at: caret) == "\\" && character(at: caret + 1) == close ? 2 : nil
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
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0, selectedRanges.count == 1 else { return super.deleteBackward(sender) }
        let caret = selection.location
        // Only a closer this view put in goes with its bracket.
        if EditorPrefs.autoPair, closers.contains(caret), let closer = closer(after: caret) {
            insertText("", replacementRange: NSRange(location: caret - 1, length: 1 + closer))
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
        var range = selectedRange()
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = text.substring(with: line).trimmingCharacters(in: .newlines)
        let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
        let lineEnd = line.location + (lineText as NSString).length
        let between = range.length == 0 && closer(after: range.location) != nil
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

    override func insertTab(_ sender: Any?) { tab(1) }

    override func insertBacktab(_ sender: Any?) { tab(-1) }

    /// Tab and Shift-Tab go to a snippet's next field and the one before it; with no snippet they indent and outdent.
    private func tab(_ step: Int) {
        if snippet != nil { return moveField(step) }
        let edits = document.indent(selectedRanges.map(\.rangeValue), more: step > 0)
        apply(edits, named: step > 0 ? String(localized: "Indent") : String(localized: "Outdent"))
    }

    /// Kept for the next file and launch, as a setting.
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        EditorPrefs.spellCheck = isContinuousSpellCheckingEnabled
    }

    /// Escape closes the completion list, or ends a snippet, or dismisses the maths preview until
    /// the caret leaves that maths, or asks for completions, as Xcode's; it never goes on to the
    /// window, which would leave full screen.
    override func cancelOperation(_ sender: Any?) {
        if offered != nil {
            closeCompletions()
        } else if snippet != nil {
            snippet = nil
        } else if mathPopover?.isShown == true, let maths = math(at: caret) {
            dismissedMath = maths.start
            mathPopover?.close()
        } else {
            complete(explicit: true)
        }
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

    /// Offer core completions after typing when the caret has candidates. With Settings'
    /// Suggest Completions While Typing off, typing only filters a list Escape opened.
    private func offerCompletions() {
        if EditorPrefs.autoComplete || offered != nil { complete(explicit: false) }
    }

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

    /// Under the typed text's start while its line shows, or closed: a view of its scroll view,
    /// over the text. Without a window it holds its items unseen, as the tests use it.
    private func showCompletions(reload: Bool) {
        guard let offered else { return }
        var start = NSRect.zero, shown = NSRect.zero, host: NSScrollView?
        if let window, let scroll = enclosingScrollView {
            host = scroll
            start = scroll.convert(window.convertFromScreen(
                firstRect(forCharacterRange: NSRange(location: offered.start, length: 0), actualRange: nil)), from: nil)
            // Not under the toolbar or the status bar.
            let insets = scroll.contentInsets, clip = scroll.contentView
            var inWindow = clip.convert(clip.bounds, to: nil)
            inWindow.origin.y += insets.bottom
            inWindow.size.height -= insets.top + insets.bottom
            shown = scroll.convert(inWindow, from: nil)
            guard shown.contains(NSPoint(x: start.minX, y: start.midY)) else { return closeCompletions() }
            guard reload else { return completionList.place(under: start, in: shown) }
        }
        completionList.show(offered.items.map(\.label), typed: caret - offered.start, kind: offered.kind,
                            font: font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                            under: start, in: shown, of: host)
        // Out of the list's way.
        if host != nil { previewMath() }
    }

    /// Arrows move through the open list, Return and Tab accept. Escape is `cancelOperation`
    /// here: the text view's own goes straight to its `complete(_:)`.
    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { return cancelOperation(nil) }
        guard offered != nil else { return super.doCommand(by: selector) }
        switch selector {
        case #selector(moveUp(_:)): completionList.move(-1)
        case #selector(moveDown(_:)): completionList.move(1)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)): acceptCompletion(completionList.selection)
        default: super.doCommand(by: selector)
        }
    }

    /// Only a chosen completion goes in, replacing what's typed of it, as an undo step of its
    /// own: undone, what was typed is back.
    private func acceptCompletion(_ index: Int) {
        guard let offered, offered.items.indices.contains(index), caret >= offered.start else { return closeCompletions() }
        let item = offered.items[index]
        closeCompletions()
        apply([TextEdit(NSRange(location: offered.start, length: caret - offered.start), item.text)], named: String(localized: "Completion"),
              select: NSRange(location: offered.start + (item.text as NSString).length, length: 0))
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
        guard needsMirror, !mirroring, let snippet, let typed = snippet.typed else { return }
        needsMirror = false
        let text = self.text.substring(with: typed)
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

    /// A double-click goes to the PDF, as one in the PDF comes here, once AppKit has selected the
    /// word: quietly, a word the PDF doesn't have (the preamble's, a comment's) raising no alert.
    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown, inGutter(event) { return selectLines(with: event) }
        if event.type == .leftMouseDown, let issue = issueMessage(at: event), clicked(issue, with: event) { return }
        super.mouseDown(with: event)
        if event.type == .leftMouseDown, event.clickCount == 2 { forwardSync(true)?() }
    }

    /// A click on an issue's message shows the issue, as one on its mark in the gutter does, once
    /// the button is let go over it; the selection stays as it is. Only a click: the message is
    /// where a line's end is, and a drag from there selects as from any line's end, as a click
    /// with Shift and a double-click do. False for those, which are the text view's.
    private func clicked(_ issue: IssueRow, with down: NSEvent) -> Bool {
        guard down.clickCount == 1, down.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) else { return false }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if issue.message?.rect.contains(convert(next.locationInWindow, from: nil)) == true { issueClicked(issue.line) }
                break
            }
            // A hand's tremor is not a drag: 3 points clear of the press is.
            if hypot(next.locationInWindow.x - down.locationInWindow.x, next.locationInWindow.y - down.locationInWindow.y) > 3 {
                // The text view tracks it from the press, taking this move first.
                window?.postEvent(next, atStart: true)
                return false
            }
        }
        return true
    }

    /// A click in the gutter selects its line, a drag the lines it passes and Shift from the
    /// selection there was, as Xcode's; on an issue's mark the build panel shows the issue.
    private func selectLines(with event: NSEvent) {
        func line(at event: NSEvent) -> NSRange {
            let point = NSPoint(x: textContainerOrigin.x, y: convert(event.locationInWindow, from: nil).y)
            return text.lineRange(for: NSRange(location: characterIndexForInsertion(at: point), length: 0))
        }
        let first = line(at: event)
        let anchor = event.modifierFlags.contains(.shift) ? selectedRange() : first
        window?.makeFirstResponder(self)
        var current = event
        repeat {
            setSelectedRange(NSUnionRange(anchor, line(at: current)))
            autoscroll(with: current)
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            current = next
        } while current.type != .leftMouseUp
        let number = document.line(at: first.location)
        if selectedRange() == first, issueLines[number] != nil { issueClicked(number) }
    }

    // MARK: file drops open, or insert a figure

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
        switch drop {
        case .open(let open): open()
        case .insert(let text):
            guard isEditable else { return false }
            // Selected where it lands, as dropped content is, and undone in one step.
            let at = characterIndexForInsertion(at: convert(info.draggingLocation, from: nil))
            apply([TextEdit(NSRange(location: at, length: 0), text)], named: String(localized: "Insert Figure"),
                  select: NSRange(location: at, length: (text as NSString).length))
            window?.makeFirstResponder(self)
        }
        return true
    }

    // MARK: VoiceOver's rotors

    /// The open file's headings in order, for VoiceOver's Headings rotor.
    var headings: () -> [(line: Int, title: String)] = { [] }
    private lazy var rotors = [NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self),
                               NSAccessibilityCustomRotor(label: String(localized: "Issues"), itemSearchDelegate: self)]

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] { rotors }

    /// The next or previous heading, or line with a build issue, from the rotor's current one. An
    /// issue is named by its kind, its line and what it says, which the filter then searches.
    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor search: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        var items = rotor.type == .heading ? headings() : issueLines.sorted { $0.key < $1.key }.map { line, error in
            let place = error ? String(localized: "Error on line \(line)") : String(localized: "Warning on line \(line)")
            return (line, issueMessages[line].map { String(localized: "\(place): \($0)") } ?? place)
        }
        if !search.filterString.isEmpty { items = items.filter { $0.title.localizedCaseInsensitiveContains(search.filterString) } }
        let current = search.currentItem.map { document.line(at: min($0.targetRange.location, text.length)) }
        let next = search.searchDirection == .next
        guard let found = next ? items.first(where: { $0.line > current ?? 0 }) : items.last(where: { $0.line < current ?? .max })
        else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        // The outline and the issues are a moment behind the text: within what there is of it.
        result.targetRange = text.lineRange(for: NSRange(location: min(document.lineStart(found.line), text.length), length: 0))
        result.customLabel = found.title
        return result
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

/// An issue's message in a view of its own, over the text view's: TextKit draws a selection in
/// a view above the text view's background (`_NSTextSelectionView`, the first of its subviews,
/// 27.2), which covered a message drawn there with the band, and Select All left no words.
/// Above the text's views it shows through a selection, in the text view's coordinates, moving
/// with the text as it scrolls. It takes no click: the text view answers for it.
final class IssueMessageView: NSView {
    private var line: CTLine?
    private var baseline: CGFloat = 0
    /// Under a selection, which is drawn to the trailing edge where it has the line's break: in
    /// the selected text's colour, the band's grey being 2.2:1 on Dark's selection.
    var covered = false {
        didSet { if covered != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Its colours are the appearance's.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The typeset line with its baseline this far under the rect's top, a point clear of the
    /// view's sides for the glyphs' edges.
    func show(_ line: CTLine, baseline: CGFloat, in rect: NSRect) {
        if line !== self.line || baseline != self.baseline { needsDisplay = true }
        (self.line, self.baseline) = (line, baseline)
        let frame = rect.insetBy(dx: -1, dy: 0)
        if frame != self.frame { self.frame = frame }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let context = NSGraphicsContext.current?.cgContext else { return }
        (covered ? NSColor.selectedTextColor : SourceTextView.issueText).setFill()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: 1, y: baseline)
        CTLineDraw(line, context)
    }
}

/// An issue's message set as one line for its line's end, in the context's colour: whole where
/// there is room for it, cut at the tail with an ellipsis where there isn't, and not at all where
/// fewer than ten of its characters would show, which say nothing. A line's other issues are
/// counted after it ("+2"), and the count outlasts the cut. An undefined command's message ends
/// with the one thing it has to say, the command, and starts as every other such message does:
/// without room for all of it, it is set in fewer words that keep the name ("Undefined: \name"),
/// and those are what is cut.
struct IssueLabel {
    private let whole: CTLine, ending: CTLine
    private let short: (line: CTLine, width: CGFloat)?
    /// The whole message's width.
    let width: CGFloat
    /// What a cut one ends with, the ellipsis and the count, is this wide.
    private let endingWidth: CGFloat
    /// The last room asked for and its answer: the same until the pane's width changes.
    private var fitted: (room: CGFloat, line: (line: CTLine, width: CGFloat, cut: Bool)?)?

    /// The fewest of a message's characters worth showing before the ellipsis.
    static let least = 10

    init(_ message: String, others: Int, font: NSFont) {
        func typeset(_ string: String) -> (CTLine, CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
            return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        // One line, whatever TeX's own breaks.
        let message = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let count = others > 0 ? "  +\(others)" : ""
        short = UndefinedCommand.named(in: message).map { typeset(String(localized: "Undefined: \($0)") + count) }
        (whole, width) = typeset(message + count)
        (ending, endingWidth) = typeset("…" + count)
    }

    /// The message for a room this wide, or nil where it has none; `cut` where it isn't all there.
    mutating func line(in room: CGFloat) -> (line: CTLine, width: CGFloat, cut: Bool)? {
        if let fitted, fitted.room == room { return fitted.line }
        var line: (line: CTLine, width: CGFloat, cut: Bool)?
        let most = short ?? (whole, width)
        if width <= room {
            line = (whole, width, false)
        } else if let short, short.width <= room {
            line = (short.line, short.width, true)
        } else if CTLineGetStringIndexForPosition(most.line, CGPoint(x: room - endingWidth, y: 0)) >= Self.least,
                  let cut = CTLineCreateTruncatedLine(most.line, Double(room), .end, ending) {
            line = (cut, CGFloat(CTLineGetTypographicBounds(cut, nil, nil, nil)), true)
        }
        fitted = (room, line)
        return line
    }
}

/// The one issue whose place on its line its message gives: TeX names the command it doesn't know,
/// which the core puts after its own words for it, and the line has that command where it stands.
enum UndefinedCommand {
    /// The command a message names as undefined, as the core writes it ("Undefined control
    /// sequence: \name"), and for no other message: one in a file TeX loaded has that file's name
    /// before it, and its command isn't on a line of this file.
    static func named(in message: String) -> String? {
        let words = "Undefined control sequence: \\"
        guard message.hasPrefix(words) else { return nil }
        let name = message.dropFirst(words.count)
        // TeX's own two forms: letters, or one character of any other kind.
        guard name.count == 1 || (!name.isEmpty && name.allSatisfy(isLetter)) else { return nil }
        return "\\" + name
    }

    /// `@` with them: a letter in a class's or a package's own source.
    private static func isLetter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character == "@")
    }

    /// Where a line has the command, each time it does: not as the start of a longer name, not
    /// after a backslash that is itself a command's (`\\foo` is a line break and a word), and not
    /// in a comment.
    static func ranges(of command: String, in line: NSString) -> [NSRange] {
        func escaped(_ at: Int) -> Bool {
            var slashes = 0
            while at - slashes > 0, line.character(at: at - slashes - 1) == 0x5C { slashes += 1 }
            return slashes % 2 == 1
        }
        // To the first percent sign that isn't `\%`.
        var end = 0
        while end < line.length, line.character(at: end) != 0x25 || escaped(end) { end += 1 }
        let word = command.dropFirst().first.map(isLetter) ?? false
        var found: [NSRange] = [], from = 0
        while from < end {
            let range = line.range(of: command, options: .literal, range: NSRange(location: from, length: end - from))
            guard range.location != NSNotFound else { break }
            from = NSMaxRange(range)
            let next = from < line.length ? Unicode.Scalar(line.character(at: from)).map(Character.init) : nil
            if !escaped(range.location), !(word && next.map(isLetter) == true) { found.append(range) }
        }
        return found
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

    /// The themes' own colours fall short of the HIG's 4.5:1 in places (Overleaf's comments, 4.2:1;
    /// the system's teal, 2.2:1), so each is raised to it, and further with Increase Contrast.
    private static func rgb(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func srgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let light = srgb(light), dark = srgb(dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }.legibleAsText
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

    /// The system's colours, which follow the appearance.
    private static let systemColours = Colours(
        command: .systemPink.legibleAsText, keyword: .systemBrown.legibleAsText, argument: .systemTeal.legibleAsText,
        maths: .systemPurple.legibleAsText, comment: .secondaryLabelColor.legibleAsText, invalid: .systemRed.legibleAsText)
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
