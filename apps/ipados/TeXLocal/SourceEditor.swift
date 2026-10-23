import SwiftUI
import UIKit

final class SourceEditor: NSObject, UITextViewDelegate {
    let textView = SourceTextView.plainDocument()
    /// The text view, and what floats over it: the completion list and the maths preview.
    let container = EditorContainer()
    /// The caret's line and column.
    var onCursor: (Int, Int) -> Void = { _, _ in }
    /// The top line.
    var onScroll: (Int) -> Void = { _ in }

    private(set) var path: String?
    /// Their state and scroll come back only if their text is unchanged since, as Xcode's do.
    private var kept: [String: (text: String, undo: UndoManager, selection: NSRange, top: (offset: Int, below: CGFloat)?)] = [:]

    /// Hidden, it is out of the focus loop; shown, it takes the focus a file's open asked for.
    var shown = false {
        didSet {
            container.isHidden = !shown
            if shown, !oldValue, focusWhenShown { focus() }
        }
    }
    private var focusWhenShown = false

    let changes = EditorChanges()

    override init() {
        super.init()
        textView.delegate = self
        textView.fontSize = CGFloat(EditorPrefs.fontSize)
        container.install(textView)
        container.isHidden = true
        // A jump's top line is known once the viewport is laid out there.
        textView.laidOut = { [weak self] in self?.reportTop() }
    }

    // MARK: - Files

    /// `source` is the session's document of `path`, which holds `text`.
    func open(path: String, text: String, source: SourceDocument? = nil, focus: Bool) {
        if let current = self.path { kept[current] = (textView.text, textView.undo, textView.selectedRange, textView.shownTop) }
        // By UTF-16, as the undo stack counts: Swift's `==` holds across Unicode normal forms.
        let prior = kept[path].flatMap { ($0.text as NSString).isEqual(to: text) ? $0 : nil }
        self.path = path
        textView.load(text, source: source)
        textView.undo = prior?.undo ?? UndoManager()
        textView.selectedRange = prior?.selection ?? .caret(0)
        textView.contentOffset = CGPoint(x: 0, y: -textView.adjustedContentInset.top)
        if let top = prior?.top { textView.scroll(toShownTop: top) }
        reportCursor()
        focusWhenShown = focus
        if focus { self.focus() }
    }

    /// Another app's text for the file shown: a new undo, and the caret and top line where they were, as Xcode's.
    func reload(text: String) {
        textView.undo = UndoManager()
        let selection = textView.selectedRange, top = textView.shownTop
        textView.reload(text)
        let length = textView.length, start = min(selection.location, length)
        textView.selectedRange = NSRange(location: start, length: min(NSMaxRange(selection), length) - start)
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
        textView.focus()
    }

    // MARK: - Where it is

    var caret: Int { textView.selectedRange.location }
    var currentLine: Int { textView.document.line(at: caret) }
    var currentColumn: Int { caret - textView.document.lineStart(currentLine) }

    /// What it found is marked, as no selection shows without the keyboard.
    func reveal(line: Int, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let (selection, found) = revealed(line: line, column: column, length: length)
        textView.selectedRange = selection
        atTop ? textView.scroll(toTop: textView.document.lineStart(line)) : textView.centerSelection()
        if focus { self.focus() }
        if found.length > 0, column != nil { textView.mark(found, found: true) }
    }

    private func reportTop() { if let line = textView.topLine { onScroll(line) } }
    private func reportCursor() { onCursor(currentLine, currentColumn) }

    // MARK: - UIKit's text view

    func textView(_ view: UITextView, shouldChangeTextInRanges ranges: [NSValue], replacementText text: String) -> Bool {
        textView.changing = ranges.count == 1 ? ranges[0].rangeValue : nil
        return true
    }

    func textViewDidChange(_ view: UITextView) {
        changes.count += 1
        textView.textChanged()
    }

    func textViewDidChangeSelection(_ view: UITextView) {
        changes.count += 1
        textView.selectionChanged()
        guard !textView.loading else { return }
        reportCursor()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        textView.scrolled()
        reportTop()
    }

    /// UIKit offers no way to keep its spelling to the prose, which only Writing Tools can be told.
    func textView(_ view: UITextView, writingToolsIgnoredRangesInEnclosingRange range: NSRange) -> [NSValue] {
        textView.document.codeRanges(in: range, for: .writingTools).map(NSValue.init(range:))
    }

    /// A misspelt word's guesses first, then the Mac's context menu's commands, which the project performs, then UIKit's.
    func textView(_ view: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
        let spelling = textView.misspelling().map { word in
            word.guesses.map { guess in UIAction(title: guess) { [weak self] _ in self?.textView.correctSpelling(word.range, to: guess) } }
                + [UIAction(title: String(localized: "Learn Spelling")) { [weak self] _ in self?.textView.learnSpelling(word.range) }]
        } ?? []
        let offered: [(MenuCommand, Bool)] = [
            (.jumpToDefinition, textView.document.definition(at: caret) != nil),
            (.editRename, textView.isEditable && renamable != nil),
            (.syncForward, textView.forwardSync(false) != nil), (.editComment, textView.isEditable),
        ]
        let ours = offered.filter(\.1).map { command, _ in UIAction(title: command.title) { [weak self] _ in self?.command(command) } }
        // AutoFill's passwords and contacts have no place in LaTeX.
        func kept(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.compactMap { element in
                guard let menu = element as? UIMenu else { return element }
                return menu.identifier == .autoFill ? nil : menu.replacingChildren(kept(menu.children))
            }
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: spelling), UIMenu(options: .displayInline, children: ours)]
            + kept(suggestedActions))
    }

    /// The edit menu's items are the menu bar's commands, which the project performs.
    var command: (MenuCommand) -> Void = { _ in }
}

/// Holds the text view, keeps its text clear of the keyboard, and has what floats over it: the completion list and the
/// maths preview, which stay within it.
final class EditorContainer: UIView {
    private weak var textView: SourceTextView?
    /// From the keyboard's top to the view's foot, as the keyboard layout guide follows it docked, split or floating.
    private let keyboard = UIView()

    func install(_ text: SourceTextView) {
        clipsToBounds = true
        addSubview(text)
        textView = text
        keyboard.isHidden = true
        keyboard.isUserInteractionEnabled = false
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboard)
        keyboardLayoutGuide.followsUndockedKeyboard = true
        keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: keyboardLayoutGuide.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: keyboardLayoutGuide.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let textView else { return }
        // A pane folded to nothing keeps its text laid out at its last width, rather than a character to a line.
        if bounds.width >= 100, textView.frame != bounds { textView.frame = bounds }
        // A floating keyboard covers a corner, which a scroll moves the text out from under; a docked or split one, all of
        // the text's width.
        let covered = keyboard.frame.intersection(textView.frame)
        let inset = !covered.isNull && covered.width >= textView.frame.width / 2 ? covered.height : 0
        guard textView.contentInset.bottom != inset else { return }
        let grew = inset > textView.contentInset.bottom
        textView.contentInset.bottom = inset
        textView.verticalScrollIndicatorInsets.bottom = inset
        if grew, textView.isFirstResponder { textView.scrollRangeToVisible(textView.selectedRange) }
    }
}

struct EditorView: UIViewRepresentable {
    let editor: SourceEditor
    let shown: Bool
    @AppStorage(DefaultsKey.editorFontName) private var fontName = ""
    @AppStorage(DefaultsKey.editorFontSize) private var fontSize = EditorPrefs.fontSize
    @AppStorage(DefaultsKey.editorLineNumbers) private var lineNumbers = true
    @AppStorage(DefaultsKey.editorSyntaxTheme) private var syntaxTheme = SyntaxTheme.system
    @AppStorage(DefaultsKey.editorAutoPair) private var autoPair = true
    @AppStorage(DefaultsKey.editorAutoComplete) private var autoComplete = true
    @AppStorage(DefaultsKey.editorSpellCheck) private var spellCheck = true

    func makeUIView(context: Context) -> EditorContainer { editor.container }

    func updateUIView(_ view: EditorContainer, context: Context) {
        // A new size only: setting one builds the font.
        if editor.textView.fontSize != CGFloat(fontSize) { editor.textView.fontSize = CGFloat(fontSize) }
        editor.textView.fontName = fontName
        editor.textView.showsLineNumbers = lineNumbers
        editor.textView.syntaxTheme = syntaxTheme
        editor.textView.autoPair = autoPair
        editor.textView.autoComplete = autoComplete
        editor.textView.checksSpelling = spellCheck
        if editor.shown != shown { editor.shown = shown }
    }
}
