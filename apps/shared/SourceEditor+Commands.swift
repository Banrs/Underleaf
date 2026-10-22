#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The editor's commands, the core's answers put into each platform's text view the same way.
extension SourceEditor {
    /// At the selection's start. The command is enabled wherever the caret is, so a name nothing defines beeps on the Mac,
    /// which has a beep.
    func jumpToDefinition() {
        guard let place = textView.document.definition(at: textView.selection.location)?.places.first else {
            #if os(macOS)
            NSSound.beep()
            #endif
            return
        }
        textView.openDefinition(place)
    }

    /// The label or citation at the selection's start, which Rename renames everywhere. Read through `changes`, so a menu
    /// showing it follows the caret.
    var renamable: Definition? {
        _ = changes.count
        guard let found = textView.document.definition(at: textView.selection.location),
              ["label", "citation"].contains(found.kind) else { return nil }
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
            // Empty braces: their labels or citations, once the menu has closed.
            if selection.length == 0 { Task { self.textView.completions.complete(explicit: true) } }
        case .comment:
            textView.apply(document.toggleComment(selections), named: String(localized: "Comment"))
        case .moveLineUp, .moveLineDown:
            let up = command == .moveLineUp
            let name = up ? String(localized: "Move Line Up") : String(localized: "Move Line Down")
            guard textView.apply(document.moveLines(selections, up: up), named: name) else { return false }
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

    var textStyles: TextStyles { path == nil ? TextStyles() : textView.document.textStyles(textView.selection) }

    /// What `reveal` selects, the match `length` long at `column`, the word there or the line's start, and what it shows
    /// found: that, or the line.
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
