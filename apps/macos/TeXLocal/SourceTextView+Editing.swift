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

    // MARK: typing: the core's brackets, indentation and snippet fields

    func markedTextChanged() {
        guard hasMarkedText() != toldComposing else { return }
        toldComposing.toggle()
        composing(toldComposing)
    }

    func finish(_ stroke: Keystroke) {
        if let selection = stroke.selection { self.selection = selection.range }
        if let partner = stroke.partner { showPartner(of: partner) }
        switch stroke.completions {
        case .keep: break
        case .offer: completions.offer()
        case .close: completions.close()
        }
    }

    /// A snippet's next field, or the lines indented.
    func tab(_ step: Int) {
        let answer = document.tab(selections, step: step)
        if let field = answer.field { return selection = field.range }
        apply(answer.edits, named: step > 0 ? String(localized: "Indent") : String(localized: "Outdent"))
    }

    /// Shift Right and Shift Left: the lines, even from within a snippet's field, which Tab would leave for the next.
    func shiftLines(_ step: Int) {
        guard isEditable else { return }
        _ = document.endSnippet()
        tab(step)
    }

    /// Escape: the completion list closes, the snippet's fields are left, the maths preview is dismissed, or else the
    /// completions are offered.
    func cancel() {
        if completions.offered != nil {
            completions.close()
        } else if document.endSnippet() {
            // Escape leaves the snippet's fields.
        } else if mathPreview.isWanted, let maths = math(at: caret) {
            dismissedMath = maths.start
            mathPreview.close()
        } else {
            completions.complete(explicit: true)
        }
    }

    // MARK: VoiceOver's rotors

    /// The outline's headings, or the issues with what they say: the first after `line`, or the last before it.
    func rotorItem(issues listed: Bool, from line: Int?, next: Bool, filter: String = "") -> (range: NSRange, title: String)? {
        var items = !listed ? headings() : Set(issues.lines.keys).union(issues.live.keys).sorted().compactMap { line in
            issues.issue(on: line).map { issue, live in
                let place = live ? String(localized: "Live Preview error on line \(line)")
                    : issue.error ? String(localized: "Error on line \(line)") : String(localized: "Warning on line \(line)")
                return (line, String(localized: "\(place): \(issue.message)"))
            }
        }
        if !filter.isEmpty { items = items.filter { $0.title.localizedCaseInsensitiveContains(filter) } }
        guard let found = next ? items.first(where: { $0.line > line ?? 0 }) : items.last(where: { $0.line < line ?? .max })
        else { return nil }
        // The outline and the issues are a moment behind the text: within what there is of it.
        return (source.lineRange(for: .caret(min(document.lineStart(found.line), length))), found.title)
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
