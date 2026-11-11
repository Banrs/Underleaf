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

    @Test func structureUsesTheXcodeKeywordWeightAndRestylesWhenTheSyntaxContextChanges() async throws {
        let (editor, window) = Self.editor("Start\n\\section{Intro} and \\emph{normal}\n% \\section{Comment}\n")
        defer { window.close() }
        let view = editor.textView
        view.appearance = NSAppearance(named: .aqua)
        view.fontSize = 13
        let manager = try #require(view.textLayoutManager)
        let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let keyword = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        func shownFont(on line: Int, at index: Int = 0) -> NSFont? {
            manager.textViewportLayoutController.layoutViewport()
            guard let location = view.textRange(.caret(view.document.lineStart(line)))?.location,
                  let paragraph = manager.textLayoutFragment(for: location)?.textElement as? NSTextParagraph else { return nil }
            return paragraph.attributedString.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        }
        #expect(shownFont(on: 2) == keyword)
        #expect(shownFont(on: 2, at: 8) == base)
        #expect(shownFont(on: 2, at: 20) == base)
        #expect(shownFont(on: 3, at: 2) == base)
        #expect(view.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont == base)
        let command = "\\section" as NSString
        #expect(command.size(withAttributes: [.font: base]).width == command.size(withAttributes: [.font: keyword]).width)
        #expect(view.apply([TextEdit(NSRange(location: 0, length: 5), "\\begin{verbatim}")], named: "Edit"))
        try await waitUntil(timeout: .seconds(2)) { shownFont(on: 2) == base }
        view.undo.undo()
        try await waitUntil(timeout: .seconds(2)) { shownFont(on: 2) == keyword }
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
        #expect(document.version == 1)
    }

    @Test func aRefusedCallReloadsTheCoresCopyFromTheEditorsTextAndANullAnswerDoesNot() {
        let document = SourceDocument(text: "stale")
        document.shown = { "shown" }
        #expect(document.mathAt(caret: 2) == nil && document.definition(at: 2) == nil)
        #expect(document.text == "stale")
        #expect(document.mathAt(caret: -1) == nil)
        #expect(document.text == "shown")
    }

    @Test func aRejectedInsertionDoesNotStartItsSnippet() throws {
        let (editor, window) = Self.editor("before")
        defer { window.close() }
        let text = editor.textView
        text.selection = .caret(3)
        text.isEditable = false
        let insertion = Insertion(edit: TextEdit(start: 0, length: 0, text: "abc"), caret: 1,
                                  fields: [SnippetField(start: 0, length: 1, index: 0)])

        #expect(!text.insert(insertion, named: "Insert"))
        #expect(text.string == "before" && text.selection == .caret(3))
        #expect(!text.document.endSnippet())
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
        while undo.canRedo { undo.redo() }
        #expect(text.string == "\\begin{list}\n  \n\\end{list}" && text.document.text == text.string)
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

    @Test func aPairTypedInAnEndsNamePutsTheCaretInsideItOnceItsBeginIsMirrored() {
        let (editor, window) = Self.editor("\\begin{x}\n\\end{x}")
        defer { window.close() }
        let text = editor.textView
        text.selection = .caret(16)
        Self.type("(", in: text)
        #expect(text.string == "\\begin{x()}\n\\end{x()}" && text.document.text == text.string)
        #expect(text.selection == .caret(19))
    }

    @Test func acceptingACompletionInAnEndsNameLeavesTheCaretAfterItOnceItsBeginIsMirrored() throws {
        let (editor, window) = Self.editor("\\begin{i}\n\\end{i}")
        defer { window.close() }
        let text = editor.textView
        text.selection = .caret(16)
        Self.type("te", in: text)
        let offered = try #require(text.completions.offered)
        text.completions.move(try #require(offered.items.firstIndex { $0.label == "itemize" }))
        Self.event(text) { text.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        #expect(text.string == "\\begin{itemize}\n\\end{itemize}" && text.document.text == text.string)
        #expect(text.selection == .caret(28))
    }

    @Test func aViewThatCantBeEditedRefusesAnEditAndSaysSo() {
        let (editor, window) = Self.editor("text")
        defer { window.close() }
        let text = editor.textView
        text.isEditable = false
        #expect(!text.apply([TextEdit(.caret(0), "x")], named: "Edit") && text.string == "text")
    }

    @Test func spreadsheetCellsPasteAsATabularOnALineOfTheirOwnAtItsIndentationInOneUndoStep() {
        let (editor, window) = Self.editor("  x\n    ")
        defer { window.close() }
        let text = editor.textView, board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("Name\tScore\r\nAda\t10\r\n", forType: .string)
        text.selection = .caret(3)
        #expect(text.pasteTable(from: board, booktabs: false))
        let table = { (indent: String, rules: [String]) in
            ["\\begin{tabular}{lr}", "  \(rules[0])", "  Name & Score \\\\", "  \(rules[1])", "  Ada & 10 \\\\", "  \(rules[2])", "\\end{tabular}"]
                .joined(separator: "\n" + indent)
        }
        let pasted = "  x\n  " + table("  ", ["\\hline", "\\hline", "\\hline"])
        #expect(text.string == pasted + "\n    " && text.document.text == text.string)
        #expect(text.selection == .caret((pasted as NSString).length) && text.undo.undoActionName == "Paste as Table")
        text.undo.undo()
        #expect(text.string == "  x\n    " && text.document.text == text.string)
        // Text after the caret goes on to a line of its own.
        text.selection = .caret(2)
        #expect(text.pasteTable(from: board, booktabs: false))
        #expect(text.string == "  " + table("  ", ["\\hline", "\\hline", "\\hline"]) + "\n  x\n    ")
        text.undo.undo()
        text.selection = .caret(8)
        #expect(text.pasteTable(from: board, booktabs: true))
        #expect(text.string == "  x\n    " + table("    ", ["\\toprule", "\\midrule", "\\bottomrule"]) && text.document.text == text.string)
        board.clearContents()
        board.setString("one column\nonly", forType: .string)
        #expect(!text.pasteTable(from: board, booktabs: false))
        text.isEditable = false
        #expect(!text.canPasteTable)
    }

    @Test func continuityCamerasImagesComeInAsFiguresThroughTheFigurePath() async throws {
        let (editor, window) = Self.editor("")
        defer { window.close() }
        let text = editor.textView, jpeg = NSPasteboard.PasteboardType("public.jpeg")
        for type in [NSPasteboard.PasteboardType.png, .tiff, .pdf, jpeg] {
            #expect(text.validRequestor(forSendType: nil, returnType: type) as? SourceTextView === text, "\(type)")
        }
        var copied: [(name: String, existed: Bool)] = []
        text.fileDrop = { url in
            .copy {
                copied.append((url.lastPathComponent, FileManager.default.fileExists(atPath: url.path(percentEncoded: false))))
                return "\\includegraphics{\(url.lastPathComponent)}"
            }
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([jpeg], owner: nil)
        board.setData(Data([0xFF, 0xD8, 0xFF, 0xD9]), forType: jpeg)
        #expect(text.readSelection(from: board))
        try await waitUntil { !copied.isEmpty }
        #expect(copied.map(\.name) == ["Pasted Graphic.jpg"] && copied[0].existed)
        #expect(text.string == "\\includegraphics{Pasted Graphic.jpg}" && text.undo.undoActionName == "Insert Figure")
        board.declareTypes([.string, jpeg], owner: nil)
        board.setString("words", forType: .string)
        board.setData(Data([0xFF, 0xD8, 0xFF, 0xD9]), forType: jpeg)
        Self.event(text) { _ = text.readSelection(from: board) }
        #expect(copied.count == 1 && text.string == "words")
        text.isEditable = false
        #expect(text.validRequestor(forSendType: nil, returnType: .png) == nil)
    }

    @Test func theEditorTakesTheFocusARevealAskedForOnlyTheNextTimeItShows() {
        let (editor, window) = Self.editor("text")
        defer { window.close() }
        let showing = {
            editor.shown = false
            window.makeFirstResponder(nil)
            editor.shown = true
            return window.firstResponder === editor.textView
        }
        editor.focusWhenShown = true
        #expect(showing() && !showing())
        editor.focusWhenShown = true
        editor.focus()
        #expect(!showing())
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
        editor.open(path: "glyphs.tex", source: SourceDocument(text: "a\n\t😀😀x"))
        text.selection = .caret(8)
        #expect(editor.currentLine == 2 && editor.currentColumn == 6 && editor.shownColumn == 5)
        let joined = "e\u{301}👨‍👩‍👧x"
        editor.open(path: "joined.tex", source: SourceDocument(text: joined))
        text.selection = .caret((joined as NSString).length)
        #expect(editor.currentLine == 1 && editor.shownColumn == 4)
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

    @Test func theChevronTogglesFoldingInThePaddingBeforeTheSourceText() throws {
        let header = "\\begin{itemize} " + String(repeating: "word ", count: 30)
        let (editor, window) = Self.editor("first\n\(header)\n\\item a\n\\end{itemize}")
        defer { window.close() }
        let text = editor.textView
        text.fontSize = 13
        window.displayIfNeeded()
        let fragment = try #require(text.fragments.first { $0.offset == text.document.lineStart(2) }?.fragment)
        let rows = fragment.textLineFragments
        try #require(rows.count > 1 && rows[0].typographicBounds.minY > 0)
        let origin = text.textContainerOrigin
        let top = origin.y + fragment.layoutFragmentFrame.minY
        let x = origin.x + text.linePadding / 2
        let chevron = NSPoint(x: x, y: top + rows[0].typographicBounds.midY)
        #expect(!text.foldClick(at: NSPoint(x: text.sourceTextStart, y: chevron.y)))
        #expect(!text.foldClick(at: NSPoint(x: x, y: top + rows[0].typographicBounds.minY / 2)))
        #expect(!text.foldClick(at: NSPoint(x: x, y: top + rows[1].typographicBounds.midY)))
        #expect(text.foldClick(at: chevron) && !text.folds.isEmpty)
        #expect(text.foldClick(at: chevron) && text.folds.isEmpty)
    }

    @Test(arguments: ["current", ""])
    func theCurrentLineAlignsWithTheTextKitRow(_ line: String) throws {
        let (editor, window) = Self.editor("first\n\(line)\nlast")
        defer { window.close() }
        let text = editor.textView
        text.fontSize = 13
        text.selection = .caret(text.document.lineStart(2))
        window.displayIfNeeded()
        let caret = text.firstRect(forCharacterRange: text.selection, actualRange: nil)
        let first = text.firstRect(forCharacterRange: .caret(0), actualRange: nil)
        let last = text.firstRect(forCharacterRange: .caret(text.document.lineStart(3)), actualRange: nil)
        #expect(abs(first.minY - caret.minY - 18) < 0.5 && abs(caret.minY - last.minY - 18) < 0.5)
        let row = text.convert(window.convertFromScreen(caret), from: nil)
        let band = try #require(text.currentLine?.rect)
        #expect(band.minY == text.onPixels(row.minY) && band.maxY == text.onPixels(row.maxY))

        let native = NSTextView(usingTextLayoutManager: true)
        native.string = text.string
        native.font = text.font
        window.contentView = native
        window.displayIfNeeded()
        let nativeRow = native.firstRect(forCharacterRange: text.selection, actualRange: nil)
        #expect(nativeRow.height > 0 && abs(row.height - nativeRow.height) < 0.5)
    }

    @Test(arguments: [true, false])
    func gutterClicksKeepTheSelectionAndPaddingClicksPlaceTheCaret(showLineNumbers: Bool) throws {
        let (editor, window) = Self.editor("Plain text")
        defer { window.close() }
        let text = editor.textView
        text.showsLineNumbers = showLineNumbers
        window.displayIfNeeded()
        text.selection = .caret(5)
        let line = try #require(text.fragments.first?.fragment)
        let origin = text.textContainerOrigin
        func click(at x: CGFloat) throws {
            let point = text.convert(NSPoint(x: x, y: origin.y + line.layoutFragmentFrame.midY), to: nil)
            func mouse(_ type: NSEvent.EventType, pressure: Float) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure))
            }
            let down = try mouse(.leftMouseDown, pressure: 1), up = try mouse(.leftMouseUp, pressure: 0)
            window.postEvent(up, atStart: true)
            text.mouseDown(with: down)
            if window.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: false) === up {
                _ = window.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true)
            }
        }
        try click(at: text.gutter.numbersEnd / 2)
        #expect(text.selection == .caret(5))
        try click(at: (text.gutter.numbersEnd + origin.x) / 2)
        #expect(text.selection == .caret(0))
        text.selection = .caret(5)
        try click(at: origin.x + text.linePadding / 2)
        #expect(text.selection == .caret(0))
    }

    @Test func markedTextIsComposedInTheCoresCopyAndOffersNoCompletionsUntilItIsCommitted() {
        let (editor, window) = Self.editor("")
        defer { window.close() }
        let text = editor.textView
        Self.type("\\s", in: text)
        #expect(text.completions.offered != nil)
        Self.event(text) { text.setMarkedText("e", selectedRange: .caret(1), replacementRange: Self.typed) }
        #expect(text.hasMarkedText() && text.document.composing)
        #expect(text.completions.offered == nil && text.document.text == "\\se")
        Self.type("é", in: text)
        #expect(!text.hasMarkedText() && !text.document.composing)
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

    @Test func aChangeOfSeveralEditsKeepsAFoldBetweenThemAndTheCoresCopyThroughUndoAndRedo() {
        let source = "\\begin{itemize}\n\\item a\n\\item b\n\\end{itemize}\nafter"
        let (editor, window) = Self.editor(source)
        defer { window.close() }
        let text = editor.textView
        text.selection = .caret(21)
        text.foldAtCaret()
        #expect(text.folds.ranges == [NSRange(location: 16, length: 16)])
        text.selection = .caret(0)
        text.apply([TextEdit(.caret(0), "% "), TextEdit(.caret(46), "% ")], named: "Comment")
        #expect(text.string == "% " + source.replacingOccurrences(of: "\nafter", with: "\n% after") && text.document.text == text.string)
        #expect(text.folds.ranges == [NSRange(location: 18, length: 16)] && text.undo.undoActionName == "Comment")
        text.undo.undo()
        #expect(text.string == source && text.document.text == source && text.folds.ranges == [NSRange(location: 16, length: 16)])
        #expect(text.selection == .caret(0))
        text.undo.redo()
        #expect(text.string.hasPrefix("% ") && text.document.text == text.string && text.folds.ranges == [NSRange(location: 18, length: 16)])
    }

    @Test func typingOnAfterAChangeOfSeveralEditsUndoesApartFromIt() {
        let (editor, window) = Self.editor("\nz")
        defer { window.close() }
        let text = editor.textView
        Self.type("ab", in: text)
        text.apply([TextEdit(.caret(3), "% ")], named: "Comment")
        Self.type("c", in: text)
        #expect(text.string == "abc\n% z")
        text.undo.undo()
        #expect(text.string == "ab\n% z" && text.document.text == text.string)
        text.undo.undo()
        #expect(text.string == "ab\nz" && text.document.text == text.string)
    }

    @Test func aWrappedLineContinuesUnderItsIndentation() throws {
        let (editor, window) = Self.editor("    " + Array(repeating: "word", count: 80).joined(separator: " "))
        defer { window.close() }
        editor.textView.fontSize = 13
        window.displayIfNeeded()
        let lines = try #require(editor.textView.fragments.first?.fragment.textLineFragments)
        try #require(lines.count > 1)
        #expect(abs(lines[1].typographicBounds.minX - lines[0].locationForCharacter(at: 4).x) < 0.5)
        #expect(abs(lines[1].typographicBounds.minY - lines[0].typographicBounds.minY - 18) < 0.5)
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

    @Test func textLaidOutBeforeAnEditIsColouredWhenScrolledIntoView() throws {
        let (editor, window) = Self.editor((1...400).map { "\\section{\($0)}" }.joined(separator: "\n"))
        defer { window.close() }
        let text = editor.textView
        let manager = try #require(text.textLayoutManager)
        window.displayIfNeeded()
        manager.ensureLayout(for: manager.documentRange)
        Self.type("x", in: text)
        window.displayIfNeeded()
        text.scrollRangeToVisible(NSRange(location: text.length, length: 0))
        window.displayIfNeeded()
        let last = try #require(text.textRange(.caret(text.document.lineStart(400))))
        var colour: NSColor?
        manager.enumerateRenderingAttributes(from: last.location, reverse: false) { _, attributes, _ in
            colour = attributes[.foregroundColor] as? NSColor
            return false
        }
        #expect(colour === HighlightKind.command.color)
    }

    @Test(arguments: [301, 293])
    func foldingAtOrAboveTheTopLineOfALongFileKeepsItInPlace(_ line: Int) throws {
        let block = ["\\begin{itemize}", "\\item " + String(repeating: "word ", count: 30), "\\item b", "\\end{itemize}"]
        let (editor, window) = Self.editor(Array(repeating: block, count: 100).flatMap { $0 }.joined(separator: "\n"))
        defer { window.close() }
        let text = editor.textView
        window.displayIfNeeded()
        text.scroll(toTop: text.document.lineStart(301))
        window.displayIfNeeded()
        let top = try #require(text.shownTop)
        try #require(text.document.line(at: top.offset) == 301)
        text.toggleFold(line: line)
        #expect(text.folds.ranges.count == 1)
        window.displayIfNeeded()
        let shown = try #require(text.shownTop)
        #expect(shown.offset == top.offset && abs(shown.below - top.below) < 0.5, "\(top) became \(shown)")
    }

    @Test func aFileShownAgainHasItsSelectionScrollFoldsAndUndo() throws {
        let block = ["\\begin{itemize}", "\\item a", "\\item b", "\\end{itemize}"]
        let (editor, window) = Self.editor(Array(repeating: block, count: 60).flatMap { $0 }.joined(separator: "\n"))
        defer { window.close() }
        let undo = editor.textView.undo
        Self.type("x", in: editor.textView)
        editor.textView.selection = .caret(21)
        editor.textView.foldAtCaret()
        window.displayIfNeeded()
        editor.textView.scroll(toTop: editor.textView.document.lineStart(101))
        window.displayIfNeeded()
        let a = editor.textView, (text, selection, folds) = (a.string, a.selection, a.folds.ranges), top = try #require(a.shownTop)
        editor.open(path: "b.tex", source: SourceDocument(text: (1...200).map { "b \($0)" }.joined(separator: "\n")))
        window.displayIfNeeded()
        editor.textView.scroll(toTop: editor.textView.document.lineStart(150))
        editor.textView.selection = .caret(3)
        editor.open(path: "main.tex", source: SourceDocument(text: text))
        window.displayIfNeeded()
        let shown = try #require(editor.textView.shownTop)
        #expect(editor.textView.undo === undo && editor.textView.selection == selection && editor.textView.folds.ranges == folds)
        #expect(shown.offset == top.offset && abs(shown.below - top.below) < 0.5, "\(top) became \(shown)")
        undo.undo()
        #expect(editor.textView.string == String(text.dropFirst()) && editor.textView.document.text == editor.textView.string)
    }

    @Test func undoInOneFileNeverUndoesAnother() {
        let (editor, window) = Self.editor("a")
        defer { window.close() }
        Self.type("1", in: editor.textView)
        editor.open(path: "b.tex", source: SourceDocument(text: "b"))
        let b = editor.textView.undo
        b.groupsByEvent = false
        Self.type("2", in: editor.textView)
        while b.canUndo { b.undo() }
        #expect(editor.textView.string == "b" && editor.textView.document.text == "b")
        editor.open(path: "main.tex", source: SourceDocument(text: "1a"))
        #expect(editor.textView.string == "1a" && editor.textView.undo !== b)
        editor.textView.undo.undo()
        #expect(editor.textView.string == "a" && editor.textView.document.text == "a")
    }

    @Test func aFileChangedWhileHiddenShowsItsNewTextFromTheStart() throws {
        let (editor, window) = Self.editor("\\begin{itemize}\n\\item a\n\\item b\n\\end{itemize}\nafter")
        defer { window.close() }
        Self.type("x", in: editor.textView)
        editor.textView.selection = .caret(21)
        editor.textView.foldAtCaret()
        editor.open(path: "b.tex", source: SourceDocument(text: "b"))
        editor.open(path: "main.tex", source: SourceDocument(text: "changed on disk"))
        window.displayIfNeeded()
        let text = editor.textView
        #expect(text.string == "changed on disk" && text.document.text == text.string)
        #expect(text.selection == .caret(0) && text.folds.isEmpty && !text.undo.canUndo && text.shownTop?.offset == 0)
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

    static func editor(_ source: String) -> (SourceEditor, NSWindow) {
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

@MainActor
struct CitingTests {
    @Test func aCitedKeyKeepsTheKeysAroundItApartInOneUndoStep() {
        let source = "See \\cite{first,old}."
        let (editor, window) = EditorTests.editor(source)
        defer { window.close() }
        let text = editor.textView
        let cite = { (selection: NSRange) in
            text.selection = selection
            #expect(editor.perform(.cite("new")))
            defer { text.undo.undo() }
            #expect(text.undo.undoActionName == "Insert Citation" && text.document.text == text.string)
            return (text.string, text.selection)
        }
        #expect(cite(.caret(10)) == ("See \\cite{new,first,old}.", .caret(14)))
        #expect(cite(.caret(16)) == ("See \\cite{first,new,old}.", .caret(20)))
        #expect(cite(.caret(12)) == ("See \\cite{first,new,old}.", .caret(19)))
        #expect(cite(NSRange(location: 16, length: 3)) == ("See \\cite{first,new}.", .caret(19)))
        #expect(cite(.caret(3)) == ("See\\cite{new} \\cite{first,old}.", .caret(13)))
        #expect(text.string == source && text.document.text == source)
    }
}
