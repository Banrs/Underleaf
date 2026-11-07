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
        guard let insertion else { return false }
        apply([insertion.edit], named: name, selecting: [.caret(insertion.caret)])
        if let first = document.startSnippet(insertion.fields, at: insertion.edit.start) { selection = first }
        return true
    }

    /// Looks only at the pasteboard's types: reading its text outside a paste asks the person's leave.
    var canPasteTable: Bool { isEditable && document.editable && NSPasteboard.general.availableType(from: [.string]) != nil }

    /// Pastes spreadsheet cells as a tabular on a line of its own, at the current line's indentation.
    func pasteTable(from board: NSPasteboard = .general, booktabs: Bool) -> Bool {
        let at = selectedRange(), line = source.lineRange(for: .caret(at.location))
        let indent = String(source.substring(with: line).prefix { $0 == " " || $0 == "\t" })
        guard isEditable, let cells = board.string(forType: .string),
              let table = Syntax.call(Tabular(cells: cells, indent: indent, booktabs: booktabs)) ?? nil else { return false }
        let before = source.substring(with: NSRange(location: line.location, length: at.location - line.location))
        let text = before.allSatisfy { $0 == " " || $0 == "\t" } ? table : "\n\(indent)\(table)"
        return apply([TextEdit(at, text)], named: String(localized: "Paste as Table"),
                     selecting: [.caret(at.location + (text as NSString).length)])
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

    func math(at caret: Int) -> MathPreview? {
        if let lastMath, lastMath.caret == caret { return lastMath.value }
        let value = document.mathAt(caret: caret)
        lastMath = (caret, value)
        return value
    }

    func offset(_ location: any NSTextLocation) -> Int { textLayoutManager?.textContentManager?.offset(of: location) ?? 0 }

    func textRange(_ range: NSRange) -> NSTextRange? { textLayoutManager?.textContentManager?.textRange(of: range) }
}
