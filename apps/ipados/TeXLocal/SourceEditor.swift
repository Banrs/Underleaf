import SwiftUI
import UIKit

/// A placeholder over UIKit's text view until the source editor's port lands: it keeps the session's document in step and
/// answers what the shared models ask of it.
final class SourceEditor: NSObject, UITextViewDelegate {
    let textView = SourceTextView(usingTextLayoutManager: true)
    var onCursor: (Int, Int) -> Void = { _, _ in }
    var onScroll: (Int) -> Void = { _ in }
    var command: (MenuCommand) -> Void = { _ in }
    private(set) var path: String?
    let changes = EditorChanges()

    override init() {
        super.init()
        textView.delegate = self
        textView.font = .monospacedSystemFont(ofSize: CGFloat(EditorPrefs.fontSize), weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textStorage.delegate = textView
    }

    func open(path: String, text: String, source: SourceDocument? = nil, focus: Bool) {
        self.path = path
        textView.load(text, source: source)
        if focus { self.focus() }
    }

    func reload(text: String) { textView.reload(text) }
    func forget(path: String) {}
    func rename(from: String, to: String) { path = path.map { remapPath($0, from: from, to: to) } }
    /// Once in a window: a text view out of one that takes the keyboard is moved into it with the keyboard animating.
    func focus() { if textView.window != nil { textView.becomeFirstResponder() } }

    var caret: Int { textView.selectedRange.location }
    var currentLine: Int { textView.document.line(at: caret) }
    var currentColumn: Int { caret - textView.document.lineStart(currentLine) }

    func reveal(line: Int, column: Int? = nil, length: Int? = nil, atTop: Bool = false, focus: Bool = true) {
        let start = textView.document.lineStart(line) + (column ?? 0)
        textView.selectedRange = NSRange(location: min(start, (textView.text as NSString).length), length: length ?? 0)
        textView.scrollRangeToVisible(textView.selectedRange)
        if focus { self.focus() }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        changes.count += 1
        onCursor(currentLine, currentColumn)
    }

    func jumpToDefinition() {
        if let place = textView.document.definition(at: caret)?.places.first { textView.openDefinition(place) }
    }

    var renamable: Definition? {
        _ = changes.count
        guard let found = textView.document.definition(at: caret), ["label", "citation"].contains(found.kind) else { return nil }
        return found
    }

    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        guard path != nil, textView.isEditable else { return false }
        let document = textView.document, selection = textView.selectedRange
        switch command {
        case .bold: textView.apply(document.toggle(.bold, [selection]), named: String(localized: "Bold"))
        case .italic: textView.apply(document.toggle(.italic, [selection]), named: String(localized: "Italic"))
        case .underline: textView.apply(document.toggle(.underline, [selection]), named: String(localized: "Underline"))
        case .math: textView.apply(document.wrap([selection], in: "$$0$"), named: String(localized: "Inline Math"))
        case .displayMath: textView.apply(document.wrap([selection], in: "\\[$0\\]"), named: String(localized: "Display Math"))
        case .inline(let template, _): textView.apply(document.wrap([selection], in: template), named: String(localized: "Insert"))
        case .comment: textView.apply(document.toggleComment([selection]), named: String(localized: "Comment"))
        case .moveLineUp, .moveLineDown:
            textView.apply(document.moveLines([selection], up: command == .moveLineUp), named: String(localized: "Move Line"))
        case .heading(let command): textView.insert(document.setHeading(caret: selection.location, command: command))
        case .symbol(let command): textView.insert(document.insertSymbol(command, replacing: selection))
        case .block(let id, _): textView.insert(document.insertBlock(id, replacing: selection))
        }
        return true
    }

    var textStyles: TextStyles { path == nil ? TextStyles() : textView.document.textStyles(textView.selectedRange) }
}

final class SourceTextView: UITextView, NSTextStorageDelegate {
    enum FileDrop { case open(() -> Void), insert(String) }

    struct Issues {
        var lines: [Int: IssuesEvent.Line] = [:]
        var live: [Int: IssuesEvent.Line] = [:]
    }

    private(set) var document = SourceDocument(text: "")
    var issues = Issues()
    var fileDrop: (URL) -> FileDrop? = { _ in nil }
    var forwardSync: (_ quietly: Bool) -> (() -> Void)? = { _ in nil }
    var openDefinition: (Definition.Place) -> Void = { _ in }
    var composing: (Bool) -> Void = { _ in }
    var keyboardChanged: (Bool) -> Void = { _ in }
    var issueClicked: (Int) -> Void = { _ in }
    var headings: () -> [(line: Int, title: String)] = { [] }
    private var loading = false

    func load(_ text: String, source: SourceDocument?) {
        document = source ?? SourceDocument(text: text)
        show(text)
    }

    func reload(_ text: String) {
        document.reload(text)
        show(text)
    }

    private func show(_ text: String) {
        loading = true
        self.text = text
        loading = false
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !loading else { return }
        _ = document.edit(NSRange(location: edited.location, length: edited.length - delta),
                          with: textStorage.mutableString.substring(with: edited), changing: nil, mirroring: false)
    }

    @discardableResult
    func apply(_ change: Change?, named name: String) -> Bool {
        apply(change?.edits ?? [], named: name, selecting: change?.selections.first?.range)
    }

    @discardableResult
    func apply(_ edits: [TextEdit], named name: String, selecting: NSRange? = nil) -> Bool {
        guard !edits.isEmpty else { return false }
        for edit in edits.reversed() { textStorage.replaceCharacters(in: edit.range, with: edit.text) }
        if let selecting { selectedRange = selecting }
        return true
    }

    func insert(_ insertion: Insertion?) {
        guard let insertion else { return }
        apply([insertion.edit], named: "")
    }

    func shiftLines(_ step: Int) {
        apply(document.tab([selectedRange], step: step).edits, named: String(localized: "Shift"))
    }
}

struct EditorView: UIViewRepresentable {
    let editor: SourceEditor
    let shown: Bool

    func makeUIView(context: Context) -> SourceTextView { editor.textView }
    func updateUIView(_ view: SourceTextView, context: Context) { view.isHidden = !shown }
}
