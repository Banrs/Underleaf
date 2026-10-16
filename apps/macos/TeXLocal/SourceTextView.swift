import AppKit
import SwiftUI

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

    /// The text's mirror: a project session's document, whose edits it saves and previews, or the view's own.
    private(set) var document = SourceDocument(text: "")
    /// Reads the storage's UTF-16 units in place: `string` bridges the whole text on every call.
    var text: NSString { textStorage?.mutableString ?? "" }
    var fileDrop: (URL) -> FileDrop? = { _ in nil }

    enum FileDrop {
        case open(() -> Void)
        case insert(String)
    }
    var forwardSync: (_ quietly: Bool) -> (() -> Void)? = { _ in nil }

    private(set) var loading = false

    /// `source` is the session's document holding `text`; without one the view keeps a mirror of its own.
    func load(_ text: String, source: SourceDocument? = nil) {
        takeText(text)
        document = source ?? SourceDocument(text: text)
        loaded()
    }

    /// The disk's text, from the session's `document_reload`: shown without an edit, then the session told it is shown.
    func reload(_ text: String) {
        takeText(text)
        document.reload(text)
        loaded()
    }

    private func takeText(_ text: String) {
        loading = true
        // Else typing coalesced into the last file's undo would go on in this one's.
        breakUndoCoalescing()
        fragments.removeAll(keepingCapacity: true)
        placeIssues()
        inputContext?.discardMarkedText()
        unmarkText()
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
    }

    private func loaded() {
        lastMath = nil
        dismissedMath = nil
        _ = document.endSnippet()
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
        edits += 1
        staleColours = min(staleColours ?? edited.location, edited.location)
        // The closers typing put in and a snippet's fields move with the text.
        document.follow(old, delta: delta, changing: changing, mirroring: mirroring)
        changing = nil
        if lineCountDigits != digits(document.lineCount) {
            // After the edit: a layout change mid-edit would lay out stale text.
            Task { self.updateGutterWidth() }
        }
    }

    /// The selections follow the edits, unless `select` is given.
    func apply(_ edits: [TextEdit], named name: String, select: NSRange? = nil) {
        guard !edits.isEmpty else { return }
        let selections = select.map { [$0] } ?? document.map(selectedRanges.map(\.rangeValue), through: edits)
        apply(edits, named: name, selecting: selections)
    }

    /// The core's edits, and the selections after them. False for none.
    @discardableResult
    func apply(_ change: Change?, named name: String) -> Bool {
        guard let change, !change.edits.isEmpty else { return false }
        apply(change.edits, named: name, selecting: change.selections.map(\.range))
        return true
    }

    /// One undo step, from the last edit.
    private func apply(_ edits: [TextEdit], named name: String, selecting selections: [NSRange]) {
        undoManager?.beginUndoGrouping()
        for edit in edits.reversed() {
            if shouldChangeText(in: edit.range, replacementString: edit.text) {
                textStorage?.replaceCharacters(in: edit.range, with: edit.text)
                didChangeText()
            }
        }
        undoManager?.setActionName(name)
        undoManager?.endUndoGrouping()
        if !selections.isEmpty {
            setSelectedRanges(selections.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        }
        scrollRangeToVisible(selectedRange())
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
        // Xcode's numbers: SF at the issue symbol's size, a little narrower than semi-condensed (74 on SF's width axis to
        // its 80), tabular, with the open 4, 6 and 9 (SF's first two stylistic sets), never under the HIG's 10 points.
        let numbers = NSFont.systemFont(ofSize: max(10, IssueBox.Metrics.small(fontSize)), weight: .regular, width: NSFont.Width(rawValue: -0.1))
        var axes = CTFontCopyVariation(numbers) as? [NSNumber: NSNumber] ?? [:]
        axes[0x7764_7468 as NSNumber] = 74 // 'wdth'
        numberFont = NSFont(descriptor: numbers.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): axes,
            .featureSettings: [
                [NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector],
                [NSFontDescriptor.FeatureKey.typeIdentifier: kStylisticAlternativesType, .selectorIdentifier: kStylisticAltOneOnSelector],
                [NSFontDescriptor.FeatureKey.typeIdentifier: kStylisticAlternativesType, .selectorIdentifier: kStylisticAltTwoOnSelector]]]),
            size: 0) ?? numbers
        issueFont = .systemFont(ofSize: fontSize)
        issueGap = ("0" as NSString).size(withAttributes: [.font: font]).width
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
        /// The core's line-end form of it.
        var short: String
        /// The command an "Undefined control sequence" names, underlined where the line has it.
        var command: String?
        var others: [String] = []
    }

    var issueLines: [Int: LineIssue] = [:] {
        didSet { if issueLines != oldValue { issuesChanged() } }
    }
    var issueClicked: (Int) -> Void = { _ in }

    var showsLineNumbers = true {
        didSet { if showsLineNumbers != oldValue { updateGutterWidth() } }
    }

    private func digits(_ n: Int) -> Int { max(4, String(n).count) }

    /// Where the current line's and an issue's band start, and where the numbers would end without them.
    private static let bandStart: CGFloat = 14
    /// The room after the text and the bands.
    private static let trailingMargin: CGFloat = 8
    /// Where a number's first digit ends: Xcode's four-digit numbers end 39.7 pt in at 13 pt (fitted to its gutter as drawn).
    private static let firstDigitEnd: CGFloat = 19.8
    /// From the numbers to the text, which starts on a whole point, as Xcode's does (51 at 13 pt).
    private static let numbersToText: CGFloat = 11

    func updateGutterWidth() {
        lineCountDigits = digits(document.lineCount)
        numbersEnd = showsLineNumbers ? Self.firstDigitEnd + CGFloat(lineCountDigits - 1) * digitWidth : Self.bandStart
        let width = (numbersEnd + Self.numbersToText).rounded(.up) - (textContainer?.lineFragmentPadding ?? 0)
        guard width != gutterWidth else { return }
        gutterWidth = width
        // The container tracks the view's width less twice this: the gutter and the margin after the text.
        textContainerInset.width = (gutterWidth + Self.trailingMargin) / 2
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
        textContainer?.size.width = max(0, size.width - gutterWidth - Self.trailingMargin)
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

    /// What of the text shows: the clip view's bounds less the scroll view's insets for the bars over it.
    var shownRect: NSRect {
        guard let scroll = enclosingScrollView else { return visibleRect }
        let insets = scroll.contentInsets
        var shown = convert(scroll.contentView.bounds, from: scroll.contentView)
        shown.origin.y += insets.top
        shown.size.height -= insets.top + insets.bottom
        return shown
    }

    /// From the fragments last laid out: asked by point, TextKit answers from its new estimates.
    var shownTop: (offset: Int, below: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView, let top = fragment(under: shownRect.minY) else { return nil }
        return (offset(top.rangeInElement.location), top.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.minY)
    }

    /// The line half a line under the shown text's top, from the fragments last laid out as `shownTop` is; nil while
    /// they don't reach there, which the viewport's next layout does (`laidOut`).
    var topLine: Int? {
        let y = shownRect.minY + (font?.boundingRectForFont.height ?? 0) / 2
        guard let top = fragment(under: y), top.layoutFragmentFrame.minY + textContainerOrigin.y <= y else { return nil }
        return document.line(at: offset(top.rangeInElement.location))
    }

    /// The first fragment laid out that reaches below `y`.
    private func fragment(under y: CGFloat) -> NSTextLayoutFragment? {
        fragments.first { $0.fragment.layoutFragmentFrame.maxY + textContainerOrigin.y > y }?.fragment
    }

    /// Each time TextKit lays out the viewport: a scroll past what it had laid out, an edit, a new width.
    var laidOut: () -> Void = {}

    /// 27.2: AppKit's Jump to Selection lands lines off where TextKit 2 has only estimated the heights above.
    override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let clip = enclosingScrollView?.contentView, let manager = textLayoutManager,
              let location = textRange(NSRange(location: selectedRange().location, length: 0))?.location
        else { return super.centerSelectionInVisibleArea(sender) }
        // The shown text's middle, under the clip view's top.
        let middle = shownRect.midY - clip.bounds.minY
        scroll(location) { [unowned self] paragraph in
            guard let fragment = manager.textLayoutFragment(for: location) else { return paragraph.midY - middle }
            let inParagraph = offset(location) - offset(fragment.rangeInElement.location)
            let line = fragment.textLineFragments.last { $0.characterRange.location <= inParagraph } ?? fragment.textLineFragments.first
            return paragraph.minY + (line?.typographicBounds.midY ?? paragraph.height / 2) - middle
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
        laidOut()
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
        return NSRect(x: Self.bandStart, y: top, width: bounds.width - Self.bandStart - Self.trailingMargin, height: bottom - top)
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

    /// The numbers' grey, raised with Increase Contrast as the syntax colours are (`displayOptionsChanged` redraws them).
    private static let numberColor: NSColor = {
        let raised: [NSAppearance.Name] = [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        return .adapting(Dictionary(uniqueKeysWithValues: raised.map { ($0, NSColor.tertiaryLabelColor.legibleAsText(in: $0)) }),
                         fallback: .tertiaryLabelColor)
    }()

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
        // The caret's line has the current line's fill, which is the same shape, and not both.
        for issue in issueRows where issue.band.maxY >= rect.minY && issue.band.minY <= rect.maxY {
            if issue.line != current?.number {
                Self.issueFill.setFill()
                issue.shape.fill()
            }
            NSColor.systemRed.setFill()
            issue.tokens.forEach { $0.fill() }
        }
        guard rect.minX < numbersEnd + 4, showsLineNumbers else { return }
        for (offset, fragment) in fragments {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: origin.y)
            guard frame.maxY >= rect.minY, frame.minY <= rect.maxY, let line = fragment.textLineFragments.first else { continue }
            let lineNumber = document.line(at: offset)
            func draw(_ lineNumber: Int, on line: NSTextLineFragment) {
                (lineNumber == current?.number ? .labelColor : Self.numberColor).setFill()
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
        /// The undefined command's underlines, where the line has it.
        var tokens: [NSRect] = []
        let fragment: NSTextLayoutFragment
        let frame: NSRect
        let width: CGFloat
        let origin: NSPoint
    }

    private(set) var issueRows: [IssueRow] = []
    private var issuesStale = false
    /// The messages as measured, by line: for these issues and this font.
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
        let label = issueLabels[number] ?? IssueLabel(reported.short, command: reported.command, font: issueFont)
        issueLabels[number] = label
        typealias Metrics = IssueBox.Metrics
        let end = band.maxX - Metrics.endInset
        let room = end - (left + first.typographicBounds.maxX) - issueGap
        let issues = said.count
        let fitted = label.text(in: room - Metrics.width(ofText: 0, font: issueFont, issues: issues))
        // A message cut short takes all the room there is, on whole points, as Xcode's does.
        let width = fitted?.cut == true ? room.rounded(.down) : Metrics.width(ofText: fitted?.width, font: issueFont, issues: issues)
        if width <= room {
            let foot = onPixels(top + first.typographicBounds.maxY + rowShift)
            let rect = NSRect(x: end - width, y: band.minY, width: width, height: foot - band.minY)
            let box = IssueBox(isError: reported.isError, issues: issues, text: fitted?.text, font: issueFont, fill: Color(nsColor: backgroundColor),
                               baseline: top + first.typographicBounds.minY + first.glyphOrigin.y - rect.minY)
            let view = view ?? IssueMessageView(box)
            view.rootView = box
            if view.frame != rect { view.frame = rect }
            if view.superview !== self { addSubview(view) }
            issue.message = (view, rect, fitted?.cut ?? true)
        }
        if issue.message?.cut != false || said.count > 1 { issue.tip = said.joined(separator: "\n") }
        // Underlined in the system's red, as Xcode does an issue's token, under the text: TextKit 2 draws no underline
        // given as a rendering attribute (27.2).
        if let command = reported.command, let font {
            // As far under the baseline as the font puts an underline, a point thick at least, on whole pixels.
            let scale = window?.backingScaleFactor ?? 1
            func whole(_ length: CGFloat) -> CGFloat { (length * scale).rounded() / scale }
            let thickness = max(1, whole(font.underlineThickness))
            for range in (first.attributedString.string as NSString).ranges(ofCommand: command) {
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
                        manager.setRenderingAttributes([.foregroundColor: syntaxTheme.color(run.kind)], for: range)
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
        // A snippet ends once the selection leaves its fields, and closers before its line are no longer stepped over.
        document.select(selectedRange(), mirroring: mirroring)
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
        guard let window, hasKeyboard, let maths, dismissedMath == nil, enclosingScrollView != nil else {
            mathPopover?.close()
            return
        }
        let screen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        // A point wide: NSPopover takes an empty rect for the whole view.
        var rect = convert(window.convertFromScreen(screen), from: nil)
        rect.size.width = max(rect.width, 1)
        guard shownRect.contains(NSPoint(x: rect.minX, y: rect.midY)) else {
            mathPopover?.close()
            return
        }
        if mathPopover == nil { mathPopover = MathPopover() }
        mathPopover?.show(maths, size: fontSize, at: rect, of: self,
                          edge: offered != nil && completionList.isAbove ? .maxY : .minY)
    }

    private func showPartner(of at: Int) {
        guard at >= 0, at < text.length, let i = document.partner(of: at), let first = fragments.first, let last = fragments.last,
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

    // MARK: typing: the core's brackets, indentation and snippet fields

    /// Settings' typing: brackets closed as they're typed, and completions offered as a command is.
    var autoPair = true, autoComplete = true

    /// Told as marked (IME) text comes and goes: the session's autosave waits for it to be committed.
    var composing: (Bool) -> Void = { _ in }
    private var toldComposing = false

    private func markedTextChanged() {
        guard hasMarkedText() != toldComposing else { return }
        toldComposing.toggle()
        composing(toldComposing)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedTextChanged()
    }

    override func unmarkText() {
        super.unmarkText()
        markedTextChanged()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasTyping = typing
        typing = true
        defer {
            typing = wasTyping
            markedTextChanged()
        }
        guard let typed = string as? String, replacementRange.location == NSNotFound, !hasMarkedText(), selectedRanges.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            closeCompletions()
            return
        }
        let stroke = document.type(typed, replacing: selectedRange(), autoPair: autoPair)
        if let edit = stroke.edit {
            super.insertText(edit.text, replacementRange: edit.range)
        } else if stroke.selection == nil {
            super.insertText(string, replacementRange: replacementRange)
        }
        finish(stroke)
    }

    /// What follows a key's edit: the selection, the bracket's partner and the completion list.
    private func finish(_ stroke: Keystroke) {
        if let selection = stroke.selection { setSelectedRange(selection.range) }
        if let partner = stroke.partner { showPartner(of: partner) }
        switch stroke.completions {
        case .keep: break
        case .offer: offerCompletions()
        case .close: closeCompletions()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let wasTyping = typing, completing = offered != nil
        typing = true
        defer {
            typing = wasTyping
            if completing { offerCompletions() }
        }
        guard selectedRanges.count == 1, let edit = document.deleteBackward(selectedRange(), autoPair: autoPair).edit
        else { return super.deleteBackward(sender) }
        insertText(edit.text, replacementRange: edit.range)
    }

    override func insertNewline(_ sender: Any?) {
        guard selectedRanges.count == 1 else { return super.insertNewline(sender) }
        let stroke = document.insertNewline(selectedRange())
        guard let edit = stroke.edit else { return super.insertNewline(sender) }
        insertText(edit.text, replacementRange: edit.range)
        finish(stroke)
    }

    override func insertTab(_ sender: Any?) { tab(1) }

    override func insertBacktab(_ sender: Any?) { tab(-1) }

    /// A snippet's next field, or the lines indented.
    private func tab(_ step: Int) {
        let answer = document.tab(selectedRanges.map(\.rangeValue), step: step)
        if let field = answer.field {
            setSelectedRange(field.range)
        } else {
            apply(answer.edits, named: step > 0 ? String(localized: "Indent") : String(localized: "Outdent"))
        }
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        EditorPrefs.spellCheck = isContinuousSpellCheckingEnabled
    }

    /// Never goes on to the window, whose Escape would leave full screen.
    override func cancelOperation(_ sender: Any?) {
        if offered != nil {
            closeCompletions()
        } else if document.endSnippet() {
            // Escape leaves the snippet's fields.
        } else if mathPopover?.isWanted == true, let maths = math(at: caret) {
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
        if autoComplete || offered != nil { complete(explicit: false) }
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
            shown = scroll.convert(shownRect, from: self)
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

    /// The core's mirror edits are going in: they move the fields without ending the snippet.
    private var mirroring = false

    func startSnippet(_ fields: [SnippetField], at location: Int) {
        guard let first = document.startSnippet(fields, at: location) else { return }
        setSelectedRange(first)
    }

    /// What's typed in a field goes in its other places.
    override func didChangeText() {
        super.didChangeText()
        guard !mirroring else { return }
        let edits = document.mirrorSnippet()
        guard !edits.isEmpty else { return }
        let selection = selectedRange()
        mirroring = true
        for edit in edits where shouldChangeText(in: edit.range, replacementString: edit.text) {
            textStorage?.replaceCharacters(in: edit.range, with: edit.text)
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
