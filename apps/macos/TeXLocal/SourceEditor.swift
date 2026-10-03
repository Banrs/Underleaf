import AppKit
import SwiftUI

/// A word plus its occurrence in source/PDF text. Offsets are UTF-16, as AppKit/PDFKit use.
nonisolated struct SyncTeXWord: Equatable, Sendable {
    let text: String
    let offset: Int
    let context: String
    let contextOffset: Int
}

/// One native text view shared across files, preserving each file's undo and selection.
/// Owns formatting commands; find is the text view's own find bar.
final class SourceEditor: NSObject, NSTextViewDelegate {
    let scrollView = SourceTextView.scrollablePlainDocumentContentTextView()
    let textView: SourceTextView
    var onChanged: () -> Void = {}
    /// The caret's line and column (UTF-16, from 0).
    var onCursor: (Int, Int) -> Void = { _, _ in }
    /// The line at the top of the view.
    var onScroll: (Int) -> Void = { _ in }

    private(set) var path: String?
    /// The files shown before, as they were left: their state comes back
    /// only if their text is unchanged since.
    private var kept: [String: (text: String, undo: UndoManager, selection: NSRange)] = [:]
    private var undo = UndoManager()
    private var cursorLine = 1, cursorColumn = 0, topLine = 1

    /// Hiding removes the editor from the key view loop; showing it restores
    /// requested focus after a file opens.
    var shown = false {
        didSet {
            scrollView.isHidden = !shown
            if shown, !oldValue, focusWhenShown { focus() }
        }
    }
    private var focusWhenShown = false

    override init() {
        textView = scrollView.documentView as! SourceTextView
        super.init()
        let text = textView
        text.usesFontPanel = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        // Xcode's first line, measured: its highlight 8 pt under the bar, a point under where TextKit's line starts.
        text.textContainerInset = NSSize(width: 0, height: 7)
        text.fontSize = NSFont.systemFontSize
        // Xcode's theme colours; its caret is the text's.
        text.selectedTextAttributes = [.backgroundColor: NSColor.sourceSelection]
        text.insertionPointColor = .textColor
        text.allowsUndo = true
        // Native spelling, correction and text replacement in prose only (below); the last
        // two as the user has them in System Settings, which a text view follows unless
        // told otherwise (NSSpellChecker.h), and Edit › Substitutions. Smart dashes and
        // quotes would rewrite the LaTeX (-- to an em dash).
        text.isContinuousSpellCheckingEnabled = EditorPrefs.spellCheck
        text.isGrammarCheckingEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.smartInsertDeleteEnabled = false
        text.inlinePredictionType = .no
        text.setAccessibilityLabel(String(localized: "Source"))
        text.delegate = self
        text.textStorage?.delegate = text
        scrollView.autohidesScrollers = true
        // The clip shows under the toolbar above the first line, where AppKit
        // takes the column's colour for its band and edge effect.
        scrollView.drawsBackground = true
        scrollView.isHidden = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // ---------- files ----------

    /// Show a file at its top; sidebar selection leaves keyboard focus where it is.
    func open(path: String, text: String, focus: Bool = true) {
        if let current = self.path { kept[current] = (textView.string, undo, textView.selectedRange()) }
        let prior = kept[path].flatMap { $0.text == text ? $0 : nil }
        self.path = path
        textView.load(text)
        undo = prior?.undo ?? UndoManager()
        let selection = prior?.selection ?? NSRange(location: 0, length: 0)
        textView.setSelectedRange(NSMaxRange(selection) <= (text as NSString).length ? selection : NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        reportCursor()
        focusWhenShown = focus
        if focus { self.focus() }
    }

    var document: (path: String, text: String)? {
        path.map { ($0, textView.committedString) }
    }

    /// Forget a file's kept state after it's deleted, or every file's under a deleted folder.
    func forget(path: String) {
        kept = kept.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    /// Preserve file state, including undo, across file or folder renames.
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

    // ---------- where it is ----------

    var currentLine: Int {
        textView.document.line(at: textView.selectedRange().location)
    }

    /// SyncTeX needs the occurrence within the source line, not just its spelling.
    var currentSyncWord: SyncTeXWord? {
        let source = textView.string as NSString
        let position = textView.selectedRange().location
        let caret = NSRange(location: position, length: 0)
        let range = textView.selectionRange(forProposedRange: caret, granularity: .selectByWord)
        let selected = source.substring(with: range)
        let word = selected.trimmingCharacters(in: .alphanumerics.inverted)
        guard !word.isEmpty else { return nil }
        let start = range.location + (selected as NSString).range(of: word).location
        let line = source.lineRange(for: caret)
        return SyncTeXWord(text: word, offset: min(max(position - start, 0), (word as NSString).length - 1),
                           context: source.substring(with: line), contextOffset: start - line.location)
    }

    var currentColumn: Int { textView.selectedRange().location - textView.document.lineStart(currentLine) }

    /// Put the line at the top or centre; a column selects its word.
    /// Show the system find indicator after the scroll completes.
    func reveal(line: Int, column: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let document = textView.document
        let start = document.lineStart(line)
        let end = line < document.lineCount ? document.lineStart(line + 1) - 1 : (textView.string as NSString).length
        let word = column.map {
            textView.selectionRange(forProposedRange: NSRange(location: min(start + $0, end), length: 0), granularity: .selectByWord)
        }
        textView.setSelectedRange(word ?? NSRange(location: start, length: 0))
        scroll(to: start, atTop: atTop)
        if focus { self.focus() }
        let shown = word ?? NSRange(location: start, length: end - start)
        if shown.length > 0 {
            // Once the scroll's layout is done.
            DispatchQueue.main.async { self.textView.showFindIndicator(for: shown) }
        }
    }

    private func scroll(to offset: Int, atTop: Bool) {
        guard let target = textView.textRange(NSRange(location: offset, length: 0)) else { return }
        let insets = scrollView.contentInsets, shown = scrollView.contentView.bounds.height - insets.top - insets.bottom
        textView.scroll(target.location) { atTop ? $0.minY - insets.top : $0.midY - insets.top - shown / 2 }
    }

    /// The first line at least half showing below the toolbar.
    @objc private func scrolled() {
        textView.previewMath()
        guard let manager = textView.textLayoutManager, let font = textView.font else { return }
        let y = scrollView.contentView.bounds.minY + scrollView.contentInsets.top - textView.textContainerOrigin.y
            + font.boundingRectForFont.height / 2
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else { return }
        let line = textView.document.line(at: textView.offset(fragment.rangeInElement.location))
        guard line != topLine else { return }
        topLine = line
        onScroll(line)
    }

    private func reportCursor() {
        let line = currentLine, column = currentColumn
        guard line != cursorLine || column != cursorColumn else { return }
        (cursorLine, cursorColumn) = (line, column)
        onCursor(line, column)
    }

    func textDidChange(_ notification: Notification) {
        onChanged()
    }

    /// Spelling, correction and text replacement apply to prose, including comments and
    /// math's text arguments; commands, math, literal code and TeX names are protected.
    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        let document = textView.document
        // The highlighter also colours words inside \text{…} as math. The
        // prose scan owns those boundaries; colours supply syntax names only.
        let code = document.highlights(in: range).filter {
            [.command, .argument, .stringLiteral, .builtin].contains($0.kind)
        }.map(\.range) + document.notProse(in: range)
        return results.filter { result in
            // Language metadata can span both prose and TeX without changing it.
            if result.resultType == .orthography { return true }
            // Native results count from the checked range's start. Rebase only
            // the comparison and return the original results for AppKit to apply.
            let found = NSRange(location: range.location + result.range.location, length: result.range.length)
            return !code.contains { NSIntersectionRange($0, found).length > 0 }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !textView.loading else { return }
        reportCursor()
    }

    /// The system's text menu, with Go to PDF Position above it while there's somewhere to go.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard textView.forwardSync() != nil else { return menu }
        let item = NSMenuItem(title: MenuCommand.syncForward.title, action: #selector(goToPDF), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func goToPDF() { textView.forwardSync()?() }

    // ---------- commands ----------

    /// False when there's no text to run it on, or no block of that id.
    @discardableResult
    func perform(_ command: EditorCommand, _ argument: String? = nil) -> Bool {
        guard path != nil else { return false }
        let document = textView.document, selection = textView.selectedRange()
        let insert = { (insertion: Insertion?, name: String) in
            guard let insertion else { return false }
            self.textView.apply([insertion.edit], named: name, select: NSRange(location: insertion.caret, length: 0))
            self.textView.startSnippet(insertion.fields, at: insertion.edit.start)
            return true
        }
        switch command {
        case .bold: wrap("\\textbf{", "}", named: String(localized: "Bold"))
        case .italic: wrap("\\textit{", "}", named: String(localized: "Italic"))
        case .math: wrap("$", "$", named: String(localized: "Inline Math"))
        case .displayMath: wrap("\\[", "\\]", named: String(localized: "Display Math"))
        case .inline:
            // A template such as \ref{$0}: "$0" is where the selection goes.
            let parts = ((argument ?? "") + "$0").components(separatedBy: "$0")
            wrap(parts[0], parts[1...].dropLast().joined(separator: "$0"), named: String(localized: "Insert"))
            // Empty braces: the labels or citations for them, once the menu has closed.
            if selection.length == 0 { DispatchQueue.main.async { self.textView.complete(nil) } }
        case .comment:
            textView.apply(document.toggleComment(textView.selectedRanges.map(\.rangeValue)), named: String(localized: "Comment"))
        case .heading:
            guard insert(document.setHeading(caret: selection.location, command: argument ?? ""), String(localized: "Section Level")) else { return false }
        case .symbol:
            guard insert(document.insertSymbol(argument ?? "", replacing: selection), String(localized: "Insert Symbol")) else { return false }
        case .block:
            guard insert(document.insertBlock(argument ?? "", replacing: selection), String(localized: "Insert")) else { return false }
        }
        focus()
        return true
    }

    /// Round the selection, which stays selected (or the caret, between them).
    private func wrap(_ prefix: String, _ suffix: String, named name: String) {
        let selection = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: selection)
        let edit = TextEdit(selection, prefix + selected + suffix)
        textView.apply([edit], named: name,
                       select: NSRange(location: selection.location + (prefix as NSString).length, length: selection.length))
    }

    // ---------- font ----------

    func setFontSize(_ size: Int) {
        textView.fontSize = CGFloat(size)
    }

    func setSyntaxTheme(_ theme: SyntaxTheme) {
        textView.syntaxTheme = theme
    }
}

/// Reuse the editor's scroll view across SwiftUI updates and beneath the bars,
/// where AppKit draws its edge effect.
struct EditorView: NSViewRepresentable {
    let editor: SourceEditor
    let shown: Bool

    func makeNSView(context: Context) -> NSScrollView { editor.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        if editor.shown != shown { editor.shown = shown }
    }
}

enum EditorCommand {
    case bold, italic, math, displayMath, comment, heading, symbol
    /// A block from the core's catalog (crates/texlocal-syntax), by id.
    case block
    /// A template with "$0" where the selection goes.
    case inline
}

enum EditorPrefs {
    static let fontSizeKey = "editorFontSize", spellCheckKey = "editorSpellCheck", syntaxThemeKey = "editorSyntaxTheme"
    static let fontSize = Int(NSFont.systemFontSize)

    /// Edit › Spelling and Grammar › Check Spelling While Typing, as last set; on at first.
    static var spellCheck: Bool {
        get { UserDefaults.standard.object(forKey: spellCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: spellCheckKey) }
    }
}
