import AppKit

/// The source's text view: TextKit 2's own, which types, selects, undoes,
/// spells, speaks and drags as every Mac text view does. The core
/// (`SourceDocument`, crates/texlocal-syntax) says what the LaTeX is; this
/// draws the line numbers and colours, and edits as the web's editor does:
/// completion with snippet fields, closing brackets, keeping indentation,
/// and the core's edits in one undo step each.
final class SourceTextView: FindPassingTextView, NSTextStorageDelegate {
    /// The open file's text as the core mirrors it; every change reaches it.
    private(set) var document = SourceDocument(text: "")
    var palette = EditorPalette.standard {
        didSet { recolour() }
    }
    /// The project's labels and citations, for completion.
    var symbols = Symbols(citations: [], labels: [])
    /// Where the find bar's query matches, in order.
    var findMatches: [NSRange] = [] {
        didSet { if findMatches != oldValue { needsDisplay = true } }
    }
    /// What dropping a file does, or nil to refuse it.
    var fileDrop: (URL) -> (() -> Void)? = { _ in nil }
    /// Escape, before anything of the text view's: true when it closed something.
    var escape: () -> Bool = { false }
    /// Go to PDF Position, or nil while there's no PDF or no TeX open.
    var forwardSync: () -> (() -> Void)? = { nil }

    /// The text is being replaced whole: no edit of the user's.
    private var loading = false

    /// Replaces the text, which starts a new mirror; nothing to undo.
    func load(_ text: String) {
        // Typing coalesced into the last file's undo would go on in its.
        breakUndoCoalescing()
        loading = true
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
        document = SourceDocument(text: text)
        snippet = nil
        closers.removeAll()
        updateGutterWidth()
        recolour()
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
        // The fields follow the change itself, when it's the one expected.
        let changed = changing.flatMap { $0.location == old.location && NSMaxRange($0) <= NSMaxRange(old) ? $0 : nil }
        changing = nil
        follow(changed ?? old, delta)
        coloured = nil
        if lineCountDigits != digits(document.lineCount) {
            // After the edit: a layout change mid-edit would lay out stale text.
            DispatchQueue.main.async { self.updateGutterWidth() }
        }
    }

    /// The core's edits, in order, applied from the last in one undo step:
    /// the selection follows the text, or becomes `select`.
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

    /// A position after edits (in order): moved with the text after them.
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

    // MARK: the gutter

    private var gutterWidth: CGFloat = 0
    private var lineCountDigits = 0
    /// The fragments laid out for the viewport: where each starts, its frame.
    private var fragments: [(offset: Int, fragment: NSTextLayoutFragment)] = []

    private var numberFont: NSFont {
        .monospacedSystemFont(ofSize: max(8, (font?.pointSize ?? NSFont.systemFontSize) - 2), weight: .regular)
    }

    private func digits(_ n: Int) -> Int { max(2, String(n).count) }

    /// Room for the largest line number, 8 pt either side of it.
    func updateGutterWidth() {
        lineCountDigits = digits(document.lineCount)
        let digit = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        let width = (CGFloat(lineCountDigits) * digit + 16).rounded(.up)
        guard width != gutterWidth else { return }
        gutterWidth = width
        // The view sizes its container, less the inset either side: the gutter and
        // 4 pt, and 8 pt at the end, shared out.
        textContainerInset.width = (textContainerOrigin.x + 8) / 2
        needsDisplay = true
    }

    /// The text starts after the gutter, and 4 pt in from it.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: gutterWidth + 4, y: textContainerInset.height)
    }

    // The top paragraph stays put: TextKit 2 keeps the offset, over heights a new width re-estimates (27.2).
    override func setFrameSize(_ size: NSSize) {
        guard size.width != frame.width else { return super.setFrameSize(size) }
        keepingTopLine {
            super.setFrameSize(size)
            // As it goes: scrolled down, AppKit's tracking waits for a live resize's end (27.2).
            textContainer?.size.width = max(0, size.width - 2 * textContainerInset.width)
        }
    }

    private func keepingTopLine(_ change: () -> Void) {
        // From the fragments last laid out: asked by point, TextKit answers from its new estimates.
        guard let clip = enclosingScrollView?.contentView,
              let top = fragments.first(where: { $0.fragment.layoutFragmentFrame.maxY + textContainerOrigin.y > clip.bounds.minY + clip.contentInsets.top })?.fragment
        else { return change() }
        let offset = top.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.minY
        change()
        scroll(top.rangeInElement.location) { $0.minY - offset }
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

    // macOS 27's viewport hooks: the line numbers and colours of what shows.

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
        colourViewport()
        needsDisplay = true
    }

    /// The current line's fill, then the numbers, the current one in the
    /// text's colour, on the first line of their paragraph's baseline.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let origin = textContainerOrigin
        let caret = selectedRange().location, length = (string as NSString).length
        // The paragraph the caret is in, if it shows.
        let entry = fragments.last { $0.offset <= caret }.flatMap { entry in
            let end = offset(entry.fragment.rangeInElement.endLocation)
            return caret < end || end == length ? entry : nil
        }
        let current = entry?.offset
        if let entry {
            // Its lines and the spacing under the last, which TextKit lays
            // out at the top of the next paragraph.
            let frame = entry.fragment.layoutFragmentFrame, lines = entry.fragment.textLineFragments
            let top = frame.minY + (lines.first?.typographicBounds.minY ?? 0)
            let bottom = frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height) + (defaultParagraphStyle?.lineSpacing ?? 0)
            NSColor.quaternarySystemFill.setFill()
            NSRect(x: 0, y: origin.y + top, width: bounds.width, height: bottom - top).fill(using: .sourceOver)
        }
        // The find bar's matches, the selection's other places and the brackets, under the text and the selection.
        if let manager = textLayoutManager, let first = fragments.first?.offset, let last = fragments.last {
            let shown = NSRange(location: first, length: offset(last.fragment.rangeInElement.endLocation) - first)
            for (range, color) in tints(in: shown) {
                guard let r = textRange(range) else { continue }
                manager.enumerateTextSegments(in: r, type: .highlight, options: []) { _, rect, _, _ in
                    color.setFill()
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
                    return true
                }
            }
        }
        let font = numberFont
        for (offset, fragment) in fragments {
            guard let line = fragment.textLineFragments.first else { continue }
            let color: NSColor = offset == current ? .textColor : .secondaryLabelColor
            let number = NSAttributedString(string: "\(document.line(at: offset))",
                                            attributes: [.font: font, .foregroundColor: color])
            let baseline = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            let x = gutterWidth - 8 - number.size().width
            number.draw(with: NSRect(x: x, y: baseline, width: number.size().width, height: 0), options: [])
        }
    }

    // MARK: colours

    /// The range last coloured, which covers the viewport and a screen either side.
    private var coloured: Range<Int>?

    private func recolour() {
        coloured = nil
        colourViewport()
    }

    private func colourViewport() {
        guard let manager = textLayoutManager, let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let shown = offset(viewport.location)..<offset(viewport.endLocation)
        if let coloured, coloured.lowerBound <= shown.lowerBound, shown.upperBound <= coloured.upperBound { return }
        let length = (string as NSString).length
        let start = max(0, shown.lowerBound - shown.count), end = min(length, shown.upperBound + shown.count)
        guard let whole = textRange(NSRange(location: start, length: end - start)) else { return }
        manager.removeRenderingAttribute(.foregroundColor, for: whole)
        for run in document.highlights(in: NSRange(location: start, length: end - start)) {
            if let color = palette.color(run.kind), let r = textRange(run.range) { manager.addRenderingAttribute(.foregroundColor, value: color, for: r) }
        }
        coloured = start..<end
    }

    private func tints(in shown: NSRange) -> [(NSRange, NSColor)] {
        let inView = { (r: NSRange) in NSIntersectionRange(r, shown).length > 0 }
        // Every match tinted; the current one is the selection.
        var tints = findMatches.filter(inView).map { ($0, NSColor.findHighlightColor.withAlphaComponent(0.35)) }
        // Only while typing comes here, else the selection is the same grey. CodeMirror's bracket colours.
        if hasKeyboard {
            tints += selectionMatches(in: shown.location..<NSMaxRange(shown)).map { ($0, NSColor.unemphasizedSelectedTextBackgroundColor) }
            tints += brackets.filter { inView($0.0) }.map { range, matched in
                (range, matched ? NSColor(srgbRed: 0x32 / 255, green: 0x8c / 255, blue: 0x82 / 255, alpha: 0x52 / 255)
                    : NSColor(srgbRed: 0xbb / 255, green: 0x55 / 255, blue: 0x55 / 255, alpha: 0x44 / 255))
            }
        }
        return tints
    }

    /// The other places the selection's text is, while it's one short run
    /// on one line (CodeMirror's highlightSelectionMatches).
    private func selectionMatches(in window: Range<Int>) -> [NSRange] {
        let selection = selectedRange()
        guard selectedRanges.count == 1, (1...200).contains(selection.length), findMatches.isEmpty else { return [] }
        let text = string as NSString
        let selected = text.substring(with: selection)
        guard !selected.contains("\n") else { return [] }
        var matches: [NSRange] = []
        var from = window.lowerBound
        while from < window.upperBound, matches.count < 100 {
            let found = text.range(of: selected, options: .literal, range: NSRange(location: from, length: window.upperBound - from))
            guard found.location != NSNotFound else { break }
            if found != selection { matches.append(found) }
            from = found.location + 1
        }
        return matches
    }

    // MARK: the selection

    /// The bracket beside the caret and its partner, or it alone if it has none.
    private var brackets: [(NSRange, Bool)] = []
    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !loading else { return }
        brackets = matchBrackets()
        previewMath()
        if let snippet, !mirroring, !snippet.contains(selectedRange()) { self.snippet = nil }
        let lineStart = (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
        closers = closers.filter { $0 >= lineStart }
        // The lines an insertion made show their colours: their first layout drops them.
        recolour()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        defer {
            needsDisplay = true
            // Once the window has made it first responder.
            DispatchQueue.main.async { self.previewMath() }
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer {
            needsDisplay = true
            mathPopover?.close()
        }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
        }
    }

    @objc private func keyChanged() {
        needsDisplay = true
        previewMath()
    }

    /// The key window's first responder, which typing reaches.
    private var hasKeyboard: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    // MARK: the maths preview

    private var mathPopover: MathPopover?

    /// The maths at the caret, typeset over where it starts, while the text
    /// has the keyboard and that place shows (the web's preview).
    func previewMath() {
        guard let window, hasKeyboard, !loading,
              let maths = document.mathAt(caret: selectedRange().location),
              let clip = enclosingScrollView?.contentView else {
            mathPopover?.close()
            return
        }
        let screen = firstRect(forCharacterRange: NSRange(location: maths.start, length: 1), actualRange: nil)
        let rect = convert(window.convertFromScreen(screen), from: nil)
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
        mathPopover?.show(maths, size: font?.pointSize ?? NSFont.systemFontSize, at: rect, of: self)
    }

    /// The character at a UTF-16 offset, if there's one there.
    private func character(at i: Int) -> Character? {
        let text = string as NSString
        guard i >= 0, i < text.length, let scalar = Unicode.Scalar(text.character(at: i)) else { return nil }
        return Character(scalar)
    }

    /// CodeMirror's bracketMatching: before the caret, then after it, within 10,000 units.
    private func matchBrackets() -> [(NSRange, Bool)] {
        let caret = selectedRange().location
        let opens = Array(Self.pairs.keys), closes = Array(Self.pairs.values)
        for at in [caret - 1, caret] {
            guard let c = character(at: at), opens.contains(c) || closes.contains(c) else { continue }
            let forward = opens.contains(c)
            let partner = forward ? Self.pairs[c]! : Self.pairs.first { $0.value == c }!.key
            var depth = 0, i = at
            while abs(i - at) <= 10_000, let d = character(at: i) {
                if d == c { depth += 1 } else if d == partner { depth -= 1 }
                if depth == 0 { return [(NSRange(location: at, length: 1), true), (NSRange(location: i, length: 1), true)] }
                i += forward ? 1 : -1
            }
            return [(NSRange(location: at, length: 1), false)]
        }
        return []
    }

    // MARK: typing

    /// Closing brackets this view put in, which typing one steps over.
    private var closers: Set<Int> = []
    /// Brackets close by themselves before these (CodeMirror's closeBrackets).
    private static let closeBefore: Set<Character> = [")", "]", "}", ":", ";", ">"]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let typed = string as? String, typed.count == 1, let c = typed.first,
              replacementRange.location == NSNotFound, !hasMarkedText(), selectedRanges.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()
        let text = self.string as NSString
        let next = character(at: selection.location)
        if selection.length == 0, Self.pairs.values.contains(c), next == c, closers.contains(selection.location) {
            closers.remove(selection.location)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        if let close = Self.pairs[c] {
            if selection.length > 0 {
                // Round the selection, which stays selected.
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
        offerCompletions()
    }

    /// An empty pair goes as one; in a line's indentation, back to the
    /// last indent stop.
    override func deleteBackward(_ sender: Any?) {
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

    /// A new line keeps the line's indentation; between an empty pair of
    /// brackets, the closing one goes a line further down.
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
        if escape() { return }
        if snippet != nil {
            snippet = nil
            return
        }
        super.cancelOperation(sender)
    }

    // MARK: completion: the core's items in the system's list

    private var offered: Completions?
    private var completing = false
    private var explicit = true

    private var caret: Int { selectedRange().location }

    private func completions(explicit: Bool) -> Completions? {
        guard selectedRange().length == 0 else { return nil }
        return document.completions(caret: caret, explicit: explicit, symbols: symbols)
    }

    /// After typing, as CodeMirror offers them: the list opens whenever the
    /// core has something for the caret.
    private func offerCompletions() {
        guard !completing, completions(explicit: false) != nil else { return }
        explicit = false
        complete(nil)
        explicit = true
    }

    override func complete(_ sender: Any?) {
        guard !completing, completions(explicit: explicit) != nil else { return }
        // The list runs its own event loop until it closes.
        completing = true
        super.complete(sender)
        completing = false
    }

    override var rangeForUserCompletion: NSRange {
        offered = completions(explicit: explicit)
        guard let offered else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: offered.start, length: caret - offered.start)
    }

    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        offered?.items.map(\.label)
    }

    /// The text changes once, when an item is chosen: its snippet, with the
    /// first field selected. A key typed on closes the list too, but the key
    /// is the user's text, after which the list opens again, narrowed.
    override func insertCompletion(_ word: String, forPartialWordRange range: NSRange, movement: Int, isFinal: Bool) {
        // A typed key closes it with .other, or .right for punctuation and space (27.2).
        let typedOn = NSApp.currentEvent?.type == .keyDown
            && ![NSTextMovement.return.rawValue, NSTextMovement.tab.rawValue].contains(movement)
        guard isFinal, movement != NSTextMovement.cancel.rawValue, !typedOn,
              let item = offered?.items.first(where: { $0.label == word }) else { return }
        insertText(item.text, replacementRange: range)
        startSnippet(item.fields, at: range.location)
    }

    // MARK: snippet fields

    /// Fields with the same index are one field in several places.
    private struct Snippet {
        var fields: [(index: Int, range: NSRange)]
        var active: Int

        func contains(_ selection: NSRange) -> Bool {
            fields.contains { $0.range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.range) }
        }

        /// The active field where it's typed in: its first place.
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

    /// Go to PDF Position for the clicked line (the click puts the caret there), above
    /// the system's items, as the PDF's menu has Go to Source Position.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        // Fonts, substitutions, transformations, speech and layout are for prose, not source.
        menu?.keep([#selector(cut(_:)), #selector(copy(_:)), #selector(paste(_:)), #selector(checkSpelling(_:))])
        guard let menu, forwardSync() != nil else { return menu }
        let item = NSMenuItem(title: MenuCommand.syncForward.title, action: #selector(goToPDF), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func goToPDF() { forwardSync()?() }

    /// VoiceOver's line is the source's, as the gutter's and LaTeX's are, not the wrapped row's.
    override func accessibilityInsertionPointLineNumber() -> Int { document.line(at: selectedRange().location) - 1 }

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

extension NSMenu {
    /// The system's items for the word under the pointer (its spellings, Look Up), which
    /// come before Cut or Copy, then only those with one of these actions or a submenu
    /// holding one, so the system's later additions stay out.
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
