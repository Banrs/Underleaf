import GameController
import UIKit

/// The source editor's text view: TextKit 2 only, never `layoutManager`, which drops it to TextKit 1; with the core's
/// document as the text's mirror. What the software keyboard, a hardware one, Scribble and dictation type all comes
/// through `insertText`, `deleteBackward` and `replace`.
final class SourceTextView: UITextView, NSTextStorageDelegate {
    static func plainDocument() -> SourceTextView {
        // A nil container is TextKit 2's; `init(usingTextLayoutManager:)` makes a plain UITextView, not this subclass.
        let view = SourceTextView(frame: .zero, textContainer: nil)
        view.textStorage.delegate = view
        view.installColouring()
        view.installGutter()
        view.installInput()
        return view
    }

    /// A project session's document, whose edits it saves and previews, or the view's own (`load`).
    var document = SourceDocument(text: "")
    /// The storage's UTF-16 units in place: `text` bridges the whole text on every call.
    var source: NSString { textStorage.mutableString }
    var length: Int { textStorage.length }
    var fileDrop: (URL) -> FileDrop? = { _ in nil }
    enum FileDrop { case open(() -> Void), insert(String) }
    var forwardSync: (_ quietly: Bool) -> (() -> Void)? = { _ in nil }
    var openDefinition: (Definition.Place) -> Void = { _ in }
    /// The outline's, for VoiceOver's headings rotor (+Input).
    var headings: () -> [(line: Int, title: String)] = { [] }
    private(set) var loading = false
    /// The file's own, which the keyboard's Undo, ⌘Z and the editor's commands share. UIKit registers no undo for the
    /// storage's edits, nor any with a manager of the view's, and its typing's undo would go past the core's edits: every
    /// edit here registers its own.
    var undo = UndoManager()
    override var undoManager: UndoManager? { undo }

    func show(_ text: String) {
        loading = true
        unmarkText()
        fragments.removeAll(keepingCapacity: true)
        issues.place()
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
        loading = false
        run = nil
        lastMath = nil
        dismissedMath = nil
        _ = document.endSnippet()
        completions.close()
        mark(nil)
        updateGutterWidth()
        staleColours = 0
    }

    // MARK: edits reach the core

    /// What UIKit said it would change (`SourceEditor`'s `shouldChangeTextIn`), or an edit of the view's own.
    var changing: NSRange?

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !loading else { return }
        // A snippet field's other places take what's typed once the change is done (`textChanged`).
        mirrorEdits += document.edit(NSRange(location: edited.location, length: edited.length - delta),
                                     with: textStorage.mutableString.substring(with: edited), changing: changing, mirroring: mirroring)
        lastMath = nil
        staleColours = min(staleColours ?? edited.location, edited.location)
        changing = nil
        // After the edit: a layout change mid-edit would lay out stale text.
        if gutter.digits != EditorGutter.digits(document.lineCount) { Task { self.updateGutterWidth() } }
    }

    /// One undo step; the selections follow the edits unless `selecting` is given. False for none.
    @discardableResult
    func apply(_ edits: [TextEdit], named name: String, selecting: [NSRange]? = nil) -> Bool {
        guard !edits.isEmpty else { return false }
        let selections = selecting ?? document.map(selections, through: edits)
        undo.beginUndoGrouping()
        replace(edits, named: name)
        undo.setActionName(name)
        undo.endUndoGrouping()
        if let first = selections.first { selectedRanges = [first] }
        scrollRangeToVisible(selectedRange)
        return true
    }

    /// Into the storage with an undo of their own, which brings the selection back.
    private func replace(_ edits: [TextEdit], named name: String) {
        var shift = 0, inverse: [TextEdit] = []
        for edit in edits {
            let inserted = (edit.text as NSString).length
            inverse.append(TextEdit(NSRange(location: edit.start + shift, length: inserted), source.substring(with: edit.range)))
            shift += inserted - edit.length
        }
        let before = selectedRange
        undo.registerUndo(withTarget: self) { $0.apply(inverse, named: name, selecting: [before]) }
        run = nil
        store(edits)
    }

    /// From the last, in the text's own attributes.
    private func store(_ edits: [TextEdit]) {
        for edit in edits.reversed() {
            changing = edit.range
            textStorage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.text, attributes: typingAttributes))
        }
        // As UIKit tells of its own changes: the editor counts them, and a snippet's other places follow.
        delegate?.textViewDidChange?(self)
    }

    /// Consecutive keys, one undo as on the Mac, until the caret goes elsewhere or another edit comes between. `range` is
    /// what they typed, which replaced `original`.
    private final class TypingRun {
        var range: NSRange
        var original: String
        let selection: NSRange

        init(range: NSRange, original: String, selection: NSRange) { (self.range, self.original, self.selection) = (range, original, selection) }
    }

    /// A key's edit, the caret after it. One that meets the run's text goes into its undo.
    private func type(_ edit: TextEdit) {
        let typed = edit.range, inserted = (edit.text as NSString).length
        if let run, typed.location <= NSMaxRange(run.range), NSMaxRange(typed) >= run.range.location {
            let start = min(run.range.location, typed.location), end = max(NSMaxRange(run.range), NSMaxRange(typed))
            run.original = source.substring(with: NSRange(location: start, length: run.range.location - start)) + run.original
                + source.substring(with: NSRange(location: NSMaxRange(run.range), length: end - NSMaxRange(run.range)))
            run.range = NSRange(location: start, length: end - start + inserted - typed.length)
        } else {
            let started = TypingRun(range: NSRange(location: typed.location, length: inserted), original: source.substring(with: typed),
                                    selection: selectedRange)
            let name = String(localized: "Typing")
            undo.registerUndo(withTarget: self) { $0.apply([TextEdit(started.range, started.original)], named: name, selecting: [started.selection]) }
            undo.setActionName(name)
            run = started
        }
        // A snippet's other places go in with it, and end the run.
        store([edit])
        selectedRange = .caret(typed.location + inserted)
        scrollRangeToVisible(selectedRange)
    }

    /// Committed marked text, an IME's or dictation's: undone back to what it replaced.
    private func registerComposed(_ committed: NSRange) {
        guard let original = composedOver, committed.length > 0 || !original.isEmpty else { return }
        undo.registerUndo(withTarget: self) { view in
            view.apply([TextEdit(committed, original)], named: String(localized: "Typing"),
                       selecting: [.caret(committed.location + (original as NSString).length)])
        }
        undo.setActionName(String(localized: "Typing"))
        run = nil
        composedOver = nil
    }

    /// As each change is done, the view's or UIKit's (`SourceEditor`'s `textViewDidChange`).
    func textChanged() {
        guard !mirroring, !mirrorEdits.isEmpty else { return }
        let edits = mirrorEdits, selection = selectedRange
        mirrorEdits = []
        mirroring = true
        // Undone with the typing: one event's undos are one step.
        replace(edits, named: String(localized: "Typing"))
        mirroring = false
        selectedRange = selection
    }

    // MARK: the font

    var fontSize = UIFont.systemFontSize { didSet { applyFont() } }
    var fontName = "" { didSet { if fontName != oldValue { applyFont() } } }
    /// How far a line's text sits under its fragment's top: half what the paragraph's least height adds.
    private(set) var rowShift: CGFloat = 0
    private var applied: UIFont?

    func applyFont() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let chosen = fontName.isEmpty || UIFont.fontNames(forFamilyName: fontName).isEmpty ? nil
            : UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: fontName]), size: fontSize)
        let font = chosen ?? .monospacedSystemFont(ofSize: fontSize, weight: dark ? .medium : .regular)
        guard font != applied else { return }
        let resized = applied?.pointSize != font.pointSize || applied?.familyName != font.familyName
        applied = font
        // TextKit 2 lays a new font out anew and estimates the heights above: the top line stays.
        let top = shownTop
        defer {
            top.map(scroll(toShownTop:))
            if !issues.isEmpty { Task { [weak self] in self?.textLayoutManager?.textViewportLayoutController.layoutViewport() } }
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
        textStorage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: length))
        typingAttributes = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: style]
        gutter.font = EditorGutter.font(forText: fontSize)
        issues.fontChanged(size: fontSize, text: font)
        updateGutterWidth()
    }

    // MARK: what is drawn under and over the text

    var gutter = EditorGutter()
    /// The current line, issues' bands, the partner and the line numbers, under the text (+Gutter).
    let underlay = Underlay()
    let gutterControl = GutterControl()
    /// The fragments TextKit last laid out in the viewport, by offset (+Layout).
    var fragments: [(offset: Int, fragment: NSTextLayoutFragment)] = []
    /// Each time TextKit lays out the viewport.
    var laidOut: () -> Void = {}
    var showsLineNumbers = true { didSet { if showsLineNumbers != oldValue { updateGutterWidth() } } }
    private(set) lazy var issues = IssueOverlay(in: self)
    var syntaxTheme = SyntaxTheme.system {
        didSet { if syntaxTheme != oldValue { fragmentColours.removeAllObjects(); colour(from: 0) } }
    }
    /// From where the text is to be coloured again at the viewport's next layout.
    var staleColours: Int?
    /// The runs each fragment was last coloured with: a pass redraws only the fragments whose runs changed (+Layout).
    let fragmentColours = NSMapTable<NSTextLayoutFragment, NSArray>.weakToStrongObjects()
    /// The bracket partner, or what `reveal` found, filled until the selection next changes (+Colours).
    var marked: (range: NSRange, found: Bool)?
    let gestures = EditorGestures()
    /// The prose's misspelt words (+Spelling).
    let spelling = Spelling()
    var checksSpelling = EditorPrefs.spellCheck { didSet { if checksSpelling != oldValue { checkSpellingSoon() } } }

    // MARK: the selection

    var caret: Int { selectedRange.location }
    var selection: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }
    var selections: [NSRange] { selectedRanges }
    func hasMarkedText() -> Bool { markedTextRange != nil }

    func word(at offset: Int) -> NSRange {
        guard let position = position(from: beginningOfDocument, offset: offset),
              let word = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward))
                ?? tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.backward))
        else { return .caret(offset) }
        return range(word)
    }

    /// The caret before the selection last changed: a step of one over a bracket shows its partner.
    private var lastCaret: Int?

    /// From `SourceEditor`'s `textViewDidChangeSelection`, which UIKit sends for its own changes and the view's.
    func selectionChanged() {
        guard !loading else { return }
        if !typing {
            completions.close()
            run = nil
        }
        if marked != nil { mark(nil) }
        let now = selectedRange
        if !typing, now.length == 0, let before = lastCaret, abs(now.location - before) == 1 {
            showPartner(of: min(before, now.location))
        }
        lastCaret = now.length == 0 ? now.location : nil
        previewMath()
        // A snippet ends once the selection leaves its fields.
        document.select(now, mirroring: mirroring)
        redrawLineAndGutter()
    }

    /// Whether the text has the window's keyboard, told as it takes and gives it up.
    var keyboardChanged: (Bool) -> Void = { _ in }

    private var keyWatches: [any NSObjectProtocol] = []
    /// Asked before the view had a window, where taking the keyboard would loop UIKit's layout.
    private var focusWhenInWindow = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        keyWatches.forEach(NotificationCenter.default.removeObserver)
        keyWatches = []
        guard let window else { return }
        keyWatches = [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyChanged() }
            }
        }
        if focusWhenInWindow {
            focusWhenInWindow = false
            Task { self.focus() }
        }
    }

    /// The software keyboard covers half the screen, so the text takes the keyboard by itself only with a hardware one, as
    /// Notes' does; a tap in it brings the software keyboard up.
    func focus() {
        guard window != nil else { return focusWhenInWindow = true }
        if !isFirstResponder, GCKeyboard.coalesced != nil { _ = becomeFirstResponder() }
    }

    var hasKeyboard: Bool { window?.isKeyWindow == true && isFirstResponder }

    // MARK: the maths preview

    private(set) lazy var mathPreview = MathCallout(for: self)
    /// Until the next edit.
    var lastMath: (caret: Int, value: MathPreview?)?
    var dismissedMath: Int?

    func previewMath() {
        // Escape's dismissal lasts while the caret is in that maths.
        let maths = loading ? nil : math(at: caret)
        if maths?.start != dismissedMath { dismissedMath = nil }
        guard hasKeyboard, let maths, dismissedMath == nil else { return mathPreview.close() }
        let rect = caretRect(at: caret)
        guard shownRect.contains(CGPoint(x: rect.minX, y: rect.midY)) else { return mathPreview.close() }
        mathPreview.show(maths, size: fontSize, at: rect, avoiding: completions.offered != nil && completions.isAbove)
    }

    // MARK: typing: the core's brackets, indentation and snippet fields

    var autoPair = true, autoComplete = true
    /// Told as marked (IME) text comes and goes: the session's autosave waits for it to be committed.
    var composing: (Bool) -> Void = { _ in }
    var toldComposing = false
    /// A key's edit is going in: the selection it moves keeps the completion list.
    private var typing = false

    /// What marked text took the place of, from its start until it's committed.
    private var composedOver: String?
    private var run: TypingRun?

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if !hasMarkedText() { composedOver = source.substring(with: self.selectedRange) }
        super.setMarkedText(markedText, selectedRange: selectedRange)
        markedTextChanged()
    }

    override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        if !hasMarkedText() { composedOver = source.substring(with: self.selectedRange) }
        super.setAttributedMarkedText(markedText, selectedRange: selectedRange)
        markedTextChanged()
    }

    override func unmarkText() {
        let committed = loading ? nil : markedTextRange.map(range)
        super.unmarkText()
        committed.map(registerComposed)
        markedTextChanged()
    }

    // A read-only editor (a project closing) asks the core nothing for its keys.

    override func insertText(_ text: String) {
        guard isEditable else { return }
        let wasTyping = typing
        typing = true
        defer {
            typing = wasTyping
            markedTextChanged()
        }
        if let marked = markedTextRange.map(range) {
            super.insertText(text)
            registerComposed(NSRange(location: marked.location, length: (text as NSString).length))
            return completions.close()
        }
        // Return and Tab accept a completion, as on the Mac; else they're the core's newline and indent.
        if text == "\n" || text == "\t", completions.offered != nil { return completions.accept() }
        if text == "\t" { return tab(1) }
        let stroke = text == "\n" ? document.insertNewline(selectedRange) : document.type(text, replacing: selectedRange, autoPair: autoPair)
        if let edit = stroke.edit {
            type(edit)
        } else if stroke.selection == nil {
            type(TextEdit(selectedRange, text))
        }
        finish(stroke)
    }

    override func deleteBackward() {
        guard isEditable else { return }
        guard !hasMarkedText() else { return super.deleteBackward() }
        let wasTyping = typing, completing = completions.offered != nil
        typing = true
        defer {
            typing = wasTyping
            if completing { completions.offer() }
        }
        let selection = selectedRange
        if let edit = document.deleteBackward(selection, autoPair: autoPair).edit {
            type(edit)
        } else if selection.length > 0 {
            type(TextEdit(selection, ""))
        } else if selection.location > 0 {
            type(TextEdit(source.rangeOfComposedCharacterSequence(at: selection.location - 1), ""))
        }
    }

    /// Scribble's, dictation's and UIKit's own replacements, typed as keys are.
    override func replace(_ range: UITextRange, withText text: String) {
        guard isEditable, !hasMarkedText() else { return super.replace(range, withText: text) }
        type(TextEdit(self.range(range), text))
    }

    override func paste(_ sender: Any?) {
        guard isEditable, let string = UIPasteboard.general.string else { return }
        let at = selectedRange.location
        apply([TextEdit(selectedRange, string)], named: String(localized: "Paste"), selecting: [.caret(at + (string as NSString).length)])
    }

    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange.length > 0 else { return }
        copy(sender)
        apply([TextEdit(selectedRange, "")], named: String(localized: "Cut"), selecting: [.caret(selectedRange.location)])
    }

    override func delete(_ sender: Any?) {
        guard isEditable, selectedRange.length > 0 else { return }
        apply([TextEdit(selectedRange, "")], named: String(localized: "Delete"), selecting: [.caret(selectedRange.location)])
    }

    /// Find's Replace. UIKit's own is a Swift extension, past an override but for its selector.
    @objc(replaceFoundTextInRange:inDocument:withText:)
    func replaceFound(_ range: UITextRange, inDocument document: Any?, withText text: String) {
        guard isEditable else { return }
        let found = self.range(range)
        apply([TextEdit(found, text)], named: String(localized: "Replace"), selecting: [.caret(found.location + (text as NSString).length)])
    }

    /// Find's Replace All, one undo as on the Mac.
    @objc(replaceAllOccurrencesOfQueryString:usingOptions:withText:)
    func replaceAllFound(_ query: String, options: UITextSearchOptions, withText text: String) {
        guard isEditable, !query.isEmpty else { return }
        func isWord(_ at: Int) -> Bool {
            at >= 0 && at < length && Unicode.Scalar(source.character(at: at)).map(CharacterSet.alphanumerics.contains) == true
        }
        var edits: [TextEdit] = [], from = 0
        while from < length {
            let found = source.range(of: query, options: options.stringCompareOptions, range: NSRange(location: from, length: length - from))
            guard found.location != NSNotFound, found.length > 0 else { break }
            from = NSMaxRange(found)
            let starts = !isWord(found.location - 1), ends = !isWord(NSMaxRange(found))
            switch options.wordMatchMethod {
            case .startsWith: guard starts else { continue }
            case .fullWord: guard starts, ends else { continue }
            default: break
            }
            edits.append(TextEdit(found, text))
        }
        apply(edits, named: String(localized: "Replace All"))
    }

    // MARK: completion

    private(set) lazy var completions = CompletionList(for: self)

    // MARK: snippet fields

    /// The core's mirror edits are going in: they move the fields without ending the snippet.
    private var mirroring = false
    private var mirrorEdits: [TextEdit] = []

    // MARK: offsets

    func range(_ range: UITextRange) -> NSRange {
        NSRange(location: offset(from: beginningOfDocument, to: range.start), length: offset(from: range.start, to: range.end))
    }

    func uiRange(_ range: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length) else { return nil }
        return textRange(from: start, to: end)
    }

    /// The caret's rect at `offset`, in the view.
    func caretRect(at offset: Int) -> CGRect {
        guard let position = position(from: beginningOfDocument, offset: min(offset, length)) else { return .zero }
        return caretRect(for: position)
    }
}
