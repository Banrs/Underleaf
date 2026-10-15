import AppKit

final class SourceTextView: NSTextView, NSTextStorageDelegate, NSAccessibilityCustomRotorItemSearchDelegate {
    static func plainDocument() -> SourceTextView {
        let view = SourceTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.usesRuler = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.delegate = view
        view.displayOptionsWatch = NSWorkspace.shared.notificationCenter.addObserver(
            of: NSWorkspace.self, for: .accessibilityDisplayOptionsDidChange) { [weak view] _ in view?.displayOptionsChanged() }
        return view
    }

    private var displayOptionsWatch: NotificationCenter.ObservationToken?

    private func displayOptionsChanged() {
        needsDisplay = true
        for issue in issueRows { issue.message?.view.needsDisplay = true }
    }

    /// A cursor rect of the list's own lost to the text view's per-move cursor, so the pointer is set on every move.
    private func setsCursor(with event: NSEvent) -> Bool {
        if updateDividerCursor(with: event) { return true }
        guard inGutter(event) || issueMessage(at: event) != nil || completionList.contains(event.locationInWindow) else { return false }
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

    private(set) var document = SourceDocument(text: "") {
        didSet { document.setSymbols(symbols) }
    }
    /// Only active IME composition needs a snapshot; ordinary edits and undo are live.
    private var beforeMarkedText: String?
    var committedString: String { hasMarkedText() ? beforeMarkedText ?? string : string }
    /// Reads the storage's UTF-16 units in place: `string` bridges the whole text on every call.
    var text: NSString { textStorage?.mutableString ?? "" }
    var symbols = Symbols(citations: [], labels: []) {
        didSet { if symbols != oldValue { document.setSymbols(symbols) } }
    }
    var fileDrop: (URL) -> FileDrop? = { _ in nil }

    enum FileDrop {
        case open(() -> Void)
        case insert(String)
    }
    var textEdited: (NSRange, String) -> Void = { _, _ in }
    var forwardSync: (_ quietly: Bool) -> (() -> Void)? = { _ in nil }

    private(set) var loading = false

    func load(_ text: String) {
        loading = true
        // Else typing coalesced into the last file's undo would go on in this one's.
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
        let changed = changing.flatMap { $0.location == old.location && NSMaxRange($0) <= NSMaxRange(old) ? $0 : nil }
        changing = nil
        follow(changed ?? old, delta)
        if lineCountDigits != digits(document.lineCount) {
            // After the edit: a layout change mid-edit would lay out stale text.
            Task { self.updateGutterWidth() }
        }
    }

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

    var fontSize = NSFont.systemFontSize {
        didSet { applyFont() }
    }
    var fontName = "" {
        didSet { if fontName != oldValue { applyFont() } }
    }
    private var rowShift: CGFloat = 0
    private var applied: NSFont?

    private func applyFont() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let chosen = fontName.isEmpty ? nil : NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: fontSize)
        let font = chosen ?? .monospacedSystemFont(ofSize: fontSize, weight: dark ? .medium : .regular)
        guard font != applied else { return }
        let resized = applied?.pointSize != font.pointSize || applied?.familyName != font.familyName
        applied = font
        defer {
            issuesStale = true
            if !issueLines.isEmpty { layOutViewportOnceSettled() }
        }
        self.font = font
        closeCompletions()
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
        // Xcode's numbers: semi-condensed SF a point under the text, tabular, never under the HIG's 10 points.
        let numbers = NSFont.systemFont(ofSize: max(10, fontSize - 1), weight: .regular, width: NSFont.Width(rawValue: -0.1))
        numberFont = NSFont(descriptor: numbers.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector]]]), size: 0) ?? numbers
        issueFont = .systemFont(ofSize: fontSize)
        let size = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular, scale: .small)
        issueSymbols = [true: ("exclamationmark.octagon", NSColor.systemRed), false: ("exclamationmark.triangle", .systemYellow)].compactMapValues {
            NSImage(systemSymbolName: $0.0, accessibilityDescription: nil)?.withSymbolConfiguration(size.applying(.init(paletteColors: [$0.1])))
        }
        issueGap = 3 * ("0" as NSString).size(withAttributes: [.font: font]).width
        gutterWidth = 0
        updateGutterWidth()
    }

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
    private var digitWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: numberFont]).width }
    private var numbersEnd: CGFloat = 0
    private var fragments: [(offset: Int, fragment: NSTextLayoutFragment)] = []
    struct LineIssue: Equatable {
        var isError: Bool
        var message: String
        var others: [String] = []
    }

    var issueLines: [Int: LineIssue] = [:] {
        didSet { if issueLines != oldValue { issuesChanged() } }
    }
    var issueClicked: (Int) -> Void = { _ in }
    private var issueSymbols: [Bool: NSImage] = [:]

    var showsLineNumbers = true {
        didSet { if showsLineNumbers != oldValue { updateGutterWidth() } }
    }

    private func digits(_ n: Int) -> Int { max(4, String(n).count) }

    func updateGutterWidth() {
        lineCountDigits = digits(document.lineCount)
        numbersEnd = showsLineNumbers ? 19.5 + CGFloat(lineCountDigits - 1) * digitWidth : 14
        let width = numbersEnd + 11 - (textContainer?.lineFragmentPadding ?? 0)
        guard width != gutterWidth else { return }
        gutterWidth = width
        textContainerInset.width = (textContainerOrigin.x + 8) / 2
        needsDisplay = true
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: gutterWidth, y: textContainerInset.height)
    }

    // 27.2: the top paragraph stays put: TextKit 2 keeps the offset, over heights a new width re-estimates.
    override func setFrameSize(_ size: NSSize) {
        guard size.width != frame.width else { return super.setFrameSize(size) }
        let top = shownTop
        super.setFrameSize(size)
        // 27.2: scrolled down, AppKit's tracking waits for a live resize's end, so the width follows as it goes.
        textContainer?.size.width = max(0, size.width - 2 * textContainerInset.width)
        top.map(scroll(toShownTop:))
        layOutViewportOnceSettled()
    }

    private var viewportPending = false

    /// 27.2: widths changing faster than a frame (a divider dragged quickly) can leave the viewport's text gone
    /// until it next scrolls; once they settle, TextKit lays the shown text out for the last.
    private func layOutViewportOnceSettled() {
        guard !viewportPending else { return }
        viewportPending = true
        Task { [weak self] in
            self?.viewportPending = false
            self?.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    /// From the fragments last laid out: asked by point, TextKit answers from its new estimates.
    var shownTop: (offset: Int, below: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView,
              let top = fragments.first(where: { $0.fragment.layoutFragmentFrame.maxY + textContainerOrigin.y > clip.bounds.minY + clip.contentInsets.top })?.fragment
        else { return nil }
        return (offset(top.rangeInElement.location), top.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.minY)
    }

    /// 27.2: AppKit's Jump to Selection lands lines off where TextKit 2 has only estimated the heights above.
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

    /// Laid out first: far from the viewport the range has no rect yet, and TextKit 2's estimates above it settle as it's shown.
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

    func scroll(toShownTop top: (offset: Int, below: CGFloat)) {
        guard let location = textRange(NSRange(location: min(top.offset, text.length), length: 0))?.location else { return }
        scroll(location) { $0.minY - top.below }
    }

    /// 27.2: lays out only that paragraph, in two passes, and only in a window.
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
        showCompletions(reload: false)
        placeIssues()
        redrawLineAndGutter()
    }

    /// The document's last line when it's empty: TextKit lays it out as an extra line of the paragraph before.
    private func extraLine(of fragment: NSTextLayoutFragment) -> NSTextLineFragment? {
        let lines = fragment.textLineFragments
        guard lines.count > 1, let last = lines.last, last.characterRange.length == 0 else { return nil }
        return last
    }

    private var currentLine: (number: Int, rect: NSRect)? {
        let selection = selectedRange(), length = text.length
        guard let entry = fragments.last(where: { $0.offset <= selection.location }) else { return nil }
        let end = offset(entry.fragment.rangeInElement.endLocation)
        guard selection.location < end || end == length else { return nil }
        var lines = entry.fragment.textLineFragments[...]
        if extraLine(of: entry.fragment) != nil { lines = selection.location == length ? lines.suffix(1) : lines.dropLast() }
        return (document.line(at: selection.location), row(lines, of: entry.fragment))
    }

    /// `rowShift` can leave the edges between two of the display's pixels, so they are snapped to one.
    private func row(_ lines: ArraySlice<NSTextLineFragment>, of fragment: NSTextLayoutFragment) -> NSRect {
        let frame = fragment.layoutFragmentFrame
        let top = onPixels(textContainerOrigin.y + frame.minY + (lines.first?.typographicBounds.minY ?? 0) + rowShift)
        let bottom = onPixels(textContainerOrigin.y + frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height) + rowShift)
        return NSRect(x: 14, y: top, width: bounds.width - 22, height: bottom - top)
    }

    private func onPixels(_ y: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (y * scale).rounded() / scale
    }
    private var drawnLine: NSRect?

    private func redrawLineAndGutter() {
        let shown = visibleRect
        setNeedsDisplay(NSRect(x: shown.minX, y: shown.minY, width: numbersEnd + 4 - shown.minX, height: shown.height))
        if let drawnLine { setNeedsDisplay(drawnLine) }
        if let rect = currentLine?.rect { setNeedsDisplay(rect) }
    }

    private var numberLines: [Int: (line: CTLine, width: CGFloat)] = [:]

    private func numberLine(_ number: Int) -> (line: CTLine, width: CGFloat) {
        if let cached = numberLines[number] { return cached }
        if numberLines.count > 4096 { numberLines.removeAll(keepingCapacity: true) }
        let line = typeset(String(number), in: numberFont)
        numberLines[number] = line
        return line
    }

    private static let legibleNumbers = NSColor.tertiaryLabelColor.legibleAsText

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let origin = textContainerOrigin
        let current = selectedRange().length == 0 ? currentLine : nil
        drawnLine = current?.rect
        if let current, current.rect.intersects(rect) {
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
            if !issue.tokens.isEmpty {
                NSColor.systemRed.setFill()
                issue.tokens.forEach { $0.fill() }
            }
        }
        guard rect.minX < numbersEnd + 4, showsLineNumbers else { return }
        // Increase Contrast raises the numbers as the syntax colours are (`displayOptionsChanged` redraws them).
        let faint = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Self.legibleNumbers : .tertiaryLabelColor
        for (offset, fragment) in fragments {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: origin.y)
            guard frame.maxY >= rect.minY, frame.minY <= rect.maxY, let line = fragment.textLineFragments.first else { continue }
            let lineNumber = document.line(at: offset)
            func draw(_ lineNumber: Int, on line: NSTextLineFragment) {
                (lineNumber == current?.number ? .labelColor : faint).setFill()
                let number = numberLine(lineNumber)
                context.textPosition = CGPoint(x: numbersEnd - number.width, y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                CTLineDraw(number.line, context)
            }
            draw(lineNumber, on: line)
            if let extra = extraLine(of: fragment) { draw(lineNumber + 1, on: extra) }
        }
    }

    // MARK: the build's issues

    struct IssueRow {
        let line: Int
        let isError: Bool
        let band: NSRect
        let shape: NSBezierPath
        var message: (view: IssueMessageView, rect: NSRect, cut: Bool)?
        var tip: String?
        var tokens: [NSRect] = []
        let fragment: NSTextLayoutFragment
        let frame: NSRect
        let width: CGFloat
        let origin: NSPoint
    }

    private(set) var issueRows: [IssueRow] = []
    private var issuesStale = false
    private var issueLabels: [Int: IssueLabel] = [:]
    private var issueFont = NSFont.systemFont(ofSize: NSFont.systemFontSize - 1) {
        didSet { issueLabels.removeAll() }
    }
    private var issueGap: CGFloat = 0
    private var issueTips: [(tag: NSView.ToolTipTag, rect: NSRect, text: NSString)] = []

    private static let issueFill = NSColor.tertiarySystemFill

    private func issuesChanged() {
        issueLabels.removeAll()
        issuesStale = true
        placeIssues()
        redrawLineAndGutter()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        issuesStale = true
        placeIssues()
    }

    private func placeIssues() {
        guard !issueLines.isEmpty || !issueRows.isEmpty else { return }
        let anew = issuesStale
        issuesStale = false
        var formerRows = issueRows
        issueRows.removeAll()
        var changed = false
        func place(_ number: Int, on fragment: NSTextLayoutFragment, extra: Bool = false) {
            guard let reported = issueLines[number] else { return }
            let former = formerRows.firstIndex { $0.line == number }.map { formerRows.remove(at: $0) }
            if let former, !anew, former.fragment === fragment, former.frame == fragment.layoutFragmentFrame,
               former.width == bounds.width, former.origin == textContainerOrigin {
                return issueRows.append(former)
            }
            changed = true
            // The document's last empty line is the last of the lines of the paragraph before it.
            var lines = fragment.textLineFragments[...]
            if extra { lines = lines.suffix(1) } else if extraLine(of: fragment) != nil { lines = lines.dropLast() }
            let placed = row(number, reported, on: lines, of: fragment, in: former?.message?.view)
            if let former {
                setNeedsDisplay(former.band)
                if former.message?.view !== placed?.message?.view { former.message?.view.removeFromSuperview() }
            }
            guard let placed else { return }
            setNeedsDisplay(placed.band)
            issueRows.append(placed)
        }
        for (offset, fragment) in fragments {
            let number = document.line(at: offset)
            place(number, on: fragment)
            if issueLines[number + 1] != nil, extraLine(of: fragment) != nil { place(number + 1, on: fragment, extra: true) }
        }
        for former in formerRows {
            changed = true
            setNeedsDisplay(former.band)
            former.message?.view.removeFromSuperview()
        }
        guard changed else { return }
        updateIssueTips()
    }

    private func row(_ number: Int, _ reported: LineIssue, on lines: ArraySlice<NSTextLineFragment>, of fragment: NSTextLayoutFragment,
                     in view: IssueMessageView?) -> IssueRow? {
        guard let first = lines.first else { return nil }
        let band = row(lines, of: fragment)
        var issue = IssueRow(line: number, isError: reported.isError, band: band, shape: NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4),
                             fragment: fragment, frame: fragment.layoutFragmentFrame, width: bounds.width, origin: textContainerOrigin)
        // The fragment's lines in the view: its frame has the line fragment's padding in it.
        let left = textContainerOrigin.x + fragment.layoutFragmentFrame.minX
        let top = textContainerOrigin.y + fragment.layoutFragmentFrame.minY
        let said = [reported.message] + reported.others
        let label = issueLabels[number] ?? IssueLabel(reported.message, others: reported.others.count, font: issueFont)
        issueLabels[number] = label
        let end = band.maxX - 1
        let room = end - (left + first.typographicBounds.maxX) - issueGap
        let fitted = label.line(in: room - IssueMessageView.width(ofText: 0, font: issueFont))
        let width = IssueMessageView.width(ofText: fitted?.width, font: issueFont)
        if width <= room {
            let rect = NSRect(x: end - width, y: band.minY, width: width,
                              height: onPixels(top + first.typographicBounds.maxY + rowShift) - band.minY)
            let view = view ?? IssueMessageView()
            let baseline = top + first.typographicBounds.minY + first.glyphOrigin.y - rect.minY
            view.show(fitted?.line, symbol: issueSymbols[reported.isError], font: issueFont, baseline: baseline, in: rect)
            if view.superview !== self { addSubview(view) }
            issue.message = (view, rect, fitted?.cut ?? true)
        }
        if issue.message?.cut != false || said.count > 1 { issue.tip = said.joined(separator: "\n") }
        // 27.2: TextKit 2 draws no underline given as a rendering attribute (of an underline, a strikethrough, a
        // spelling state and a background colour it drew the last two), so it is drawn here, under the text.
        let commands = said.compactMap(UndefinedCommand.named)
        if !commands.isEmpty, let font {
            let scale = window?.backingScaleFactor ?? 1
            func whole(_ length: CGFloat) -> CGFloat { (length * scale).rounded() / scale }
            let thickness = max(1, whole(font.underlineThickness))
            let paragraph = first.attributedString.string as NSString
            for range in commands.flatMap({ UndefinedCommand.ranges(of: $0, in: paragraph) }) {
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

    private func updateIssueTips() {
        var tips: [(rect: NSRect, text: String)] = []
        for issue in issueRows {
            if let tip = issue.tip, let message = issue.message { tips.append((message.rect, tip)) }
        }
        guard !tips.elementsEqual(issueTips, by: { $0.rect == $1.rect && $1.text.isEqual(to: $0.text) }) else { return }
        for tip in issueTips { removeToolTip(tip.tag) }
        // The string is the tag's owner, which AppKit asks for its description and doesn't keep.
        issueTips = tips.map { tip in
            let text = tip.text as NSString
            return (addToolTip(tip.rect, owner: text, userData: nil), tip.rect, text)
        }
    }

    private func issueMessage(at event: NSEvent) -> IssueRow? {
        guard !issueRows.isEmpty else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return nil }
        return issueRows.first { $0.message?.rect.contains(point) == true }
    }

    // MARK: the colours

    var syntaxTheme = SyntaxTheme.overleaf {
        didSet { if syntaxTheme != oldValue { colour(from: 0) } }
    }

    private var staleColours: Int?

    /// TextKit validates colours when it lays a fragment out anew, without editing the document's attributes;
    /// the fragments already shown keep none until validated here.
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

    /// 27.2: each shown fragment draws in a view of its own, which new rendering attributes don't redraw, nor does the text view's own display.
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
    }

    override func becomeFirstResponder() -> Bool {
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

    private var keyWatches: [NotificationCenter.ObservationToken] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyWatches = []
        guard let window else { return }
        keyWatches = [
            NotificationCenter.default.addObserver(of: window, for: .didBecomeKey) { [weak self] _ in self?.keyChanged() },
            NotificationCenter.default.addObserver(of: window, for: .didResignKey) { [weak self] _ in self?.keyChanged() },
        ]
    }

    private func keyChanged() {
        if !hasKeyboard { closeCompletions() }
        previewMath()
    }

    private var hasKeyboard: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    // MARK: the maths preview

    private var mathPopover: MathPopover?
    private var lastMath: (caret: Int, edits: Int, value: MathPreview?)?
    private var edits = 0
    private var dismissedMath: Int?

    private func math(at caret: Int) -> MathPreview? {
        if let lastMath, lastMath.caret == caret, lastMath.edits == edits { return lastMath.value }
        let value = document.mathAt(caret: caret)
        lastMath = (caret, edits, value)
        return value
    }

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

    private func character(at i: Int) -> Character? {
        guard i >= 0, i < text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: i)).first
    }

    /// Brackets are ASCII, so code units compare exactly.
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

    private func showPartner(of at: Int) {
        guard let i = partner(of: at), let first = fragments.first, let last = fragments.last,
              first.offset <= i, i < offset(last.fragment.rangeInElement.endLocation) else { return }
        let range = NSRange(location: i, length: 1)
        guard reducesMotion(), let manager = textLayoutManager, let marked = textRange(range) else { return showFindIndicator(for: range) }
        // The find indicator bounces: with Reduce Motion the partner is filled where it is, until the selection next changes.
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

    private var closers: Set<Int> = []
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
            // A closer put in as \] or \}: its bracket steps over both, and a backslash typed for it goes.
            if next == "\\", character(at: selection.location + 1) == c {
                closers.remove(selection.location)
                var bracket = selection.location + 1
                if text.isEscaped(at: selection.location) {
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
                super.insertText(text.isEscaped(at: selection.location) ? "\(c)\\\(close)" : "\(c)\(close)", replacementRange: selection)
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

    private func closer(after caret: Int) -> Int? {
        guard let close = character(at: caret - 1).flatMap({ Self.pairs[$0] }) else { return nil }
        if character(at: caret) == close { return 1 }
        return text.isEscaped(at: caret - 1) && character(at: caret) == "\\" && character(at: caret + 1) == close ? 2 : nil
    }

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

    private func tab(_ step: Int) {
        if snippet != nil { return moveField(step) }
        let edits = document.indent(selectedRanges.map(\.rangeValue), more: step > 0)
        apply(edits, named: step > 0 ? String(localized: "Indent") : String(localized: "Outdent"))
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        EditorPrefs.spellCheck = isContinuousSpellCheckingEnabled
    }

    /// Never goes on to the window, whose Escape would leave full screen.
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

    private(set) var offered: Completions?
    private lazy var completionList: CompletionList = {
        let list = CompletionList()
        list.clicked = { [unowned self] in acceptCompletion($0) }
        return list
    }()
    private var typing = false

    private var caret: Int { selectedRange().location }

    private func offerCompletions() {
        if EditorPrefs.autoComplete || offered != nil { complete(explicit: false) }
    }

    override func complete(_ sender: Any?) { complete(explicit: true) }

    private func complete(explicit: Bool) {
        guard selectedRange().length == 0, selectedRanges.count == 1, !hasMarkedText(),
              let found = document.completions(caret: caret, explicit: explicit) else {
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

    /// Without a window it holds its items unseen, as the tests use it.
    private func showCompletions(reload: Bool) {
        guard let offered else { return }
        var start = NSRect.zero, shown = NSRect.zero, host: NSScrollView?
        if let window, let scroll = enclosingScrollView {
            host = scroll
            start = scroll.convert(window.convertFromScreen(
                firstRect(forCharacterRange: NSRange(location: offered.start, length: 0), actualRange: nil)), from: nil)
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
        if host != nil { previewMath() }
    }

    /// Escape is `cancelOperation` here: the text view's own goes straight to its `complete(_:)`.
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

    private func acceptCompletion(_ index: Int) {
        guard let offered, offered.items.indices.contains(index), caret >= offered.start else { return closeCompletions() }
        let item = offered.items[index]
        closeCompletions()
        apply([TextEdit(NSRange(location: offered.start, length: caret - offered.start), item.text)], named: String(localized: "Completion"),
              select: NSRange(location: offered.start + (item.text as NSString).length, length: 0))
        startSnippet(item.fields, at: offered.start)
    }

    // MARK: snippet fields

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

    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown, inGutter(event) { return selectLines(with: event) }
        if event.type == .leftMouseDown, let issue = issueMessage(at: event), clicked(issue, with: event) { return }
        super.mouseDown(with: event)
        if event.type == .leftMouseDown, event.clickCount == 2 { forwardSync(true)?() }
    }

    /// False for a drag, Shift-click and double-click, which are the text view's.
    private func clicked(_ issue: IssueRow, with down: NSEvent) -> Bool {
        guard down.clickCount == 1, down.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) else { return false }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if issue.message?.rect.contains(convert(next.locationInWindow, from: nil)) == true { issueClicked(issue.line) }
                break
            }
            if hypot(next.locationInWindow.x - down.locationInWindow.x, next.locationInWindow.y - down.locationInWindow.y) > 3 {
                window?.postEvent(next, atStart: true)
                return false
            }
        }
        return true
    }

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
            let at = characterIndexForInsertion(at: convert(info.draggingLocation, from: nil))
            apply([TextEdit(NSRange(location: at, length: 0), text)], named: String(localized: "Insert Figure"),
                  select: NSRange(location: at, length: (text as NSString).length))
            window?.makeFirstResponder(self)
        }
        return true
    }

    // MARK: VoiceOver's rotors

    var headings: () -> [(line: Int, title: String)] = { [] }
    private lazy var rotors = [NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self),
                               NSAccessibilityCustomRotor(label: String(localized: "Issues"), itemSearchDelegate: self)]

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] { rotors }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor search: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        var items = rotor.type == .heading ? headings() : issueLines.sorted { $0.key < $1.key }.map { line, issue in
            let place = issue.isError ? String(localized: "Error on line \(line)") : String(localized: "Warning on line \(line)")
            return (line, String(localized: "\(place): \(issue.message)"))
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

/// 27.2: TextKit draws a selection in a view above the text view's background (`_NSTextSelectionView`), which would
/// cover a box drawn there; this view sits above the text's views, takes no click, and the text view answers for it.
final class IssueMessageView: NSView {
    private var line: CTLine?
    private var symbol: NSImage?
    private var baseline: CGFloat = 0
    private var font = NSFont.systemFont(ofSize: 13)

    private static func measures(_ font: NSFont) -> (segment: CGFloat, padding: CGFloat) {
        ((2 * font.pointSize).rounded(), (font.pointSize / 2).rounded())
    }

    static func width(ofText text: CGFloat?, font: NSFont) -> CGFloat {
        let measures = measures(font)
        return measures.segment + (text.map { 1 + (2 * measures.padding + $0).rounded(.up) } ?? 0)
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func show(_ line: CTLine?, symbol: NSImage?, font: NSFont, baseline: CGFloat, in rect: NSRect) {
        if line !== self.line || symbol !== self.symbol || font != self.font || baseline != self.baseline { needsDisplay = true }
        (self.line, self.symbol, self.font, self.baseline) = (line, symbol, font, baseline)
        if rect != frame { frame = rect }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let measures = Self.measures(font)
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        ((superview as? NSTextView)?.backgroundColor ?? .textBackgroundColor).setFill()
        box.fill()
        NSColor.separatorColor.set()
        box.stroke()
        if line != nil { NSRect(x: measures.segment, y: 0, width: 1, height: bounds.height).fill() }
        if let symbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: (measures.segment - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        guard let line else { return }
        NSColor.labelColor.setFill()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: measures.segment + 1 + measures.padding, y: baseline)
        CTLineDraw(line, context)
    }
}

struct IssueLabel {
    private let whole: CTLine, ending: CTLine
    private let short: (line: CTLine, width: CGFloat)?
    let width: CGFloat
    private let endingWidth: CGFloat

    static let least = 10
    private static let saysError = "LaTeX Error: "

    init(_ message: String, others: Int, font: NSFont) {
        // One line, without LaTeX's words for what the symbol beside it says already.
        var message = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if message.hasPrefix(Self.saysError) { message.removeFirst(Self.saysError.count) }
        let count = others > 0 ? "  +\(others)" : ""
        short = UndefinedCommand.named(in: message).map { typeset(String(localized: "Undefined: \($0)") + count, in: font) }
        (whole, width) = typeset(message + count, in: font)
        (ending, endingWidth) = typeset("…" + count, in: font)
    }

    func line(in room: CGFloat) -> (line: CTLine, width: CGFloat, cut: Bool)? {
        if width <= room { return (whole, width, false) }
        if let short, short.width <= room { return (short.line, short.width, true) }
        let most = short?.line ?? whole
        guard CTLineGetStringIndexForPosition(most, CGPoint(x: room - endingWidth, y: 0)) >= Self.least,
              let cut = CTLineCreateTruncatedLine(most, Double(room), .end, ending) else { return nil }
        return (cut, CGFloat(CTLineGetTypographicBounds(cut, nil, nil, nil)), true)
    }
}

private func typeset(_ string: String, in font: NSFont) -> (line: CTLine, width: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
    return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}

enum UndefinedCommand {
    /// For no other message: one in a file TeX loaded has that file's name before it, and its command isn't on a line of this file.
    static func named(in message: String) -> String? {
        let words = "Undefined control sequence: \\"
        guard message.hasPrefix(words) else { return nil }
        let name = message.dropFirst(words.count)
        // TeX's own two forms: letters, or one character of any other kind.
        guard name.count == 1 || (!name.isEmpty && name.allSatisfy(isLetter)) else { return nil }
        return "\\" + name
    }

    private static func isLetter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character == "@")
    }

    /// Not after a backslash that is itself a command's (`\\foo` is a line break and a word), and not in a comment.
    static func ranges(of command: String, in line: NSString) -> [NSRange] {
        var end = 0
        while end < line.length, line.character(at: end) != 0x25 || line.isEscaped(at: end) { end += 1 }
        let word = command.dropFirst().first.map(isLetter) ?? false
        var found: [NSRange] = [], from = 0
        while from < end {
            let range = line.range(of: command, options: .literal, range: NSRange(location: from, length: end - from))
            guard range.location != NSNotFound else { break }
            from = NSMaxRange(range)
            let next = from < line.length ? Unicode.Scalar(line.character(at: from)).map(Character.init) : nil
            if !line.isEscaped(at: range.location), !(word && next.map(isLetter) == true) { found.append(range) }
        }
        return found
    }
}

private extension NSString {
    func isEscaped(at: Int) -> Bool {
        var slashes = 0
        while at - slashes > 0, character(at: at - slashes - 1) == 0x5C { slashes += 1 }
        return slashes % 2 == 1
    }
}

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
        let command: NSColor
        let argument: NSColor
        let maths: NSColor
        let comment: NSColor
        let invalid: NSColor
    }

    var colours: Colours {
        switch self {
        case .overleaf: Self.overleafColours
        case .texstudio: Self.texstudioColours
        case .system: Self.systemColours
        }
    }

    /// The themes' own colours fall short of the HIG's 4.5:1 in places, so each is raised to it, and further with Increase Contrast.
    private static func rgb(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func srgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let light = srgb(light), dark = srgb(dark)
        return NSColor(name: nil) { @Sendable in $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }.legibleAsText
    }

    private static let overleafColours = Colours(
        command: rgb(0x0000FF, 0x8BE9FD), argument: rgb(0x318495, 0xFFB86C),
        maths: rgb(0x036A07, 0xF1FA8C), comment: rgb(0x4C886B, 0x6272A4), invalid: rgb(0xFF0000, 0xFF79C6))

    private static let texstudioColours = Colours(
        command: rgb(0x800000, 0x60CDF2), argument: rgb(0x008000, 0x60F260),
        maths: rgb(0x509600, 0x85F218), comment: rgb(0x808080, 0x667299), invalid: rgb(0xC00000, 0xF2F218))

    private static let systemColours = Colours(
        command: .systemPink.legibleAsText, argument: .systemTeal.legibleAsText,
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
