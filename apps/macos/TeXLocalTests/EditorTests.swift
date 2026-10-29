import AppKit
import Testing
@testable import TeXLocal

struct EditorTests {
    @Test func highlightsMapToTheAppsKinds() {
        let document = SourceDocument(text: "\\emph{a} $x$ % note")
        let kinds = Set(document.highlights(in: NSRange(location: 0, length: 19)).map(\.kind))
        #expect(kinds == [.command, .maths, .comment])
    }

    @Test func theCoresAnswersDecode() throws {
        let document = SourceDocument(text: "\\section{Intro}\nSome $x^2$ text\n\\sec")
        let completions = try #require(document.completions(caret: 36, explicit: false))
        #expect(completions.items.contains { $0.label == "\\section" })
        let heading = try #require(document.setHeading(caret: 3, command: "subsection"))
        #expect(heading.edit.text == "\\subsection{Intro}")
        #expect(document.mathAt(caret: 22) == MathPreview(start: 21, tex: "x^2", display: false))
        #expect(document.folds() == [Fold(line: 1, end: 3)])
        #expect(document.toggleComment([NSRange(location: 0, length: 0)]).first?.text == "% ")
        #expect(document.words(in: NSRange(location: 16, length: 15)) == 2)
    }

    @Test func textStylesSayHowToTakeAStyleOff() {
        let document = SourceDocument(text: "\\textbf{bold} word")
        let styles = document.textStyles(NSRange(location: 9, length: 2))
        #expect(styles.bold?.isEmpty == false)
        #expect(styles.italic == nil)
    }

    @Test func editsChangeTheText() {
        let document = SourceDocument(text: "one\ntwo")
        _ = document.edit(NSRange(location: 4, length: 3), with: "2", changing: nil, mirroring: false)
        #expect(document.text == "one\n2")
        #expect(document.lineCount == 2)
        #expect(document.line(at: 4) == 2)
        #expect(document.version == nil)
    }

    @Test func aRefusedCallReloadsTheCoresCopyFromTheEditorsTextAndANullAnswerDoesNot() {
        let document = SourceDocument(text: "stale")
        document.shown = { "shown" }
        #expect(document.mathAt(caret: 2) == nil && document.definition(at: 2) == nil)
        #expect(document.text == "stale")
        #expect(document.mathAt(caret: -1) == nil)
        #expect(document.text == "shown")
    }

    @Test func aCompletionReplacesWhatWasTypedFillsItsFieldAndUndoesBackToIt() throws {
        let (editor, window) = Self.editor("")
        defer { window.close() }
        let text = editor.textView, undo = text.undo
        Self.type(["\\", "s", "e", "c"], in: text)
        let offered = try #require(text.completions.offered)
        text.completions.move(try #require(offered.items.firstIndex { $0.label == "\\section" }))
        Self.event(text) { text.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        #expect(text.completions.offered == nil)
        #expect(text.string == "\\section{}" && text.selection == .caret(9))
        #expect(undo.undoActionName == "Completion")
        undo.undo()
        #expect(text.string == "\\sec" && text.selection == .caret(4))
        undo.redo()
        #expect(text.string == "\\section{}")
        while undo.canUndo { undo.undo() }
        #expect(text.string == "" && text.document.text == "")
    }

    @Test func typingInACompletedEnvironmentsNameMirrorsItsEndAndUndoesKeyByKey() {
        let (editor, window) = Self.editor("")
        defer { window.close() }
        let text = editor.textView, undo = text.undo
        Self.type(["\\", "b", "e", "g", "i", "n"], in: text)
        Self.event(text) { text.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        #expect(text.string == "\\begin{env}\n  \n\\end{env}" && text.selection == NSRange(location: 7, length: 3))
        Self.type(["l", "i", "s", "t"], in: text)
        #expect(text.string == "\\begin{list}\n  \n\\end{list}" && text.document.text == text.string)
        undo.undo()
        #expect(text.string == "\\begin{lis}\n  \n\\end{lis}")
        for _ in 1...3 { undo.undo() }
        #expect(text.string == "\\begin{env}\n  \n\\end{env}")
        undo.undo()
        #expect(text.string == "\\begin" && text.document.text == "\\begin")
    }

    @Test func foldingHidesALinesBodyTheCaretStepsOverItAndAnEditInsideOpensIt() async throws {
        let (editor, window) = Self.editor("\\begin{itemize}\n\\item a\n\\item b\n\\end{itemize}\nafter")
        defer { window.close() }
        let text = editor.textView
        text.selection = .caret(20)
        text.foldAtCaret()
        #expect(text.folded == [NSRange(location: 16, length: 16)])
        #expect(text.selection == .caret(15))
        #expect(Self.paragraphs(text) == ["\\begin{itemize}\n", "\\end{itemize}\n", "after"])
        text.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(text.selection == .caret(32))
        #expect(text.folded.count == 1)
        text.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(text.selection == .caret(15))
        #expect(text.folded.count == 1)
        text.apply([TextEdit(.caret(20), "x")], named: "Edit", selecting: [.caret(0)])
        #expect(text.folded.isEmpty)
        try await waitUntil { Self.paragraphs(text).count == 5 }
        text.foldAll()
        #expect(text.folded.count == 1)
        text.unfoldAll()
        #expect(text.folded.isEmpty)
    }

    @Test func markedTextIsComposedInTheCoresCopyAndOffersNoCompletionsUntilItIsCommitted() {
        let (editor, window) = Self.editor("")
        defer { window.close() }
        let text = editor.textView
        var composing: [Bool] = []
        text.composing = { composing.append($0) }
        Self.type(["\\", "s"], in: text)
        #expect(text.completions.offered != nil)
        Self.event(text) { text.setMarkedText("e", selectedRange: .caret(1), replacementRange: Self.typed) }
        #expect(text.hasMarkedText() && composing == [true])
        #expect(text.completions.offered == nil && text.document.text == "\\se")
        Self.type(["é"], in: text)
        #expect(!text.hasMarkedText() && composing == [true, false])
        #expect(text.string == "\\sé" && text.document.text == "\\sé")
    }

    @Test func scrollingReportsTheTopLine() throws {
        let (editor, window) = Self.editor((1...200).map { "line \($0)" }.joined(separator: "\n"))
        defer { window.close() }
        let text = editor.textView
        window.displayIfNeeded()
        var tops: [Int] = []
        editor.onScroll = { tops.append($0) }
        text.laidOut = {}
        let fourth = try #require(text.fragments.first { text.document.line(at: $0.offset) == 4 })
        text.scroll(NSPoint(x: 0, y: fourth.fragment.layoutFragmentFrame.minY + text.textContainerOrigin.y))
        #expect(tops == [4])
    }

    private static let typed = NSRange(location: NSNotFound, length: 0)

    private static func event(_ text: SourceTextView, _ body: () -> Void) {
        text.undo.beginUndoGrouping()
        body()
        text.undo.endUndoGrouping()
    }

    private static func type(_ keys: [String], in text: SourceTextView) {
        for key in keys { event(text) { text.insertText(key, replacementRange: typed) } }
    }

    private static func editor(_ source: String) -> (SourceEditor, NSWindow) {
        let editor = SourceEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.open(path: "main.tex", source: SourceDocument(text: source))
        editor.textView.undo.groupsByEvent = false
        editor.shown = true
        window.makeFirstResponder(editor.textView)
        return (editor, window)
    }

    private static func paragraphs(_ text: SourceTextView) -> [String] {
        guard let content = text.textLayoutManager?.textContentManager else { return [] }
        var found: [String] = []
        content.enumerateTextElements(from: content.documentRange.location) { element in
            found.append((element as? NSTextParagraph)?.attributedString.string ?? "")
            return true
        }
        return found
    }
}
