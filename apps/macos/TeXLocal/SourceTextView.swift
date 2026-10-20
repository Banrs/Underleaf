import AppKit
import SwiftUI

/// The source editor's text view: TextKit 2 only, with the core's document as the text's mirror.
final class SourceTextView: NSTextView, NSTextStorageDelegate, NSAccessibilityCustomRotorItemSearchDelegate {
    static func plainDocument() -> SourceTextView {
        let view = SourceTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.usesRuler = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.delegate = view
        view.installColouring()
        view.displayOptionsWatch = NSWorkspace.shared.notificationCenter.addObserver(
            of: NSWorkspace.self, for: .accessibilityDisplayOptionsDidChange) { [weak view] _ in view?.needsDisplay = true }
        return view
    }

    private var displayOptionsWatch: NotificationCenter.ObservationToken?

    /// A project session's document, whose edits it saves and previews, or the view's own.
    private(set) var document = SourceDocument(text: "")
    /// The storage's UTF-16 units in place: `string` bridges the whole text on every call.
    var text: NSString { textStorage?.mutableString ?? "" }
    var fileDrop: (URL) -> FileDrop? = { _ in nil }
    enum FileDrop { case open(() -> Void), insert(String) }
    var forwardSync: (_ quietly: Bool) -> (() -> Void)? = { _ in nil }
    private(set) var loading = false

    /// `source` is the session's document holding `text`.
    func load(_ text: String, source: SourceDocument? = nil) {
        // First: colours and line numbers read the storage against it.
        document = source ?? SourceDocument(text: text)
        show(text)
    }

    /// The disk's text, from the session's `document_reload`: shown without an edit.
    func reload(_ text: String) {
        document.reload(text)
        show(text)
    }

    private func show(_ text: String) {
        loading = true
        // Else typing coalesced into the last file's undo would go on in this one's.
        breakUndoCoalescing()
        fragments.removeAll(keepingCapacity: true)
        issues.place()
        inputContext?.discardMarkedText()
        unmarkText()
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
        lastMath = nil
        dismissedMath = nil
        _ = document.endSnippet()
        completions.close()
        markPartner(nil)
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
        // A snippet field's other places take what's typed once the change is done (`didChangeText`).
        mirrorEdits = document.edit(NSRange(location: edited.location, length: edited.length - delta),
                                    with: textStorage.mutableString.substring(with: edited), changing: changing, mirroring: mirroring)
        lastMath = nil
        staleColours = min(staleColours ?? edited.location, edited.location)
        changing = nil
        // After the edit: a layout change mid-edit would lay out stale text.
        if gutter.digits != EditorGutter.digits(document.lineCount) { Task { self.updateGutterWidth() } }
    }

    /// The core's edits, and the selections after them. False for none.
    @discardableResult
    func apply(_ change: Change?, named name: String) -> Bool {
        apply(change?.edits ?? [], named: name, selecting: change?.selections.map(\.range))
    }

    /// One undo step; the selections follow the edits unless `selecting` is given. False for none.
    @discardableResult
    func apply(_ edits: [TextEdit], named name: String, selecting: [NSRange]? = nil) -> Bool {
        guard !edits.isEmpty else { return false }
        let selections = selecting ?? document.map(selectedRanges.map(\.rangeValue), through: edits)
        undoManager?.beginUndoGrouping()
        for edit in edits.reversed() where shouldChangeText(in: edit.range, replacementString: edit.text) {
            textStorage?.replaceCharacters(in: edit.range, with: edit.text)
            didChangeText()
        }
        undoManager?.setActionName(name)
        undoManager?.endUndoGrouping()
        if !selections.isEmpty { setSelectedRanges(selections.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false) }
        scrollRangeToVisible(selectedRange())
        return true
    }

    // MARK: the font

    var fontSize = NSFont.systemFontSize { didSet { applyFont() } }
    var fontName = "" { didSet { if fontName != oldValue { applyFont() } } }
    /// How far a line's text sits under its fragment's top: half what the paragraph's least height adds.
    private(set) var rowShift: CGFloat = 0
    private var applied: NSFont?

    private func applyFont() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let chosen = fontName.isEmpty ? nil : NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: fontSize)
        let font = chosen ?? .monospacedSystemFont(ofSize: fontSize, weight: dark ? .medium : .regular)
        guard font != applied else { return }
        let resized = applied?.pointSize != font.pointSize || applied?.familyName != font.familyName
        applied = font
        // TextKit 2 lays a new font out anew and estimates the heights above: the top line stays.
        let top = shownTop
        defer {
            top.map(scroll(toShownTop:))
            if !issues.lines.isEmpty { layOutViewportOnceSettled() }
        }
        self.font = font
        completions.close()
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
        gutter.font = EditorGutter.font(forText: fontSize)
        issues.fontChanged(size: fontSize, text: font)
        updateGutterWidth()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFont()
    }

    // MARK: what is drawn under and over the text

    var gutter = EditorGutter()
    /// The fragments TextKit last laid out in the viewport, by offset (+Viewport).
    var fragments: [(offset: Int, fragment: NSTextLayoutFragment)] = []
    var viewportPending = false
    /// Each time TextKit lays out the viewport.
    var laidOut: () -> Void = {}
    var showsLineNumbers = true { didSet { if showsLineNumbers != oldValue { updateGutterWidth() } } }
    private(set) lazy var issues = IssueOverlay(in: self)
    var issueClicked: (Int) -> Void = { _ in }
    var syntaxTheme = SyntaxTheme.overleaf {
        didSet { if syntaxTheme != oldValue { fragmentColours.removeAllObjects(); colour(from: 0) } }
    }
    /// From where the text is to be coloured again at the viewport's next layout.
    var staleColours: Int?
    /// The runs each fragment was last coloured with: a pass redraws only the fragments whose runs changed (+Colours).
    let fragmentColours = NSMapTable<NSTextLayoutFragment, NSArray>.weakToStrongObjects()
    /// The bracket partner filled in place of the find indicator, with Reduce Motion (+Colours).
    var partnerMark: NSRange?
    var partnerDrawn: NSRect?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let current = selectedRange().length == 0 ? currentLine : nil
        drawCurrentLine(current, in: rect)
        issues.draw(in: rect, currentLine: current?.number)
        drawPartner(in: rect)
        drawNumbers(in: rect, current: current?.number)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        issues.place()
    }

    // MARK: the selection

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !loading else { return }
        if !typing { completions.close() }
        if partnerMark != nil { markPartner(nil) }
        previewMath()
        // A snippet ends once the selection leaves its fields.
        document.select(selectedRange(), mirroring: mirroring)
        redrawLineAndGutter()
    }

    var caret: Int { selectedRange().location }

    /// Whether the text has the window's keyboard, told as it takes and gives it up.
    var keyboardChanged: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        defer { Task { self.previewMath() } }
        guard super.becomeFirstResponder() else { return false }
        keyboardChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        defer {
            mathPopover.close()
            completions.close()
        }
        guard super.resignFirstResponder() else { return false }
        keyboardChanged(false)
        return true
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
        if !hasKeyboard { completions.close() }
        previewMath()
    }

    private var hasKeyboard: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    // MARK: the maths preview

    private lazy var mathPopover = MathPopover()
    /// Until the next edit.
    private var lastMath: (caret: Int, value: MathPreview?)?
    private var dismissedMath: Int?

    private func math(at caret: Int) -> MathPreview? {
        if let lastMath, lastMath.caret == caret { return lastMath.value }
        let value = document.mathAt(caret: caret)
        lastMath = (caret, value)
        return value
    }

    func previewMath() {
        // Escape's dismissal lasts while the caret is in that maths.
        let maths = loading ? nil : math(at: caret)
        if maths?.start != dismissedMath { dismissedMath = nil }
        guard let window, hasKeyboard, let maths, dismissedMath == nil, enclosingScrollView != nil else { return mathPopover.close() }
        // A point wide: NSPopover takes an empty rect for the whole view.
        var rect = convert(window.convertFromScreen(firstRect(forCharacterRange: .caret(caret), actualRange: nil)), from: nil)
        rect.size.width = max(rect.width, 1)
        guard shownRect.contains(NSPoint(x: rect.minX, y: rect.midY)) else { return mathPopover.close() }
        mathPopover.show(maths, size: fontSize, at: rect, of: self, edge: completions.offered != nil && completions.isAbove ? .maxY : .minY)
    }

    override func moveRight(_ sender: Any?) { stepCaret(1) { super.moveRight(sender) } }
    override func moveLeft(_ sender: Any?) { stepCaret(-1) { super.moveLeft(sender) } }

    /// A caret that steps over a bracket shows its partner; the character stepped over is at the lesser of the two carets.
    private func stepCaret(_ step: Int, by move: () -> Void) {
        let before = selectedRange()
        move()
        guard before.length == 0, selectedRange() == .caret(before.location + step) else { return }
        showPartner(of: min(before.location, before.location + step))
    }

    // MARK: typing: the core's brackets, indentation and snippet fields

    var autoPair = true, autoComplete = true
    /// Told as marked (IME) text comes and goes: the session's autosave waits for it to be committed.
    var composing: (Bool) -> Void = { _ in }
    private var toldComposing = false
    /// A key's edit is going in: the selection it moves keeps the completion list.
    private var typing = false

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

    // A read-only editor (a project closing) asks the core nothing for its keys.

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEditable else { return super.insertText(string, replacementRange: replacementRange) }
        let wasTyping = typing
        typing = true
        defer {
            typing = wasTyping
            markedTextChanged()
        }
        guard let typed = string as? String, replacementRange.location == NSNotFound, !hasMarkedText(), selectedRanges.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return completions.close()
        }
        let stroke = document.type(typed, replacing: selectedRange(), autoPair: autoPair)
        if let edit = stroke.edit {
            super.insertText(edit.text, replacementRange: edit.range)
        } else if stroke.selection == nil {
            super.insertText(string, replacementRange: replacementRange)
        }
        finish(stroke)
    }

    private func finish(_ stroke: Keystroke) {
        if let selection = stroke.selection { setSelectedRange(selection.range) }
        if let partner = stroke.partner { showPartner(of: partner) }
        switch stroke.completions {
        case .keep: break
        case .offer: completions.offer()
        case .close: completions.close()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        guard isEditable else { return super.deleteBackward(sender) }
        let wasTyping = typing, completing = completions.offered != nil
        typing = true
        defer {
            typing = wasTyping
            if completing { completions.offer() }
        }
        guard selectedRanges.count == 1, let edit = document.deleteBackward(selectedRange(), autoPair: autoPair).edit
        else { return super.deleteBackward(sender) }
        // Past this view's own `insertText`, which would close the list.
        super.insertText(edit.text, replacementRange: edit.range)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, selectedRanges.count == 1 else { return super.insertNewline(sender) }
        let stroke = document.insertNewline(selectedRange())
        guard let edit = stroke.edit else { return super.insertNewline(sender) }
        super.insertText(edit.text, replacementRange: edit.range)
        finish(stroke)
    }

    override func insertTab(_ sender: Any?) { isEditable ? tab(1) : super.insertTab(sender) }
    override func insertBacktab(_ sender: Any?) { isEditable ? tab(-1) : super.insertBacktab(sender) }

    /// A snippet's next field, or the lines indented.
    private func tab(_ step: Int) {
        let answer = document.tab(selectedRanges.map(\.rangeValue), step: step)
        if let field = answer.field { return setSelectedRange(field.range) }
        apply(answer.edits, named: step > 0 ? String(localized: "Indent") : String(localized: "Outdent"))
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        EditorPrefs.spellCheck = isContinuousSpellCheckingEnabled
    }

    // MARK: completion

    private(set) lazy var completions = CompletionList(for: self)

    override func complete(_ sender: Any?) { completions.complete(explicit: true) }

    /// Never goes on to the window, whose Escape would leave full screen.
    override func cancelOperation(_ sender: Any?) {
        if completions.offered != nil {
            completions.close()
        } else if document.endSnippet() {
            // Escape leaves the snippet's fields.
        } else if mathPopover.isWanted, let maths = math(at: caret) {
            dismissedMath = maths.start
            mathPopover.close()
        } else {
            completions.complete(explicit: true)
        }
    }

    /// Escape is `cancelOperation`: the text view's own goes straight to `complete(_:)`. While the list shows, the arrows
    /// move through it and Return or Tab accepts.
    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { return cancelOperation(nil) }
        guard completions.offered != nil else { return super.doCommand(by: selector) }
        switch selector {
        case #selector(moveUp(_:)): completions.move(-1)
        case #selector(moveDown(_:)): completions.move(1)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)): completions.accept()
        default: super.doCommand(by: selector)
        }
    }

    // MARK: snippet fields

    /// The core's mirror edits are going in: they move the fields without ending the snippet.
    private var mirroring = false
    private var mirrorEdits: [TextEdit] = []

    func startSnippet(_ fields: [SnippetField], at location: Int) {
        if let first = document.startSnippet(fields, at: location) { setSelectedRange(first) }
    }

    override func didChangeText() {
        super.didChangeText()
        guard !mirroring, !mirrorEdits.isEmpty else { return }
        let edits = mirrorEdits, selection = selectedRange()
        mirrorEdits = []
        mirroring = true
        for edit in edits where shouldChangeText(in: edit.range, replacementString: edit.text) {
            textStorage?.replaceCharacters(in: edit.range, with: edit.text)
            super.didChangeText()
        }
        mirroring = false
        setSelectedRange(selection)
    }

    // MARK: the mouse

    /// The text view sets its cursor on every move, over the list's own cursor rect.
    private func setsCursor(with event: NSEvent) -> Bool {
        if updateDividerCursor(with: event) { return true }
        guard inGutter(event) || issue(at: event) != nil || completions.contains(event.locationInWindow) else { return false }
        NSCursor.arrow.set()
        return true
    }

    private func inGutter(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return visibleRect.contains(point) && point.x < textContainerOrigin.x
    }

    private func issue(at event: NSEvent) -> IssueOverlay.Row? { issues.message(at: convert(event.locationInWindow, from: nil)) }

    override func mouseMoved(with event: NSEvent) { if !setsCursor(with: event) { super.mouseMoved(with: event) } }
    override func mouseEntered(with event: NSEvent) { if !setsCursor(with: event) { super.mouseEntered(with: event) } }
    override func cursorUpdate(with event: NSEvent) { if !setsCursor(with: event) { super.cursorUpdate(with: event) } }

    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown, inGutter(event) { return selectLines(with: event) }
        if event.type == .leftMouseDown, let row = issue(at: event), clicked(row, with: event) { return }
        super.mouseDown(with: event)
        if event.type == .leftMouseDown, event.clickCount == 2 { forwardSync(true)?() }
    }

    /// False for a drag, Shift-click and double-click, which are the text view's.
    private func clicked(_ issue: IssueOverlay.Row, with down: NSEvent) -> Bool {
        guard down.clickCount == 1, down.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) else { return false }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if issue.message?.rect.contains(convert(next.locationInWindow, from: nil)) == true { issueClicked(issue.line) }
                return true
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
            return text.lineRange(for: .caret(characterIndexForInsertion(at: point)))
        }
        let first = line(at: event)
        let anchor = event.modifierFlags.contains(.shift) ? selectedRange() : first
        window?.makeFirstResponder(self)
        // Periodic events keep it scrolling while the pointer holds still past an edge, as a drag in the text does.
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var current = event
        repeat {
            setSelectedRange(NSUnionRange(anchor, line(at: current)))
            autoscroll(with: current)
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) else { break }
            // A periodic event has no place: the last drag's, scrolled under, is the next line.
            if next.type != .periodic { current = next }
        } while current.type != .leftMouseUp
        let number = document.line(at: first.location)
        if selectedRange() == first, issues.lines[number] != nil { issueClicked(number) }
    }

    // MARK: file drops open, or insert a figure

    private func files(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// The text view's own for what isn't a file; none for files the project can't take.
    private func dragOperation(_ info: any NSDraggingInfo, textViews own: () -> NSDragOperation) -> NSDragOperation {
        let files = files(info)
        guard !files.isEmpty else { return own() }
        guard let drop = files.lazy.compactMap(fileDrop).first else { return [] }
        // The insertion point shows where a figure goes, and it scrolls near the edges (HIG, Drag and drop).
        if case .insert = drop {
            guard isEditable else { return [] }
            _ = own()
        }
        return info.draggingSourceOperationMask.contains(.generic) ? .generic : .copy
    }

    override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation { dragOperation(info) { super.draggingEntered(info) } }
    override func draggingUpdated(_ info: any NSDraggingInfo) -> NSDragOperation { dragOperation(info) { super.draggingUpdated(info) } }

    override func performDragOperation(_ info: any NSDraggingInfo) -> Bool {
        let files = files(info)
        guard !files.isEmpty else { return super.performDragOperation(info) }
        switch files.lazy.compactMap(fileDrop).first {
        case nil: return false
        case .open(let open)?: open()
        case .insert(let text)?:
            guard isEditable else { return false }
            let at = characterIndexForInsertion(at: convert(info.draggingLocation, from: nil))
            apply([TextEdit(.caret(at), text)], named: String(localized: "Insert Figure"),
                  selecting: [NSRange(location: at, length: (text as NSString).length)])
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
        var items = rotor.type == .heading ? headings() : issues.lines.sorted { $0.key < $1.key }.map { line, issue in
            let place = issue.error ? String(localized: "Error on line \(line)") : String(localized: "Warning on line \(line)")
            return (line, String(localized: "\(place): \(issue.message)"))
        }
        if !search.filterString.isEmpty { items = items.filter { $0.title.localizedCaseInsensitiveContains(search.filterString) } }
        let current = search.currentItem.map { document.line(at: min($0.targetRange.location, text.length)) }
        guard let found = search.searchDirection == .next ? items.first(where: { $0.line > current ?? 0 })
                                                          : items.last(where: { $0.line < current ?? .max })
        else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        // The outline and the issues are a moment behind the text: within what there is of it.
        result.targetRange = text.lineRange(for: .caret(min(document.lineStart(found.line), text.length)))
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
