import AppKit

extension SourceEditor {
    func open(path: String, source: SourceDocument) {
        if let current = self.path {
            kept[current] = (textView.source as String, textView.undo, textView.selection, textView.shownTop, textView.folds)
        }
        self.path = path
        textView.load(source)
        let prior = kept[path].flatMap { textView.source.isEqual(to: $0.text) ? $0 : nil }
        textView.undo = prior?.undo ?? UndoManager()
        if let folds = prior?.folds, !folds.isEmpty {
            textView.folds = folds
            textView.relayOutFolds()
        }
        textView.selection = prior?.selection ?? .caret(0)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if let top = prior?.top { textView.scroll(toShownTop: top) }
        reportCursor()
    }

    func reload(_ source: SourceDocument) {
        let selection = textView.selection, top = textView.shownTop
        textView.load(source)
        textView.undo = UndoManager()
        let length = textView.length, start = min(selection.location, length)
        textView.selection = NSRange(location: start, length: min(NSMaxRange(selection), length) - start)
        top.map(textView.scroll(toShownTop:))
        reportCursor()
    }

    func forget(path: String) { kept = kept.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }

    func rename(from: String, to: String) {
        forget(path: to)
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
    var shownColumn: Int { textView.source.substring(with: NSRange(location: caret - currentColumn, length: currentColumn)).count + 1 }

    func reportTop() { if let line = textView.topLine { onScroll(line) } }
    func reportCursor() { onCursor(currentLine, currentColumn, shownColumn) }
}
