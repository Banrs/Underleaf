import AppKit

extension SourceTextView {
    func load(_ text: String, source: SourceDocument? = nil) {
        document = source ?? SourceDocument(text: text)
        show(text)
    }

    func reload(_ text: String) -> Bool {
        guard document.reload(text) else { return false }
        show(text)
        return true
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

    func offset(_ location: any NSTextLocation) -> Int {
        guard let storage = textLayoutManager?.textContentManager else { return 0 }
        return storage.offset(from: storage.documentRange.location, to: location)
    }

    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let storage = textLayoutManager?.textContentManager,
              let start = storage.location(storage.documentRange.location, offsetBy: range.location),
              let end = storage.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
