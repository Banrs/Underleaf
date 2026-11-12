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

    override func becomeFirstResponder() -> Bool {
        defer { Task { self.previewMath() } }
        guard super.becomeFirstResponder() else { return false }
        keyboardChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        defer {
            mathPreview.close()
            completions.close()
        }
        guard super.resignFirstResponder() else { return false }
        keyboardChanged(false)
        return true
    }

    func keyChanged() {
        if !hasKeyboard { completions.close() }
        previewMath()
    }

    func offset(_ location: any NSTextLocation) -> Int { textLayoutManager?.textContentManager?.offset(of: location) ?? 0 }

    func textRange(_ range: NSRange) -> NSTextRange? { textLayoutManager?.textContentManager?.textRange(of: range) }
}
