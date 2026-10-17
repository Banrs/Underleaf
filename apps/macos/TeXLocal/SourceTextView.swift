import AppKit
import SwiftUI

/// The source editor's text view: TextKit 2 only, with the core's document as the text's mirror. Its gutter
/// (EditorGutter.swift), its scrolling (+Viewport), its colours (+Colours), its issues (IssueOverlay) and its completion
/// list (CompletionList) are each in a file of their own.
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
        #if DEBUG
        _ = textKit1Watch
        #endif
        return view
    }

    private var displayOptionsWatch: NotificationCenter.ObservationToken?

    #if DEBUG
    /// TextKit 1 comes back unseen on any `layoutManager` access, the app's own or AppKit's: never in the editor.
    private static let textKit1Watch = NotificationCenter.default.addObserver(
        forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: nil, queue: nil) { note in
        assert(!(note.object is SourceTextView), "The source editor is falling back to TextKit 1")
    }
    #endif

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
        // First: the storage's text is read against it, as for colours and line numbers.
        document = source ?? SourceDocument(text: text)
        takeText(text)
        loaded()
    }

    /// The disk's text, from the session's `document_reload`: shown without an edit, then the session told it is shown.
    func reload(_ text: String) {
        document.reload(text)
        takeText(text)
        loaded()
    }

    private func takeText(_ text: String) {
        loading = true
        // Else typing coalesced into the last file's undo would go on in this one's.
        breakUndoCoalescing()
        fragments.removeAll(keepingCapacity: true)
        issues.place()
        inputContext?.discardMarkedText()
        unmarkText()
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
    }

    private func loaded() {
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
        let old = NSRange(location: edited.location, length: edited.length - delta)
        let text = textStorage.mutableString.substring(with: edited)
        // The closers typing put in and a snippet's fields move with the text; what's typed in a field goes in its other
        // places once the change is done (`didChangeText`).
        mirrorEdits = document.edit(old, with: text, changing: changing, mirroring: mirroring)
        lastMath = nil
        staleColours = min(staleColours ?? edited.location, edited.location)
        changing = nil
        if gutter.digits != EditorGutter.digits(document.lineCount) {
            // After the edit: a layout change mid-edit would lay out stale text.
            Task { self.updateGutterWidth() }
        }
    }

    /// The core's edits, and the selections after them. False for none.
    @discardableResult
    func apply(_ change: Change?, named name: String) -> Bool {
        apply(change?.edits ?? [], named: name, selecting: change?.selections.map(\.range))
    }

    /// One undo step, from the last edit; the selections follow the edits unless `selecting` is given. False for none.
    @discardableResult
    func apply(_ edits: [TextEdit], named name: String, selecting: [NSRange]? = nil) -> Bool {
        guard !edits.isEmpty else { return false }
        let selections = selecting ?? document.map(selectedRanges.map(\.rangeValue), through: edits)
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
        return true
    }

    // MARK: the font

    var fontSize = NSFont.systemFontSize {
        didSet { applyFont() }
    }
    var fontName = "" {
        didSet { if fontName != oldValue { applyFont() } }
    }
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
        // A font set on the whole text has TextKit 2 lay it out anew and estimate the heights above: the top line stays.
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
    /// Each time TextKit lays out the viewport: a scroll past what it had laid out, an edit, a new width.
    var laidOut: () -> Void = {}

    var showsLineNumbers = true {
        didSet { if showsLineNumbers != oldValue { updateGutterWidth() } }
    }

    private(set) lazy var issues = IssueOverlay(in: self)
    var issueLines: [Int: LineIssue] {
        get { issues.lines }
        set { issues.lines = newValue }
    }
    var issueRows: [IssueRow] { issues.rows }
    var issueClicked: (Int) -> Void = { _ in }

    var syntaxTheme = SyntaxTheme.overleaf {
        didSet { if syntaxTheme != oldValue { colour(from: 0) } }
    }
    /// From where the text is to be coloured again at the viewport's next layout.
    var staleColours: Int?

    var reducesMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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
        // A snippet ends once the selection leaves its fields, and closers before its line are no longer stepped over.
        document.select(selectedRange(), mirroring: mirroring)
        redrawLineAndGutter()
    }

    var caret: Int { selectedRange().location }

    override func becomeFirstResponder() -> Bool {
        defer { Task { self.previewMath() } }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer {
            mathPopover?.close()
            completions.close()
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
        if !hasKeyboard { completions.close() }
        previewMath()
    }

    private var hasKeyboard: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    // MARK: the maths preview

    private var mathPopover: MathPopover?
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
        // Asked for whether or not it shows: Escape's dismissal lasts while the caret is in that maths.
        let maths = loading ? nil : math(at: caret)
        if maths?.start != dismissedMath { dismissedMath = nil }
        guard let window, hasKeyboard, let maths, dismissedMath == nil, enclosingScrollView != nil else {
            mathPopover?.close()
            return
        }
        let screen = firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        // A point wide: NSPopover takes an empty rect for the whole view.
        var rect = convert(window.convertFromScreen(screen), from: nil)
        rect.size.width = max(rect.width, 1)
        guard shownRect.contains(NSPoint(x: rect.minX, y: rect.midY)) else {
            mathPopover?.close()
            return
        }
        if mathPopover == nil { mathPopover = MathPopover() }
        mathPopover?.show(maths, size: fontSize, at: rect, of: self,
                          edge: completions.offered != nil && completions.isAbove ? .maxY : .minY)
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

    // MARK: typing: the core's brackets, indentation and snippet fields

    /// Settings' typing: brackets closed as they're typed, and completions offered as a command is.
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

    // A read-only editor (a project closing) asks the core nothing for its keys: the text view refuses them.

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
            completions.close()
            return
        }
        let stroke = document.type(typed, replacing: selectedRange(), autoPair: autoPair)
        if let edit = stroke.edit {
            replace(edit)
        } else if stroke.selection == nil {
            super.insertText(string, replacementRange: replacementRange)
        }
        finish(stroke)
    }

    /// A key's edit from the core, typed as a key types, past this view's own `insertText`, which would close the list.
    private func replace(_ edit: TextEdit) {
        super.insertText(edit.text, replacementRange: edit.range)
    }

    /// What follows a key's edit: the selection, the bracket's partner and the completion list.
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
        replace(edit)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, selectedRanges.count == 1 else { return super.insertNewline(sender) }
        let stroke = document.insertNewline(selectedRange())
        guard let edit = stroke.edit else { return super.insertNewline(sender) }
        replace(edit)
        finish(stroke)
    }

    override func insertTab(_ sender: Any?) {
        isEditable ? tab(1) : super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        isEditable ? tab(-1) : super.insertBacktab(sender)
    }

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

    // MARK: completion: the core's items in a list under the caret

    private(set) lazy var completions = CompletionList(for: self)

    override func complete(_ sender: Any?) { completions.complete(explicit: true) }

    /// Never goes on to the window, whose Escape would leave full screen.
    override func cancelOperation(_ sender: Any?) {
        if completions.offered != nil {
            completions.close()
        } else if document.endSnippet() {
            // Escape leaves the snippet's fields.
        } else if mathPopover?.isWanted == true, let maths = math(at: caret) {
            dismissedMath = maths.start
            mathPopover?.close()
        } else {
            completions.complete(explicit: true)
        }
    }

    /// Escape is `cancelOperation` here: the text view's own goes straight to its `complete(_:)`. While the list shows,
    /// the arrows move through it and Return or Tab accepts.
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
    /// What the last edit typed in a snippet's field, for its other places: from the last.
    private var mirrorEdits: [TextEdit] = []

    func startSnippet(_ fields: [SnippetField], at location: Int) {
        guard let first = document.startSnippet(fields, at: location) else { return }
        setSelectedRange(first)
    }

    /// What's typed in a field goes in its other places.
    override func didChangeText() {
        super.didChangeText()
        guard !mirroring, !mirrorEdits.isEmpty else { return }
        let edits = mirrorEdits
        mirrorEdits = []
        let selection = selectedRange()
        mirroring = true
        for edit in edits where shouldChangeText(in: edit.range, replacementString: edit.text) {
            textStorage?.replaceCharacters(in: edit.range, with: edit.text)
            super.didChangeText()
        }
        mirroring = false
        setSelectedRange(selection)
    }

    // MARK: the mouse

    /// A cursor rect of the list's own lost to the text view's per-move cursor, so the pointer is set on every move.
    private func setsCursor(with event: NSEvent) -> Bool {
        if updateDividerCursor(with: event) { return true }
        guard inGutter(event) || issueMessage(at: event) != nil || completions.contains(event.locationInWindow) else { return false }
        NSCursor.arrow.set()
        return true
    }

    private func inGutter(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return visibleRect.contains(point) && point.x < textContainerOrigin.x
    }

    private func issueMessage(at event: NSEvent) -> IssueRow? {
        issues.message(at: convert(event.locationInWindow, from: nil))
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

    /// The text view's own for what isn't a file; none for files the project can't take.
    private func dragOperation(_ info: any NSDraggingInfo, textViews own: () -> NSDragOperation) -> NSDragOperation {
        let files = files(info)
        guard !files.isEmpty else { return own() }
        guard let drop = files.lazy.compactMap(fileDrop).first else { return [] }
        // The text view's insertion point shows where a figure goes, and it scrolls near the edges (HIG, Drag and drop).
        if case .insert = drop {
            guard isEditable else { return [] }
            _ = own()
        }
        return info.draggingSourceOperationMask.contains(.generic) ? .generic : .copy
    }

    override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(info) { super.draggingEntered(info) }
    }

    override func draggingUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(info) { super.draggingUpdated(info) }
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
