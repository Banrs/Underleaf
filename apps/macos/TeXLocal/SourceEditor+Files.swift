import AppKit

/// The file the editor shows, and where in it the caret and the shown text are.
extension SourceEditor {
    /// `source` is the session's document of `path`, which holds `text`.
    func open(path: String, text: String, source: SourceDocument? = nil, focus: Bool) {
        if let current = self.path {
            kept[current] = (textView.source as String, textView.undo, textView.selection, textView.shownTop, textView.folded)
        }
        // By UTF-16, as the undo stack counts: Swift's `==` holds across Unicode normal forms.
        let prior = kept[path].flatMap { ($0.text as NSString).isEqual(to: text) ? $0 : nil }
        self.path = path
        textView.load(text, source: source)
        textView.undo = prior?.undo ?? UndoManager()
        // Before the selection, which would open a fold it lands in.
        if let folded = prior?.folded, !folded.isEmpty {
            textView.folded = folded
            textView.relayOutFolds()
        }
        textView.selection = prior?.selection ?? .caret(0)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if let top = prior?.top { textView.scroll(toShownTop: top) }
        reportCursor()
        focusWhenShown = focus
        if focus { self.focus() }
    }

    /// Another app's text for the file shown: a new undo, and the caret and top line where they were, as Xcode's.
    func reload(text: String) {
        let selection = textView.selection, top = textView.shownTop
        guard textView.reload(text) else { return }
        textView.undo = UndoManager()
        let length = textView.length, start = min(selection.location, length)
        textView.selection = NSRange(location: start, length: min(NSMaxRange(selection), length) - start)
        top.map(textView.scroll(toShownTop:))
        reportCursor()
    }

    func forget(path: String) { kept = kept.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }

    /// Whatever is kept at the new name is stale, a file gone outside the app: the name was free.
    func rename(from: String, to: String) {
        if to != from { forget(path: to) }
        kept = Dictionary(uniqueKeysWithValues: kept.map { (remapPath($0.key, from: from, to: to), $0.value) })
        path = path.map { remapPath($0, from: from, to: to) }
    }

    func focus() {
        guard shown else { return }
        textView.window?.makeFirstResponder(textView)
    }

    var caret: Int { textView.caret }
    var currentLine: Int { textView.document.line(at: caret) }
    var currentColumn: Int { caret - textView.document.lineStart(currentLine) }

    func reportTop() { if let line = textView.topLine { onScroll(line) } }
    func reportCursor() { onCursor(currentLine, currentColumn) }
}
