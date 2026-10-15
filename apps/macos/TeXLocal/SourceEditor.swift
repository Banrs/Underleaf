import AppKit
import SwiftUI

nonisolated struct SyncTeXWord: Equatable, Sendable {
    let text: String
    let offset: Int
    let context: String
    let contextOffset: Int
}

final class SourceEditor: NSObject, NSTextViewDelegate {
    let textView = SourceTextView.plainDocument()
    let scrollView = NSScrollView()
    var onCursor: (Int, Int) -> Void = { _, _ in }
    var onScroll: (Int) -> Void = { _ in }

    private(set) var path: String?
    /// Their state and scroll come back only if their text is unchanged since, as Xcode's do.
    private var kept: [String: (text: String, undo: UndoManager, selection: NSRange, top: (offset: Int, below: CGFloat)?)] = [:]
    private var undo = UndoManager()
    private var cursorLine = 1, cursorColumn = 0, topLine = 1

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
        text.backgroundColor = .untintedTextBackground
        text.isHidden = true
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = text
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scrolling = NotificationCenter.default.addObserver(of: clip, for: .boundsDidChange) { [weak self] _ in self?.scrolled() }
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
        textView.setSelectedRange(prior?.selection ?? NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if let top = prior?.top { textView.scroll(toShownTop: top) }
        reportCursor()
        focusWhenShown = focus
        if focus { self.focus() }
    }

    /// Another app's text for the file shown, from the session: its undo was the old text's.
    func reload(text: String) {
        undo = UndoManager()
        textView.reload(text)
        reportCursor()
    }

    var document: (path: String, text: String)? {
        path.map { ($0, textView.string) }
    }

    func forget(path: String) {
        kept = kept.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

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

    var currentLine: Int {
        textView.document.line(at: textView.selectedRange().location)
    }

    var currentSyncWord: SyncTeXWord? {
        let source = textView.text
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

    /// Shows the system find indicator after the scroll completes; it bounces, so not with Reduce Motion, where the selected word or the caret's line is the mark.
    func reveal(line: Int, column: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let document = textView.document
        let start = document.lineStart(line)
        let end = line < document.lineCount ? document.lineStart(line + 1) - 1 : textView.text.length
        let word = column.map {
            textView.selectionRange(forProposedRange: NSRange(location: min(start + $0, end), length: 0), granularity: .selectByWord)
        }
        textView.setSelectedRange(word ?? NSRange(location: start, length: 0))
        scroll(to: start, atTop: atTop)
        if focus { self.focus() }
        let shown = word ?? NSRange(location: start, length: end - start)
        if shown.length > 0, !textView.reducesMotion() {
            // Once the scroll's layout is done.
            Task { self.textView.showFindIndicator(for: shown) }
        }
    }

    private func scroll(to offset: Int, atTop: Bool) {
        guard let target = textView.textRange(NSRange(location: offset, length: 0)) else { return }
        let insets = scrollView.contentInsets, shown = scrollView.contentView.bounds.height - insets.top - insets.bottom
        textView.scroll(target.location) { atTop ? $0.minY - insets.top : $0.midY - insets.top - shown / 2 }
    }

    private func scrolled() {
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
        changes.count += 1
    }

    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        let code = code(in: range, kinds: [.command, .argument, .stringLiteral, .builtin])
        return results.filter { result in
            // Language metadata can span both prose and TeX without changing it.
            if result.resultType == .orthography { return true }
            // Native results count from the checked range's start. Rebase only the comparison and return the original results for AppKit to apply.
            let found = NSRange(location: range.location + result.range.location, length: result.range.length)
            return !code.contains { NSIntersectionRange($0, found).length > 0 }
        }
    }

    /// The highlighter also colours words inside \text{…} as maths, while the core keeps those as prose, so spelling leaves the maths kinds out of `kinds`.
    private func code(in range: NSRange, kinds: Set<HighlightKind>) -> [NSRange] {
        let document = textView.document
        return document.highlights(in: range).filter { kinds.contains($0.kind) }.map(\.range) + document.notProse(in: range)
    }

    func textView(_ view: NSTextView, writingToolsIgnoredRangesInEnclosingRange range: NSRange) -> [NSValue] {
        code(in: range, kinds: [.command, .argument, .mathDelimiter, .mathIdentifier, .number, .comment, .invalid, .stringLiteral, .builtin])
            .map(NSValue.init(range:))
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
        var own: [NSMenuItem] = []
        if textView.forwardSync(false) != nil {
            own.append(NSMenuItem(title: MenuCommand.syncForward.title, action: #selector(goToPDF), keyEquivalent: ""))
        }
        if textView.isEditable {
            own.append(NSMenuItem(title: MenuCommand.editComment.title, action: #selector(toggleComment), keyEquivalent: ""))
        }
        own.forEach { $0.target = self }
        for item in (own + [.separator()]).reversed() { menu.insertItem(item, at: 0) }
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
    func perform(_ command: EditorCommand, _ argument: String? = nil, title: String? = nil) -> Bool {
        guard path != nil, textView.isEditable else { return false }
        let document = textView.document, selection = textView.selectedRange()
        let inserting = title.map { String(localized: "Insert \($0)") } ?? String(localized: "Insert")
        let insert = { (insertion: Insertion?, name: String) in
            guard let insertion else { return false }
            self.textView.apply([insertion.edit], named: name, select: NSRange(location: insertion.caret, length: 0))
            self.textView.startSnippet(insertion.fields, at: insertion.edit.start)
            return true
        }
        switch command {
        case .bold: toggle(\.bold, "\\textbf{", named: String(localized: "Bold"))
        case .italic: toggle(\.italic, "\\textit{", named: String(localized: "Italic"))
        case .underline: toggle(\.underline, "\\underline{", named: String(localized: "Underline"))
        case .math: wrap("$", "$", named: String(localized: "Inline Math"))
        case .displayMath: wrap("\\[", "\\]", named: String(localized: "Display Math"))
        case .inline:
            // A template such as \ref{$0}: "$0" is where the selection goes.
            let parts = ((argument ?? "") + "$0").components(separatedBy: "$0")
            wrap(parts[0], parts[1...].dropLast().joined(separator: "$0"), named: inserting)
            // Empty braces: the labels or citations for them, once the menu has closed.
            if selection.length == 0 { Task { self.textView.complete(nil) } }
        case .comment:
            textView.apply(document.toggleComment(textView.selectedRanges.map(\.rangeValue)), named: String(localized: "Comment"))
        case .moveLineUp, .moveLineDown:
            guard moveLines(up: command == .moveLineUp) else { return false }
        case .heading:
            guard insert(document.setHeading(caret: selection.location, command: argument ?? ""), String(localized: "Section Level")) else { return false }
        case .symbol:
            guard insert(document.insertSymbol(argument ?? "", replacing: selection), String(localized: "Insert Symbol")) else { return false }
        case .block:
            guard insert(document.insertBlock(argument ?? "", replacing: selection), inserting) else { return false }
        }
        focus()
        return true
    }

    private func moveLines(up: Bool) -> Bool {
        let text = textView.text, length = text.length
        let selections = textView.selectedRanges.map(\.rangeValue)
        // Each selection's whole lines; one ending at a line's start doesn't take that line.
        var runs: [NSRange] = []
        for selection in selections {
            let run = text.lineRange(for: selection)
            if let previous = runs.last, run.location <= NSMaxRange(previous) {
                runs[runs.count - 1] = NSUnionRange(previous, run)
            } else {
                runs.append(run)
            }
        }
        var edits: [TextEdit] = [], shifts: [(run: NSRange, by: Int)] = []
        for run in runs.sorted(by: { $0.location < $1.location }) {
            // The empty line after a final line break has nothing to move.
            guard run.length > 0, up ? run.location > 0 : NSMaxRange(run) < length else { return false }
            let neighbour = text.lineRange(for: NSRange(location: up ? run.location - 1 : NSMaxRange(run), length: 0))
            let whole = NSUnionRange(run, neighbour)
            // The lines' text trades places; the line ends stay where they were, so a last line without one keeps none.
            var lines: [(text: String, end: String)] = []
            text.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, line, withEnd, _ in
                let end = NSRange(location: NSMaxRange(line), length: NSMaxRange(withEnd) - NSMaxRange(line))
                lines.append((text.substring(with: line), text.substring(with: end)))
            }
            let moved = up ? Array(lines.dropFirst() + lines.prefix(1)) : Array(lines.suffix(1) + lines.dropLast())
            edits.append(TextEdit(whole, zip(moved, lines).map { $0.text + $1.end }.joined()))
            let newStart = up ? whole.location : whole.location + (moved[0].text + lines[0].end).utf16.count
            shifts.append((run, newStart - run.location))
        }
        textView.apply(edits, named: up ? String(localized: "Move Line Up") : String(localized: "Move Line Down"))
        textView.setSelectedRanges(selections.map { selection in
            let by = shifts.first { NSLocationInRange(selection.location, $0.run) || selection.location == NSMaxRange($0.run) && selection.length == 0 && NSMaxRange($0.run) == length }?.by ?? 0
            return NSValue(range: NSRange(location: selection.location + by, length: selection.length))
        }, affinity: .downstream, stillSelecting: false)
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    var textStyles: TextStyles {
        path == nil ? TextStyles() : textView.document.textStyles(textView.selectedRange())
    }

    private func toggle(_ style: KeyPath<TextStyles, [TextEdit]?>, _ command: String, named name: String) {
        if let unwrap = textStyles[keyPath: style] {
            textView.apply(unwrap, named: name)
        } else {
            wrap(command, "}", named: name)
        }
    }

    private func wrap(_ prefix: String, _ suffix: String, named name: String) {
        let selection = textView.selectedRange()
        let selected = textView.text.substring(with: selection)
        let edit = TextEdit(selection, prefix + selected + suffix)
        textView.apply([edit], named: name,
                       select: NSRange(location: selection.location + (prefix as NSString).length, length: selection.length))
    }
}

struct EditorView: NSViewRepresentable {
    let editor: SourceEditor
    let shown: Bool
    let fontName: String
    let fontSize: Int
    let lineNumbers: Bool
    let syntaxTheme: SyntaxTheme

    func makeNSView(context: Context) -> NSScrollView { editor.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        // A new size only: setting one builds the font to compare.
        if editor.textView.fontSize != CGFloat(fontSize) { editor.textView.fontSize = CGFloat(fontSize) }
        editor.textView.fontName = fontName
        editor.textView.showsLineNumbers = lineNumbers
        editor.textView.syntaxTheme = syntaxTheme
        if editor.shown != shown { editor.shown = shown }
    }
}

enum EditorCommand {
    case bold, italic, underline, math, displayMath, comment, heading, symbol, moveLineUp, moveLineDown
    case block
    case inline
}

enum EditorPrefs {
    static let fontSizeKey = "editorFontSize", spellCheckKey = "editorSpellCheck", syntaxThemeKey = "editorSyntaxTheme"
    static let fontSize = Int(NSFont.systemFontSize)
    static let fontSizes = 10...28

    static func stepFontSize(by step: Int) {
        let current = UserDefaults.standard.object(forKey: fontSizeKey) as? Int ?? fontSize
        UserDefaults.standard.set(min(max(current + step, fontSizes.lowerBound), fontSizes.upperBound), forKey: fontSizeKey)
    }
    static let fontNameKey = "editorFontName", lineNumbersKey = "editorLineNumbers"
    static let autoPairKey = "editorAutoPair", autoCompleteKey = "editorAutoComplete"

    static var autoPair: Bool { UserDefaults.standard.object(forKey: autoPairKey) as? Bool ?? true }
    static var autoComplete: Bool { UserDefaults.standard.object(forKey: autoCompleteKey) as? Bool ?? true }

    static var spellCheck: Bool {
        get { UserDefaults.standard.object(forKey: spellCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: spellCheckKey) }
    }
}

@Observable final class EditorChanges {
    var count = 0
}
