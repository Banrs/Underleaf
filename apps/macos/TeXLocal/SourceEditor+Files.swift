import SwiftUI

/// The file the editor shows, and where in it the caret and the shown text are.
extension SourceEditor {
    /// `source` is the session's document of `path`, which holds `text`.
    func open(path: String, text: String, source: SourceDocument? = nil, focus: Bool) {
        if let current = self.path { kept[current] = (textView.source as String, textView.undo, textView.selection, textView.shownTop) }
        // By UTF-16, as the undo stack counts: Swift's `==` holds across Unicode normal forms.
        let prior = kept[path].flatMap { ($0.text as NSString).isEqual(to: text) ? $0 : nil }
        self.path = path
        textView.load(text, source: source)
        textView.undo = prior?.undo ?? UndoManager()
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

struct EditorView {
    let editor: SourceEditor
    let shown: Bool
    @AppStorage(DefaultsKey.editorFontName) private var fontName = ""
    @AppStorage(DefaultsKey.editorFontSize) private var fontSize = EditorPrefs.fontSize
    @AppStorage(DefaultsKey.editorLineNumbers) private var lineNumbers = true
    @AppStorage(DefaultsKey.editorSyntaxTheme) private var syntaxTheme = SyntaxTheme.system
    @AppStorage(DefaultsKey.editorAutoPair) private var autoPair = true
    @AppStorage(DefaultsKey.editorAutoComplete) private var autoComplete = true

    private func update() {
        // A new size only: setting one builds the font.
        if editor.textView.fontSize != CGFloat(fontSize) { editor.textView.fontSize = CGFloat(fontSize) }
        editor.textView.fontName = fontName
        editor.textView.showsLineNumbers = lineNumbers
        editor.textView.syntaxTheme = syntaxTheme
        editor.textView.autoPair = autoPair
        editor.textView.autoComplete = autoComplete
        if editor.shown != shown { editor.shown = shown }
    }
}

extension EditorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView { editor.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) { update() }
}
