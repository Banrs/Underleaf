import AppKit

/// The text view's work with the core's document, over its selection and keys.
extension SourceTextView {
    /// `source` is the session's document holding `text`.
    func load(_ text: String, source: SourceDocument? = nil) {
        // First: colours and line numbers read the storage against it.
        document = source ?? SourceDocument(text: text)
        show(text)
    }

    /// The disk's text, from the session's `document_reload`: shown without an edit, unless the core kept the view's.
    func reload(_ text: String) -> Bool {
        guard document.reload(text) else { return false }
        show(text)
        return true
    }

    /// The core's edits, and the selections after them. False for none.
    @discardableResult
    func apply(_ change: Change?, named name: String) -> Bool {
        apply(change?.edits ?? [], named: name, selecting: change?.selections.map(\.range))
    }

    /// One undo step with the caret at the insertion's, then its snippet's first field selected. False for none.
    @discardableResult
    func insert(_ insertion: Insertion?, named name: String) -> Bool {
        guard let insertion else { return false }
        apply([insertion.edit], named: name, selecting: [.caret(insertion.caret)])
        if let first = document.startSnippet(insertion.fields, at: insertion.edit.start) { selection = first }
        return true
    }

    // MARK: the keyboard

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

    /// As the window takes or gives up the keyboard.
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

    // MARK: offsets

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
