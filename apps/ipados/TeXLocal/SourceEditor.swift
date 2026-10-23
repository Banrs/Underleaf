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

    var path: String?
    /// Their state and scroll come back only if their text is unchanged since, as Xcode's do.
    var kept: [String: (text: String, undo: UndoManager, selection: NSRange, top: (offset: Int, below: CGFloat)?)] = [:]

    /// Hidden, it is out of the focus loop; shown, it takes the focus a file's open asked for.
    var shown = false {
        didSet {
            container.isHidden = !shown
            if shown, !oldValue, focusWhenShown { focus() }
        }
    }
    var focusWhenShown = false

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

    /// What it found is marked, as no selection shows without the keyboard.
    func reveal(line: Int, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let (selection, found) = revealed(line: line, column: column, length: length)
        textView.selectedRange = selection
        atTop ? textView.scroll(toTop: textView.document.lineStart(line)) : textView.centerSelection()
        if focus { self.focus() }
        if found.length > 0, column != nil { textView.mark(found, found: true) }
    }

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
