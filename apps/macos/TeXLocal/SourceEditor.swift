import AppKit
import SwiftUI

final class SourceEditor: NSObject, NSTextViewDelegate {
    let textView = SourceTextView.plainDocument()
    let scrollView = NSScrollView()
    /// The caret's line and column, told as the selection moves or a file opens.
    var onCursor: (Int, Int) -> Void = { _, _ in }
    /// The top line, told as a scroll or a layout may have changed it.
    var onScroll: (Int) -> Void = { _ in }

    private(set) var path: String?
    /// Their state and scroll come back only if their text is unchanged since, as Xcode's do.
    private var kept: [String: (text: String, undo: UndoManager, selection: NSRange, top: (offset: Int, below: CGFloat)?)] = [:]
    private var undo = UndoManager()

    /// Hiding removes the editor from the key view loop; showing it restores requested focus after a file opens.
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
        // The first line's band 8 pt under the text's top, as Xcode's: the band is a point into the line's fragment (rowShift).
        text.textContainerInset = NSSize(width: 0, height: 7)
        text.fontSize = NSFont.systemFontSize
        text.allowsUndo = true
        // Smart dashes and quotes would rewrite the LaTeX (-- to an em dash), so spelling, correction and text replacement apply to prose only (below).
        text.isContinuousSpellCheckingEnabled = EditorPrefs.spellCheck
        text.isGrammarCheckingEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.smartInsertDeleteEnabled = false
        text.inlinePredictionType = .no
        // An answer offered after "2+3=" would be the system's sum in the LaTeX.
        text.mathExpressionCompletionType = .no
        // Writing Tools proofread and rewrite the prose in place, as plain text, and leave the LaTeX alone (below).
        text.writingToolsBehavior = .limited
        text.allowedWritingToolsResultOptions = .plainText
        text.setAccessibilityLabel(String(localized: "Source"))
        text.delegate = self
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
        // A jump's new top line is known once the viewport is laid out there.
        text.laidOut = { [weak self] in self?.reportTop() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // MARK: - Files

    /// `source` is the session's document of `path`, which holds `text`.
    func open(path: String, text: String, source: SourceDocument? = nil, focus: Bool) {
        if let current = self.path { kept[current] = (textView.string, undo, textView.selectedRange(), textView.shownTop) }
        // By UTF-16, as the kept ranges count: Swift's `==` also holds for a file rewritten in another Unicode normal form,
        // whose undo stack would then replace the wrong ranges.
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

    /// Another app's text for the file shown, from the session: its undo was the old text's. The caret and the top line
    /// stay where they were, as Xcode's do, within the new text.
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

    /// Shows the system find indicator after the scroll completes; it bounces, so not with Reduce Motion, where the selected word or the caret's line is the mark.
    func reveal(line: Int, column: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let document = textView.document
        let start = document.lineStart(line)
        let end = line < document.lineCount ? document.lineStart(line + 1) - 1 : textView.text.length
        let word = column.map { textView.selectionRange(forProposedRange: .caret(min(start + $0, end)), granularity: .selectByWord) }
        textView.setSelectedRange(word ?? .caret(start))
        atTop ? textView.scroll(toTop: start) : textView.centerSelectionInVisibleArea(nil)
        if focus { self.focus() }
        let shown = word ?? NSRange(location: start, length: end - start)
        if shown.length > 0, !textView.reducesMotion() {
            // Once the scroll's layout is done.
            Task { self.textView.showFindIndicator(for: shown) }
        }
    }

    private func reportTop() { if let line = textView.topLine { onScroll(line) } }
    private func reportCursor() { onCursor(currentLine, currentColumn) }

    func textDidChange(_ notification: Notification) { changes.count += 1 }

    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        let code = textView.document.codeRanges(in: range, for: .spelling)
        return results.filter { result in
            // Language metadata can span both prose and TeX without changing it.
            if result.resultType == .orthography { return true }
            // Native results count from the checked range's start. Rebase only the comparison and return the original results for AppKit to apply.
            let found = NSRange(location: range.location + result.range.location, length: result.range.length)
            return !code.contains { NSIntersectionRange($0, found).length > 0 }
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
        for item in menu.items where unwanted.contains(where: { action in
            item.action == action || item.submenu?.items.contains { $0.action == action } == true
        }) {
            menu.removeItem(item)
        }
        menu.insertItem(.separator(), at: 0)
        for (shown, command, action) in [(textView.isEditable, MenuCommand.editComment, #selector(toggleComment)),
                                         (textView.forwardSync(false) != nil, MenuCommand.syncForward, #selector(goToPDF))] where shown {
            let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
        }
        // A separator only between two groups.
        for item in menu.items.reversed() where item.isSeparatorItem {
            let index = menu.index(of: item)
            if index == 0 || index == menu.numberOfItems - 1 || menu.item(at: index + 1)?.isSeparatorItem == true { menu.removeItem(item) }
        }
        return menu
    }

    @objc private func goToPDF() { textView.forwardSync(false)?() }
    @objc private func toggleComment() { perform(.comment) }

    // MARK: - Commands

    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        guard path != nil, textView.isEditable else { return false }
        let document = textView.document, selection = textView.selectedRange(), selections = textView.selectedRanges.map(\.rangeValue)
        let insert = { (insertion: Insertion?, name: String) in
            guard let insertion else { return false }
            self.textView.apply([insertion.edit], named: name, selecting: [.caret(insertion.caret)])
            self.textView.startSnippet(insertion.fields, at: insertion.edit.start)
            return true
        }
        switch command {
        case .bold: textView.apply(document.toggle(.bold, selections), named: String(localized: "Bold"))
        case .italic: textView.apply(document.toggle(.italic, selections), named: String(localized: "Italic"))
        case .underline: textView.apply(document.toggle(.underline, selections), named: String(localized: "Underline"))
        case .math: textView.apply(document.wrap(selections, in: "$$0$"), named: String(localized: "Inline Math"))
        case .displayMath: textView.apply(document.wrap(selections, in: "\\[$0\\]"), named: String(localized: "Display Math"))
        case .inline(let template, let title):
            textView.apply(document.wrap(selections, in: template), named: Self.insertion(titled: title))
            // Empty braces: the labels or citations for them, once the menu has closed.
            if selection.length == 0 { Task { self.textView.complete(nil) } }
        case .comment:
            textView.apply(document.toggleComment(selections), named: String(localized: "Comment"))
        case .moveLineUp, .moveLineDown:
            let up = command == .moveLineUp
            guard textView.apply(document.moveLines(selections, up: up),
                                 named: up ? String(localized: "Move Line Up") : String(localized: "Move Line Down")) else { return false }
        case .heading(let command):
            guard insert(document.setHeading(caret: selection.location, command: command), String(localized: "Section Level")) else { return false }
        case .symbol(let command):
            guard insert(document.insertSymbol(command, replacing: selection), String(localized: "Insert Symbol")) else { return false }
        case .block(let id, let title):
            guard insert(document.insertBlock(id, replacing: selection), Self.insertion(titled: title)) else { return false }
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
        // A new size only: setting one builds the font to compare.
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
    case bold, italic, underline, math, displayMath, comment, moveLineUp, moveLineDown
    /// A section command without its backslash; empty for Normal Text.
    case heading(String)
    case symbol(String)
    /// A block of the core's by its id; the title names the undo.
    case block(id: String, title: String? = nil)
    /// A template whose "$0" is where the selection goes.
    case inline(template: String, title: String? = nil)
}

enum EditorPrefs {
    static let fontSize = Int(NSFont.systemFontSize)
    static let fontSizes = 10...28

    static func stepFontSize(by step: Int) {
        let current = UserDefaults.standard.object(forKey: DefaultsKey.editorFontSize) as? Int ?? fontSize
        UserDefaults.standard.set(min(max(current + step, fontSizes.lowerBound), fontSizes.upperBound), forKey: DefaultsKey.editorFontSize)
    }

    static var spellCheck: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.editorSpellCheck) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.editorSpellCheck) }
    }
}

@Observable final class EditorChanges { var count = 0 }
