import AppKit
import Testing
@testable import TeXLocal

struct EditorTests {
    @Test func highlightsMapToTheAppsKinds() {
        let document = SourceDocument(text: "}1 \\x $y$ % z")
        let runs = document.highlights(in: NSRange(location: 0, length: 14))
        let kinds = Dictionary(uniqueKeysWithValues: runs.map { ($0.range.location, $0.kind) })
        #expect([0, 1, 3, 7, 10].map { kinds[$0] } == [.invalid, .argument, .command, .maths, .comment])
    }

    @Test func theCoresAnswersDecode() throws {
        let document = SourceDocument(text: "\\section{Intro}\nSome $x^2$ text\n\\sec")
        let completions = try #require(document.complete(caret: 36, explicit: false))
        #expect(completions.items.contains { $0.label == "\\section" })
        let heading = try #require(document.setHeading(caret: 3, command: "subsection"))
        #expect(heading.edit.text == "\\subsection{Intro}")
        #expect(document.mathAt(caret: 22) == MathPreview(start: 21, tex: "x^2", display: false))
        #expect(document.folds() == [Fold(line: 1, end: 3)])
        #expect(document.toggleComment([NSRange(location: 0, length: 0)]).first?.text == "% ")
        #expect(document.words(in: NSRange(location: 16, length: 15)) == 2)
        #expect(document.selectsCommand(NSRange(location: 1, length: 7)) && !document.selectsCommand(NSRange(location: 9, length: 5)))
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

    @Test func foldsMoveWithEditsBeforeThemOpenOnEditsInsideAndStepTheCaretOverThemBothWays() {
        let document = SourceDocument(text: "\\begin{itemize}\n\\item a\n\\item b\n\\end{itemize}\nafter")
        let fold = Fold(line: 1, end: 3).hidden(in: document, length: 51)
        #expect(fold == NSRange(location: 16, length: 16) && Fold(line: 4, end: 5).hidden(in: document, length: 51) == NSRange(location: 46, length: 5))
        let folds = FoldSet([fold, fold])
        #expect(folds.ranges == [fold] && folds.headers(in: document) == [1: fold] && folds.hides(16) && !folds.hides(32))
        #expect(folds.caret(on: 1, hiding: .caret(20), in: document) == .caret(15))
        #expect(folds.caret(on: 1, hiding: .caret(40), in: document) == nil)
        let edits: [(NSRange, Int, NSRange?)] = [(.caret(2), 1, NSRange(location: 17, length: 16)), (NSRange(location: 33, length: 2), -2, fold),
                                                 (.caret(32), 1, fold), (.caret(20), 1, nil), (NSRange(location: 15, length: 1), -1, nil)]
        for (old, delta, kept) in edits {
            var edited = folds
            #expect(edited.edited(old, delta: delta) == (kept == nil) && edited.ranges == (kept.map { [$0] } ?? []))
        }
        var stepped = folds
        #expect(stepped.moved(from: .caret(15), to: .caret(16), stepping: true) == .caret(32))
        #expect(stepped.moved(from: .caret(32), to: .caret(31), stepping: true) == .caret(15) && stepped == folds)
        #expect(stepped.moved(from: .caret(15), to: .caret(20), stepping: false) == nil && stepped.isEmpty)
    }

    @Test func theEditSyncHoldsAMirrorWhileTheNameIsComposedAndTheMirrorsEchoAsksForNoMore() {
        let document = SourceDocument(text: "\\begin{x}\n\\end{x}")
        let text = NSMutableString(string: document.text)
        var sync = EditSync()
        document.select(.caret(8), mirroring: false)
        sync.willChange([.caret(8)], to: ["é"])
        text.insert("é", at: 8)
        #expect(sync.edited(NSRange(location: 8, length: 1), delta: 1, in: text, of: document) == .caret(8))
        #expect(sync.mirror(composing: true).isEmpty)
        #expect(sync.mirror(composing: false) == [TextEdit(start: 16, length: 1, text: "xé")])
        sync.mirroring = true
        text.replaceCharacters(in: NSRange(location: 16, length: 1), with: "xé")
        _ = sync.edited(NSRange(location: 16, length: 2), delta: 1, in: text, of: document)
        sync.mirroring = false
        #expect(sync.mirror(composing: false).isEmpty && document.text == text as String)
    }

    @Test func offsetsAndRangesConvertThroughTheTextContent() throws {
        let content = NSTextContentStorage()
        content.attributedString = NSAttributedString(string: "ab\ncdé")
        let range = try #require(content.textRange(of: NSRange(location: 1, length: 4)))
        #expect(content.offset(of: range.location) == 1 && content.offset(of: range.endLocation) == 5)
        #expect(content.textRange(of: NSRange(location: 7, length: 0)) == nil)
    }

    @Test func aCompletionReplacesWhatWasTypedFillsItsFieldAndUndoesBackToIt() throws {
        let (editor, window) = Self.editor("")
        defer { window.close() }
        let text = editor.textView, undo = text.undo
        Self.type("\\sec", in: text)
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
        Self.type("\\begin", in: text)
        Self.event(text) { text.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        #expect(text.string == "\\begin{env}\n  \n\\end{env}" && text.selection == NSRange(location: 7, length: 3))
        Self.type("list", in: text)
        #expect(text.string == "\\begin{list}\n  \n\\end{list}" && text.document.text == text.string)
        undo.undo()
        #expect(text.string == "\\begin{lis}\n  \n\\end{lis}")
        for _ in 1...3 { undo.undo() }
        #expect(text.string == "\\begin{env}\n  \n\\end{env}")
        undo.undo()
        #expect(text.string == "\\begin" && text.document.text == "\\begin")
    }

    @Test func typingInAnEndsNameMirrorsItsBeginAndKeepsTheCaretAfterTheTypedLetters() {
        let (editor, window) = Self.editor("\\begin{x}\n\\end{x}")
        defer { window.close() }
        let text = editor.textView
        text.selection = .caret(16)
        Self.type("ab", in: text)
        #expect(text.string == "\\begin{xab}\n\\end{xab}" && text.document.text == text.string)
        #expect(text.selection == .caret(20))
    }

    @Test func switchingFilesKeepsEachFilesSelectionFoldsAndUndoUnlessItsTextChanged() {
        let (editor, window) = Self.editor("\\begin{itemize}\n\\item a\n\\item b\n\\end{itemize}\nafter")
        defer { window.close() }
        let text = editor.textView, undo = text.undo
        Self.type("x", in: text)
        text.selection = .caret(21)
        text.foldAtCaret()
        let (main, folded, selection) = (text.string, text.folds.ranges, text.selection)
        #expect(folded == [NSRange(location: 17, length: 16)] && selection == .caret(16))
        editor.open(path: "other.tex", source: SourceDocument(text: "other"))
        let other = text.undo
        #expect(other !== undo && text.folds.isEmpty)
        text.selection = .caret(3)
        editor.open(path: "main.tex", source: SourceDocument(text: main))
        #expect(text.undo === undo && text.folds.ranges == folded && text.selection == selection)
        editor.open(path: "other.tex", source: SourceDocument(text: "changed"))
        #expect(text.undo !== other && text.selection == .caret(0))
    }

    @Test func foldingHidesALinesBodyTheCaretStepsOverItAndAnEditInsideOpensIt() async throws {
        let (editor, window) = Self.editor("\\begin{itemize}\n\\item a\n\\item b\n\\end{itemize}\nafter")
        defer { window.close() }
        let text = editor.textView
        text.selection = .caret(20)
        text.foldAtCaret()
        #expect(text.folds.ranges == [NSRange(location: 16, length: 16)])
        #expect(text.selection == .caret(15))
        #expect(Self.paragraphs(text) == ["\\begin{itemize}\n", "\\end{itemize}\n", "after"])
        text.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(text.selection == .caret(32))
        #expect(text.folds.ranges.count == 1)
        text.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(text.selection == .caret(15))
        #expect(text.folds.ranges.count == 1)
        text.apply([TextEdit(.caret(20), "x")], named: "Edit", selecting: [.caret(0)])
        #expect(text.folds.isEmpty)
        try await waitUntil { Self.paragraphs(text).count == 5 }
        text.foldAll()
        #expect(text.folds.ranges.count == 1)
        text.unfoldAll()
        #expect(text.folds.isEmpty)
    }

    @Test func markedTextIsComposedInTheCoresCopyAndOffersNoCompletionsUntilItIsCommitted() {
        let (editor, window) = Self.editor("")
        defer { window.close() }
        let text = editor.textView
        var composing: [Bool] = []
        text.composing = { composing.append($0) }
        Self.type("\\s", in: text)
        #expect(text.completions.offered != nil)
        Self.event(text) { text.setMarkedText("e", selectedRange: .caret(1), replacementRange: Self.typed) }
        #expect(text.hasMarkedText() && composing == [true])
        #expect(text.completions.offered == nil && text.document.text == "\\se")
        Self.type("é", in: text)
        #expect(!text.hasMarkedText() && composing == [true, false])
        #expect(text.string == "\\sé" && text.document.text == "\\sé")
    }

    @Test(arguments: [(8, 9), (16, 18)], [false, true])
    func composingInAnEnvironmentsNameMirrorsItOnceTheCompositionCommits(_ place: (caret: Int, after: Int), _ unmarking: Bool) {
        let (editor, window) = Self.editor("\\begin{x}\n\\end{x}")
        defer { window.close() }
        let text = editor.textView
        text.selection = .caret(place.caret)
        Self.event(text) { text.setMarkedText(unmarking ? "é" : "´", selectedRange: .caret(1), replacementRange: Self.typed) }
        #expect(text.markedRange() == NSRange(location: place.caret, length: 1) && text.document.text == text.string)
        if unmarking { Self.event(text) { text.unmarkText() } } else { Self.type("é", in: text) }
        #expect(!text.hasMarkedText() && text.string == "\\begin{xé}\n\\end{xé}" && text.document.text == text.string)
        #expect(text.selection == .caret(place.after))
    }

    @Test func aReplaceAllsCoalescedEditKeepsTheCoresCopyEqualToTheShownTextThroughUndo() {
        let (editor, window) = Self.editor("a b a b")
        defer { window.close() }
        let text = editor.textView
        let found = [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)]
        Self.event(text) {
            guard text.shouldChangeText(inRanges: found.map(NSValue.init(range:)), replacementStrings: ["xy", "xy"]) else { return }
            text.textStorage?.beginEditing()
            for range in found.reversed() { text.textStorage?.replaceCharacters(in: range, with: "xy") }
            text.textStorage?.endEditing()
            text.didChangeText()
        }
        #expect(text.string == "xy b xy b" && text.document.text == text.string)
        text.undo.undo()
        #expect(text.string == "a b a b" && text.document.text == text.string)
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

    private static func type(_ keys: String, in text: SourceTextView) {
        for key in keys { event(text) { text.insertText(String(key), replacementRange: typed) } }
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
