import AppKit
import SwiftUI

final class SourceEditor: NSObject, NSTextViewDelegate {
    let textView = SourceTextView.plainDocument()
    let scrollView = ScrollView()
    var onCursor: (Int, Int, Int) -> Void = { _, _, _ in }
    var onScroll: (Int) -> Void = { _ in }
    var onChange: () -> Void = {}

    var path: String?
    var kept: [String: Kept] = [:]

    struct Kept {
        let text: String
        let undo: UndoManager
        let selection: NSRange
        let top: (offset: Int, below: CGFloat)?
        let folds: FoldSet
    }

    var shown = false {
        didSet {
            textView.isHidden = !shown
            if shown, !oldValue, focusWhenShown { focus() }
        }
    }
    var focusWhenShown = false

    final class ScrollView: NSScrollView {
        var scrolled: () -> Void = {}
        private var viewportHeight: CGFloat = 0

        override func reflectScrolledClipView(_ clip: NSClipView) {
            super.reflectScrolledClipView(clip)
            let grew = clip.bounds.height > viewportHeight
            viewportHeight = clip.bounds.height
            if grew, let text = documentView as? SourceTextView, !text.isHidden {
                // Lay out the lines being revealed as the viewport grows, including during a split resize.
                text.textLayoutManager?.textViewportLayoutController.layoutViewport()
            }
            scrolled()
        }
    }

    override init() {
        super.init()
        let text = textView
        text.usesFontPanel = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        // Xcode 27.2’s first text row starts 8 pt below the editor’s top edge on Retina.
        text.textContainerInset.height = 8
        text.allowsUndo = true
        text.isGrammarCheckingEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
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
        scrollView.layerContentsRedrawPolicy = .duringViewResize
        scrollView.documentView = text
        scrollView.scrolled = { [weak self] in
            self?.textView.scrolled()
            self?.reportTop()
        }
        text.laidOut = { [weak self] in self?.reportTop() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { textView.undo }

    func reveal(line: Int, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let (selection, found) = revealed(line: line, column: column, length: length)
        textView.setSelectedRange(selection)
        atTop ? textView.scroll(toTop: textView.document.lineStart(line)) : textView.centerSelectionInVisibleArea(nil)
        if focus { self.focus() }
        if found.length > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Task { [textView] in if textView.window?.isVisible == true { textView.showFindIndicator(for: found) } }
        }
    }

    func textDidChange(_ notification: Notification) {
        onChange()
    }

    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        let code = textView.document.codeRanges(in: range, for: .spelling)
        return results.filter { result in
            let found = NSRange(location: range.location + result.range.location, length: result.range.length)
            return result.resultType == .orthography || !code.contains { NSIntersectionRange($0, found).length > 0 }
        }
    }

    func textView(_ view: NSTextView, writingToolsIgnoredRangesInEnclosingRange range: NSRange) -> [NSValue] {
        textView.document.codeRanges(in: range, for: .writingTools).map(NSValue.init(range:))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onChange()
        guard !textView.loading else { return }
        reportCursor()
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let unwanted = [#selector(NSTextView.changeLayoutOrientation(_:)), #selector(NSTextView.startSpeaking(_:)),
                        #selector(NSResponder.uppercaseWord(_:))]
        let offered: [(MenuCommand, Bool)] = [
            (.jumpToDefinition, true), (.findUsages, true), (.editRename, textView.isEditable && renamable != nil),
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

    var command: (MenuCommand) -> Void = { _ in }

    @objc private func choose(_ item: NSMenuItem) { (item.representedObject as? MenuCommand).map(command) }
}

extension SourceEditor {
    func jumpToDefinition() {
        guard let place = textView.document.definition(at: textView.selection.location)?.places.first else { return NSSound.beep() }
        textView.openDefinition(place)
    }

    var renamable: SymbolName? {
        guard let found = textView.document.symbol(at: textView.selection.location),
              [.label, .citation].contains(found.kind) else { return nil }
        return found
    }

    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        guard path != nil, textView.isEditable else { return false }
        let document = textView.document, selection = textView.selection, selections = textView.selections
        switch command {
        case .bold: textView.apply(document.toggle(.bold, selections), named: String(localized: "Bold"))
        case .italic: textView.apply(document.toggle(.italic, selections), named: String(localized: "Italic"))
        case .underline: textView.apply(document.toggle(.underline, selections), named: String(localized: "Underline"))
        case .math: textView.apply(document.wrap(selections, in: "$$0$"), named: String(localized: "Inline Math"))
        case .displayMath: textView.apply(document.wrap(selections, in: "\\[$0\\]"), named: String(localized: "Display Math"))
        case .inline(let template, let title):
            textView.apply(document.wrap(selections, in: template), named: Self.insertion(titled: title))
            if selection.length == 0 { Task { self.textView.completions.complete(explicit: true) } }
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
        case .fold: textView.foldAtCaret()
        case .unfold: textView.unfoldAtCaret()
        case .foldAll: textView.foldAll()
        case .unfoldAll: textView.unfoldAll()
        case .heading(let command):
            let level = document.setHeading(caret: selection.location, command: command)
            guard textView.insert(level, named: String(localized: "Section Level")) else { return false }
        case .symbol(let command):
            let symbol = document.insertSymbol(command, replacing: selection)
            guard textView.insert(symbol, named: String(localized: "Insert Symbol")) else { return false }
        case .block(let id, let title):
            let block = document.insertBlock(id, replacing: selection)
            guard textView.insert(block, named: Self.insertion(titled: title)) else { return false }
        case .cite(let key):
            guard textView.insert(document.cite(key, replacing: selection), named: String(localized: "Insert Citation")) else { return false }
        }
        focus()
        return true
    }

    private static func insertion(titled title: String?) -> String {
        title.map { String(localized: "Insert \($0)") } ?? String(localized: "Insert")
    }

    var textStyles: TextStyles { path == nil ? TextStyles() : textView.document.textStyles(textView.selection) }

    func revealed(line: Int, column: Int?, length: Int?) -> (selection: NSRange, found: NSRange) {
        let document = textView.document
        let start = document.lineStart(line)
        let end = line < document.lineCount ? document.lineStart(line + 1) - 1 : textView.length
        let found = column.map { column in
            let at = min(start + column, end)
            return length.map { NSRange(location: at, length: min($0, end - at)) } ?? textView.word(at: at)
        }
        return (found ?? .caret(start), found ?? NSRange(location: start, length: end - start))
    }
}

extension SourceEditor {
    func open(path: String, source: SourceDocument) {
        if let current = self.path {
            kept[current] = Kept(text: textView.source as String, undo: textView.undo, selection: textView.selection, top: textView.shownTop,
                                 folds: textView.folds)
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

    func forget(path: String) { kept = kept.filter { !$0.key.isWithin(path) } }

    func rename(from: String, to: String) {
        forget(path: to)
        kept = Dictionary(uniqueKeysWithValues: kept.map { (remapPath($0.key, from: from, to: to), $0.value) })
        path = path.map { remapPath($0, from: from, to: to) }
    }

    func focus() {
        guard shown else { return }
        focusWhenShown = false
        textView.window?.makeFirstResponder(textView)
    }

    var caret: Int { textView.caret }
    var currentLine: Int { textView.document.line(at: caret) }
    var currentColumn: Int { caret - textView.document.lineStart(currentLine) }
    var shownColumn: Int { textView.source.substring(with: NSRange(location: caret - currentColumn, length: currentColumn)).count + 1 }

    func reportTop() { if let line = textView.topLine { onScroll(line) } }
    func reportCursor() { onCursor(currentLine, currentColumn, shownColumn) }
}
