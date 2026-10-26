import AppKit

extension SourceEditor {
    func open(path: String, text: String, source: SourceDocument? = nil, focus: Bool) {
        if let current = self.path {
            kept[current] = (textView.source as String, textView.undo, textView.selection, textView.shownTop, textView.folded)
        }
        let prior = kept[path].flatMap { ($0.text as NSString).isEqual(to: text) ? $0 : nil }
        self.path = path
        textView.load(text, source: source)
        textView.undo = prior?.undo ?? UndoManager()
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
