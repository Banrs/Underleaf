import AppKit
import SwiftUI

final class SourceEditor: NSObject, NSTextViewDelegate {
    let textView = SourceTextView.plainDocument()
    let scrollView = NSScrollView()
    /// The caret's line and column.
    var onCursor: (Int, Int) -> Void = { _, _ in }
    /// The top line.
    var onScroll: (Int) -> Void = { _ in }

    private(set) var path: String?
    /// Their state and scroll come back only if their text is unchanged since, as Xcode's do.
    private var kept: [String: (text: String, undo: UndoManager, selection: NSRange, top: (offset: Int, below: CGFloat)?)] = [:]
    private var undo = UndoManager()

    /// Hidden, it is out of the key view loop; shown, it takes the focus a file's open asked for.
    var shown = false {
        didSet {
            textView.isHidden = !shown
            if shown, !oldValue, focusWhenShown { focus() }
        }
    }
    private var focusWhenShown = false

    private var scrolling: NotificationCenter.ObservationToken?
    let changes = EditorChanges()

    override init() {
        super.init()
        let text = textView
        text.usesFontPanel = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        // The first line's band 8 pt under the text's top, as Xcode's.
        text.textContainerInset = NSSize(width: 0, height: 7)
        text.fontSize = NSFont.systemFontSize
        text.allowsUndo = true
        // Smart dashes and quotes would rewrite the LaTeX; spelling and Writing Tools keep to the prose (below).
        text.isContinuousSpellCheckingEnabled = EditorPrefs.spellCheck
        text.isGrammarCheckingEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.smartInsertDeleteEnabled = false
        text.inlinePredictionType = .no
        text.mathExpressionCompletionType = .no
        text.writingToolsBehavior = .limited
        text.allowedWritingToolsResultOptions = .plainText
        text.setAccessibilityLabel(String(localized: "Source"))
        text.delegate = self
        text.backgroundColor = .untintedTextBackground
        text.isHidden = true
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = text
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scrolling = NotificationCenter.default.addObserver(of: clip, for: .boundsDidChange) { [weak self] _ in
            self?.textView.scrolled()
            self?.reportTop()
        }
        // A jump's top line is known once the viewport is laid out there.
        text.laidOut = { [weak self] in self?.reportTop() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // MARK: - Files

    /// `source` is the session's document of `path`, which holds `text`.
    func open(path: String, text: String, source: SourceDocument? = nil, focus: Bool) {
        if let current = self.path { kept[current] = (textView.string, undo, textView.selectedRange(), textView.shownTop) }
        // By UTF-16, as the undo stack counts: Swift's `==` holds across Unicode normal forms.
        let prior = kept[path].flatMap { ($0.text as NSString).isEqual(to: text) ? $0 : nil }
        self.path = path
        textView.load(text, source: source)
        undo = prior?.undo ?? UndoManager()
        textView.setSelectedRange(prior?.selection ?? .caret(0))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if let top = prior?.top { textView.scroll(toShownTop: top) }
        reportCursor()
        focusWhenShown = focus
        if focus { self.focus() }
    }

    /// Another app's text for the file shown: a new undo, and the caret and top line where they were, as Xcode's.
    func reload(text: String) {
        undo = UndoManager()
        let selection = textView.selectedRange(), top = textView.shownTop
        textView.reload(text)
        let length = textView.text.length, start = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: start, length: min(NSMaxRange(selection), length) - start))
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

    // MARK: - Where it is

    var currentLine: Int { textView.document.line(at: textView.selectedRange().location) }
    var currentColumn: Int { textView.selectedRange().location - textView.document.lineStart(currentLine) }

    /// The match `length` long at `column`, or the word there. The find indicator bounces, so not with Reduce Motion, where
    /// the selection is the mark.
    func reveal(line: Int, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let document = textView.document
        let start = document.lineStart(line)
        let end = line < document.lineCount ? document.lineStart(line + 1) - 1 : textView.text.length
        let found = column.map { column in
            let at = min(start + column, end)
            return length.map { NSRange(location: at, length: min($0, end - at)) }
                ?? textView.selectionRange(forProposedRange: .caret(at), granularity: .selectByWord)
        }
        textView.setSelectedRange(found ?? .caret(start))
        atTop ? textView.scroll(toTop: start) : textView.centerSelectionInVisibleArea(nil)
        if focus { self.focus() }
        let shown = found ?? NSRange(location: start, length: end - start)
        // Once the scroll's layout is done.
        if shown.length > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { Task { self.textView.showFindIndicator(for: shown) } }
    }

    private func reportTop() { if let line = textView.topLine { onScroll(line) } }
    private func reportCursor() { onCursor(currentLine, currentColumn) }

    func textDidChange(_ notification: Notification) { changes.count += 1 }

    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        let code = textView.document.codeRanges(in: range, for: .spelling)
        // Results count from the checked range's start; orthography spans prose and TeX alike.
        return results.filter { result in
            let found = NSRange(location: range.location + result.range.location, length: result.range.length)
            return result.resultType == .orthography || !code.contains { NSIntersectionRange($0, found).length > 0 }
        }
    }

    func textView(_ view: NSTextView, writingToolsIgnoredRangesInEnclosingRange range: NSRange) -> [NSValue] {
        textView.document.codeRanges(in: range, for: .writingTools).map(NSValue.init(range:))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        changes.count += 1
        guard !textView.loading else { return }
        reportCursor()
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let unwanted = [#selector(NSTextView.changeLayoutOrientation(_:)), #selector(NSTextView.startSpeaking(_:)),
                        #selector(NSResponder.uppercaseWord(_:))]
        let offered: [(MenuCommand, Bool)] = [
            (.jumpToDefinition, true), (.editRename, textView.isEditable && renamable != nil),
            (.syncForward, textView.forwardSync(false) != nil), (.editComment, textView.isEditable),
        ]
        let ours = offered.filter(\.1).map { command, _ in
            let item = NSMenuItem(title: command.title, action: #selector(choose), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            return item
        }
        let kept = menu.items.filter { item in
            !unwanted.contains { action in item.action == action || item.submenu?.items.contains { $0.action == action } == true }
        }
        menu.tidy(ours + [.separator()] + kept)
        return menu
    }

    /// The context menu's items are the menu bar's commands, which the project performs.
    var command: (MenuCommand) -> Void = { _ in }

    @objc private func choose(_ item: NSMenuItem) { (item.representedObject as? MenuCommand).map(command) }

    /// At the selection's start. The command is enabled wherever the caret is, so a name nothing defines beeps.
    func jumpToDefinition() {
        guard let place = textView.document.definition(at: textView.selectedRange().location)?.places.first else { return NSSound.beep() }
        textView.openDefinition(place)
    }

    /// The label or citation at the selection's start, which Rename renames everywhere. Read through `changes`, so a menu
    /// showing it follows the caret.
    var renamable: Definition? {
        _ = changes.count
        guard let found = textView.document.definition(at: textView.selectedRange().location),
              ["label", "citation"].contains(found.kind) else { return nil }
        return found
    }

    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        guard path != nil, textView.isEditable else { return false }
        let document = textView.document, selection = textView.selectedRange(), selections = textView.selectedRanges.map(\.rangeValue)
        switch command {
        case .bold: textView.apply(document.toggle(.bold, selections), named: String(localized: "Bold"))
        case .italic: textView.apply(document.toggle(.italic, selections), named: String(localized: "Italic"))
        case .underline: textView.apply(document.toggle(.underline, selections), named: String(localized: "Underline"))
        case .math: textView.apply(document.wrap(selections, in: "$$0$"), named: String(localized: "Inline Math"))
        case .displayMath: textView.apply(document.wrap(selections, in: "\\[$0\\]"), named: String(localized: "Display Math"))
        case .inline(let template, let title):
            textView.apply(document.wrap(selections, in: template), named: Self.insertion(titled: title))
            // Empty braces: their labels or citations, once the menu has closed.
            if selection.length == 0 { Task { self.textView.complete(nil) } }
        case .comment:
            textView.apply(document.toggleComment(selections), named: String(localized: "Comment"))
        case .moveLineUp, .moveLineDown:
            let up = command == .moveLineUp
            let name = up ? String(localized: "Move Line Up") : String(localized: "Move Line Down")
            guard textView.apply(document.moveLines(selections, up: up), named: name) else { return false }
        case .duplicateLine:
            textView.apply(document.duplicateLines(selections), named: String(localized: "Duplicate Line"))
        case .deleteLine:
            textView.apply(document.deleteLines(selections), named: String(localized: "Delete Line"))
        case .heading(let command):
            let level = document.setHeading(caret: selection.location, command: command)
            guard textView.insert(level, named: String(localized: "Section Level")) else { return false }
        case .symbol(let command):
            let symbol = document.insertSymbol(command, replacing: selection)
            guard textView.insert(symbol, named: String(localized: "Insert Symbol")) else { return false }
        case .block(let id, let title):
            let block = document.insertBlock(id, replacing: selection)
            guard textView.insert(block, named: Self.insertion(titled: title)) else { return false }
        }
        focus()
        return true
    }

    private static func insertion(titled title: String?) -> String {
        title.map { String(localized: "Insert \($0)") } ?? String(localized: "Insert")
    }

    var textStyles: TextStyles { path == nil ? TextStyles() : textView.document.textStyles(textView.selectedRange()) }
}

struct EditorView: NSViewRepresentable {
    let editor: SourceEditor
    let shown: Bool
    @AppStorage(DefaultsKey.editorFontName) private var fontName = ""
    @AppStorage(DefaultsKey.editorFontSize) private var fontSize = EditorPrefs.fontSize
    @AppStorage(DefaultsKey.editorLineNumbers) private var lineNumbers = true
    @AppStorage(DefaultsKey.editorSyntaxTheme) private var syntaxTheme = SyntaxTheme.overleaf
    @AppStorage(DefaultsKey.editorAutoPair) private var autoPair = true
    @AppStorage(DefaultsKey.editorAutoComplete) private var autoComplete = true

    func makeNSView(context: Context) -> NSScrollView { editor.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
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

enum EditorCommand: Equatable {
    case bold, italic, underline, math, displayMath, comment, moveLineUp, moveLineDown, duplicateLine, deleteLine
    /// Without its backslash; empty for Normal Text.
    case heading(String)
    case symbol(String)
    /// The core's block by its id; the title names the undo.
    case block(id: String, title: String? = nil)
    /// "$0" is where the selection goes.
    case inline(template: String, title: String? = nil)
}

enum EditorPrefs {
    static let fontSize = Int(NSFont.systemFontSize)
    static let fontSizes = 10...28

    static var spellCheck: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.editorSpellCheck) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.editorSpellCheck) }
    }
}

@Observable final class EditorChanges { var count = 0 }
