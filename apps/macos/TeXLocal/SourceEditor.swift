import AppKit
import SwiftUI

final class SourceEditor: NSObject, NSTextViewDelegate {
    let textView = SourceTextView.plainDocument()
    let scrollView = NSScrollView()
    /// The caret's line and column.
    var onCursor: (Int, Int) -> Void = { _, _ in }
    /// The top line.
    var onScroll: (Int) -> Void = { _ in }

    var path: String?
    /// Their state and scroll come back only if their text is unchanged since, as Xcode's do.
    var kept: [String: (text: String, undo: UndoManager, selection: NSRange, top: (offset: Int, below: CGFloat)?, folded: [NSRange])] = [:]

    /// Hidden, it is out of the key view loop; shown, it takes the focus a file's open asked for.
    var shown = false {
        didSet {
            textView.isHidden = !shown
            if shown, !oldValue, focusWhenShown { focus() }
        }
    }
    var focusWhenShown = false

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
        // Smart dashes and quotes, corrections and text replacements would rewrite the LaTeX, and a term in the prose, as
        // Xcode keeps them off; spelling and Writing Tools keep to the prose (below).
        text.isContinuousSpellCheckingEnabled = EditorPrefs.spellCheck
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

    func undoManager(for view: NSTextView) -> UndoManager? { textView.undo }

    /// The find indicator bounces, so not with Reduce Motion, where the selection is the mark.
    func reveal(line: Int, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let (selection, found) = revealed(line: line, column: column, length: length)
        textView.setSelectedRange(selection)
        atTop ? textView.scroll(toTop: textView.document.lineStart(line)) : textView.centerSelectionInVisibleArea(nil)
        if focus { self.focus() }
        // Once the scroll's layout is done, in a window still shown: AppKit's pulse joins the window as a child, and one
        // closed meanwhile is freed under it (`aRevealedLineStaysAtTheTop` could crash the host).
        if found.length > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Task { [textView] in if textView.window?.isVisible == true { textView.showFindIndicator(for: found) } }
        }
    }

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

    /// The context menu's items are the menu bar's commands, which the project performs.
    var command: (MenuCommand) -> Void = { _ in }

    @objc private func choose(_ item: NSMenuItem) { (item.representedObject as? MenuCommand).map(command) }
}
