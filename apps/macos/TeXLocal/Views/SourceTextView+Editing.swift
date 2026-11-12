import AppKit

extension SourceTextView {
    func load(_ source: SourceDocument) {
        document = source
        document.shown = { [weak self] in self?.string }
        show(source.text)
    }

    @discardableResult
    func apply(_ change: Change?, named name: String) -> Bool {
        apply(change?.edits ?? [], named: name, selecting: change?.selections.map(\.range))
    }

    @discardableResult
    func insert(_ insertion: Insertion?, named name: String) -> Bool {
        guard let insertion, apply([insertion.edit], named: name, selecting: [.caret(insertion.caret)]) else { return false }
        if let first = document.startSnippet(insertion.fields, at: insertion.edit.start) { selection = first }
        return true
    }

    /// Looks only at the pasteboard's types: reading its text outside a paste asks the person's leave.
    var canPasteTable: Bool { isEditable && document.editable && NSPasteboard.general.availableType(from: [.string]) != nil }

    /// Pastes spreadsheet cells as a tabular on a line of its own, at the current line's indentation.
    func pasteTable(from board: NSPasteboard = .general, booktabs: Bool) -> Bool {
        guard isEditable, let cells = board.string(forType: .string) else { return false }
        return apply(document.pasteTable(cells, at: selectedRange(), booktabs: booktabs), named: String(localized: "Paste as Table"))
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard document.editable, super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else {
            return false
        }
        sync.willChange(affectedRanges.map(\.rangeValue), to: replacementStrings)
        return true
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !loading else { return }
        foldCache = nil
        let edits = sync.edited(edited, delta: delta, in: textStorage.mutableString, of: document)
        if !edits.filter({ folds.edited($0.range, delta: $0.text.utf16.count - $0.length) }).isEmpty { Task { self.relayOutFolds() } }
        staleColours = min(staleColours ?? edited.location, edited.location)
        if gutter.digits != EditorGutter.digits(document.lineCount) { Task { self.updateGutterWidth() } }
    }

    /// Makes edits given front to back as one undo step, which undoes and redoes through here too, in one TextKit pass:
    /// NSTextView's own undo replays them one pass each, and took 6 s to undo an indent of 2,000 lines.
    @discardableResult
    func apply(_ edits: [TextEdit], named name: String, selecting: [NSRange]? = nil) -> Bool {
        guard isEditable, document.editable, !edits.isEmpty else { return false }
        let selections = selecting ?? document.map(selectedRanges.map(\.rangeValue), through: edits)
        var shift = 0
        let undone = edits.map { edit in
            let range = NSRange(location: edit.range.location + shift, length: edit.text.utf16.count)
            shift += range.length - edit.range.length
            return TextEdit(range, source.substring(with: edit.range))
        }
        let restored = self.selections
        undoManager?.beginUndoGrouping()
        undoManager?.registerUndo(withTarget: self) { $0.apply(undone, named: name, selecting: restored) }
        undoManager?.disableUndoRegistration()
        replace(edits.reversed())
        undoManager?.enableUndoRegistration()
        if !selections.isEmpty { setSelectedRanges(selections.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false) }
        // The selections are set before mirroring, so the mirror's edits move them as typing's do.
        mirror()
        undoManager?.setActionName(name)
        undoManager?.endUndoGrouping()
        scrollRangeToVisible(selectedRange())
        return true
    }

    override func moveRight(_ sender: Any?) { stepCaret(1) { super.moveRight(sender) } }
    override func moveLeft(_ sender: Any?) { stepCaret(-1) { super.moveLeft(sender) } }

    private func stepCaret(_ step: Int, by move: () -> Void) {
        let before = selectedRange()
        move()
        guard before.length == 0, selectedRange() == .caret(before.location + step) else { return }
        showPartner(of: min(before.location, before.location + step))
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedTextChanged()
    }

    override func unmarkText() {
        super.unmarkText()
        markedTextChanged()
        mirror()
    }

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
        holdingMirror {
            if let edit = stroke.edit {
                super.insertText(edit.text, replacementRange: edit.range)
            } else if stroke.selection == nil {
                super.insertText(string, replacementRange: replacementRange)
            }
        }
        finish(stroke)
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
        super.insertText(edit.text, replacementRange: edit.range)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, selectedRanges.count == 1 else { return super.insertNewline(sender) }
        let stroke = document.insertNewline(selectedRange())
        guard let edit = stroke.edit else { return super.insertNewline(sender) }
        holdingMirror { super.insertText(edit.text, replacementRange: edit.range) }
        finish(stroke)
    }

    override func insertTab(_ sender: Any?) { isEditable ? tab(1) : super.insertTab(sender) }
    override func insertBacktab(_ sender: Any?) { isEditable ? tab(-1) : super.insertBacktab(sender) }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        spellCheckToggled(isContinuousSpellCheckingEnabled)
    }

    func markedTextChanged() {
        if hasMarkedText() != document.composing { document.composing.toggle() }
    }

    /// The keystroke's offsets are from before its mirror edits, which then move the selection as they move typing.
    func finish(_ stroke: Keystroke) {
        if let selection = stroke.selection { self.selection = selection.range }
        let mirrored = mirror()
        if let partner = stroke.partner { showPartner(of: document.map([.caret(partner)], through: mirrored)[0].location) }
        switch stroke.completions {
        case .keep: break
        case .offer: completions.offer()
        case .close: completions.close()
        }
    }

    func tab(_ step: Int) {
        let answer = document.tab(selections, step: step)
        if let field = answer.field { return selection = field.range }
        apply(answer.edits, named: step > 0 ? String(localized: "Indent") : String(localized: "Outdent"))
    }

    func shiftLines(_ step: Int) {
        guard isEditable else { return }
        _ = document.endSnippet()
        tab(step)
    }

    func cancel() {
        if completions.offered != nil {
            completions.close()
        } else if document.endSnippet() {
        } else if mathPreview.isWanted, let maths = document.mathAt(caret: caret) {
            dismissedMath = maths.start
            mathPreview.close()
        } else {
            completions.complete(explicit: true)
        }
    }

    override func complete(_ sender: Any?) { completions.complete(explicit: true) }

    override func cancelOperation(_ sender: Any?) { cancel() }

    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { return cancelOperation(nil) }
        guard completions.offered != nil else { return keyCommand(selector) }
        switch selector {
        case #selector(moveUp(_:)): completions.move(-1)
        case #selector(moveDown(_:)): completions.move(1)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)): completions.accept()
        default: keyCommand(selector)
        }
    }

    private func keyCommand(_ selector: Selector) {
        stepping = NSStringFromSelector(selector).hasPrefix("move")
        defer { stepping = false }
        super.doCommand(by: selector)
    }

    override func didChangeText() {
        super.didChangeText()
        if !mirrorHeld { mirror() }
    }

    private func holdingMirror(_ edit: () -> Void) {
        mirrorHeld = true
        edit()
        mirrorHeld = false
    }

    @discardableResult
    private func mirror() -> [TextEdit] {
        let edits = sync.mirror(composing: hasMarkedText())
        guard !edits.isEmpty else { return [] }
        let kept = document.map(selections, through: edits)
        sync.mirroring = true
        replace(edits)
        sync.mirroring = false
        setSelectedRanges(kept.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        breakUndoCoalescing()
        return edits
    }

    /// Makes edits given back to front in one TextKit pass: a pass per edit updates every paragraph after it and moves the
    /// selection, which parses for the maths preview, so 2,000 took 15 s. Each edit still asks to change, keeping its undo
    /// step, and the core takes them one by one.
    private func replace(_ edits: some Sequence<TextEdit>) {
        guard let storage = textStorage else { return }
        var changed = false
        storage.beginEditing()
        for edit in edits where shouldChangeText(in: edit.range, replacementString: edit.text) {
            storage.replaceCharacters(in: edit.range, with: edit.text)
            sync.batch(edit)
            changed = true
        }
        storage.endEditing()
        if changed { super.didChangeText() }
    }
}
