import AppKit

/// Native TextKit 2 handles typing, undo and accessibility. `SourceDocument`
/// supplies LaTeX syntax; this view adds the gutter, colours, completion,
/// brackets and indentation, with core edits grouped into undo steps.
final class SourceTextView: NSTextView, NSTextStorageDelegate {
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
        inputContext?.discardMarkedText()
        unmarkText()
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
        document = SourceDocument(text: text)
        snippet = nil
        closers.removeAll()
        closeCompletions()
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
        // Scrolled, it follows the text.
        if offered != nil { showCompletions(reload: false) }
        needsDisplay = true
    }

    /// Draw the current line and numbers on each paragraph's first baseline.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let origin = textContainerOrigin
        let caret = selectedRange().location, length = (string as NSString).length
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
        if let manager = textLayoutManager, hasKeyboard {
            for (range, matched) in brackets {
                guard let r = textRange(range) else { continue }
                let color = (matched ? NSColor.systemTeal : .systemRed).withAlphaComponent(0.3)
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
            if let r = textRange(run.range) { manager.addRenderingAttribute(.foregroundColor, value: run.kind.color, for: r) }
        }
        coloured = start..<end
    }

    // MARK: the selection

    private var brackets: [(NSRange, Bool)] = []
    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !loading else { return }
        if !typing { closeCompletions() }
        brackets = matchBrackets()
        previewMath()
        if let snippet, !mirroring, !snippet.contains(selectedRange()) { self.snippet = nil }
        let lineStart = (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
        closers = closers.filter { $0 >= lineStart }
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
            closeCompletions()
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
        if !hasKeyboard { closeCompletions() }
        previewMath()
    }

    private var hasKeyboard: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    // MARK: the maths preview

    private var mathPopover: MathPopover?

    /// Preview maths at the caret only while its source is visible and focused.
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
        guard i >= 0, i < text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: i)).first
    }

    /// Check before and after the caret, bounded to 10,000 UTF-16 units.
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
        super.cancelOperation(sender)
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
                            under: start, in: host)
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

    /// Command-click goes to the PDF from the clicked spot.
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let sync = forwardSync() else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), length: 0))
        sync()
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

private extension HighlightKind {
    var color: NSColor {
        switch self {
        case .command: .systemPink
        case .argument: .systemTeal
        case .mathDelimiter: .systemOrange
        case .mathIdentifier, .builtin: .systemPurple
        case .number: .systemBlue
        case .comment: .secondaryLabelColor
        case .stringLiteral: .systemBrown
        case .invalid: .systemRed
        }
    }
}
