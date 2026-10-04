import AppKit
import Testing
@testable import TeXLocal

/// The source editor's own editing, over the core's answers (whose LaTeX
/// crates/texlocal-syntax tests).
@MainActor
struct SourceEditorTests {
    private let editor = SourceEditor()
    private var text: SourceTextView { editor.textView }
    private let typed = NSRange(location: NSNotFound, length: 0)

    private func open(_ string: String, caret: Int? = nil, path: String = "main.tex") {
        editor.open(path: path, text: string, focus: false)
        text.setSelectedRange(NSRange(location: caret ?? (string as NSString).length, length: 0))
    }

    /// Each file has its own undo, kept while another shows, while its text
    /// is as it was left.
    @Test func eachFileKeepsItsUndo() throws {
        open("one", caret: 0, path: "a.tex")
        text.insertText("x", replacementRange: typed)
        let a = try #require(text.undoManager)
        open("two", path: "b.tex")
        #expect(text.undoManager !== a)
        #expect(text.undoManager?.canUndo == false)
        open("xone", path: "a.tex")
        #expect(text.undoManager === a)
        text.undoManager?.undo()
        #expect(text.string == "one")
        // Changed elsewhere since: a fresh start.
        open("two, changed", path: "b.tex")
        open("elsewhere", path: "a.tex")
        #expect(text.undoManager !== a)
    }

    /// A rename onto a name whose file went outside the app keeps the renamed file's undo.
    @Test func aRenameOntoAFileGoneElsewhereKeepsItsUndo() throws {
        open("one", caret: 0, path: "a.tex")
        text.insertText("x", replacementRange: typed)
        let a = try #require(text.undoManager)
        open("two", path: "b.tex")
        open("main", path: "main.tex")
        // b.tex deleted in the Finder, so its kept state stays; a.tex takes its name.
        editor.rename(from: "a.tex", to: "b.tex")
        open("xone", path: "b.tex")
        #expect(text.undoManager === a)
    }

    /// The mirror keeps a U+0000 the editor keeps, and the offsets after it (#24).
    @Test func aNulCharacterKeepsTheMirrorInStep() {
        let document = SourceDocument(text: "a\u{0}\nb")
        #expect(document.lineCount == 2)
        document.edit(NSRange(location: 4, length: 0), with: "\u{0}\nc")
        #expect(document.lineCount == 3)
        #expect(document.lineStart(3) == 6)
    }

    @Test func bracketsCloseAndAreSteppedOver() {
        open("")
        text.insertText("{", replacementRange: typed)
        #expect(text.string == "{}" && text.selectedRange() == NSRange(location: 1, length: 0))
        text.insertText("}", replacementRange: typed)
        #expect(text.string == "{}" && text.selectedRange() == NSRange(location: 2, length: 0))
        // Before a word, only the one typed.
        open("x", caret: 0)
        text.insertText("(", replacementRange: typed)
        #expect(text.string == "(x")
        // Round a selection, which stays selected.
        open("ab")
        text.setSelectedRange(NSRange(location: 0, length: 2))
        text.insertText("[", replacementRange: typed)
        #expect(text.string == "[ab]" && text.selectedRange() == NSRange(location: 1, length: 2))
        // An empty pair goes as one.
        open("{}", caret: 1)
        text.deleteBackward(nil)
        #expect(text.string == "")
    }

    @Test func anEmojiAfterAnOpeningBracketIsOccupiedText() {
        open("😀", caret: 0)
        text.insertText("(", replacementRange: typed)
        #expect(text.string == "(😀")
        #expect(text.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func newLinesKeepTheIndentation() {
        open("  a", caret: 3)
        text.insertNewline(nil)
        #expect(text.string == "  a\n  " && text.selectedRange().location == 6)
        // Between brackets, the closing one a line further down.
        open("  a{}", caret: 4)
        text.insertNewline(nil)
        #expect(text.string == "  a{\n  \n  }" && text.selectedRange().location == 7)
        // Tab and Shift-Tab indent by two spaces; Delete in the indentation back to a stop.
        open("x", caret: 0)
        text.insertTab(nil)
        #expect(text.string == "  x")
        text.insertBacktab(nil)
        #expect(text.string == "x")
        open("     y", caret: 5)
        text.deleteBackward(nil)
        #expect(text.string == "    y")
    }

    /// The core's edits go in as one undo step, the selection following the
    /// text: text put in at its start goes before it.
    @Test func commentsToggleAsOneStep() {
        open("a\n  b")
        text.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(editor.perform(.comment))
        // At the least indentation of the lines.
        #expect(text.string == "% a\n%   b")
        #expect(text.selectedRange() == NSRange(location: 2, length: 7))
        #expect(editor.document?.text == text.string)
        text.undoManager?.undo()
        #expect(text.string == "a\n  b")
        #expect(editor.document?.text == text.string)
        text.undoManager?.redo()
        #expect(text.string == "% a\n%   b")
        #expect(editor.document?.text == text.string)
    }

    @Test func wrappingKeepsTheSelection() {
        open("word")
        text.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(editor.perform(.bold))
        #expect(text.string == "\\textbf{word}" && text.selectedRange() == NSRange(location: 8, length: 4))
        #expect(editor.perform(.inline, "\\ref{$0}"))
        #expect(text.string == "\\textbf{\\ref{word}}")
        #expect(!editor.perform(.block, "no such block"))
    }

    /// Bold, Italic and Underline are on where the selection is in their
    /// command, as a word processor's: they unwrap it, in one step.
    @Test func aStyleTheSelectionIsInUnwraps() {
        open("a \\textit{b \\textbf{word} c} d")
        let word = (text.string as NSString).range(of: "word")
        text.setSelectedRange(word)
        #expect(editor.textStyles.bold != nil && editor.textStyles.italic != nil && editor.textStyles.underline == nil)
        #expect(editor.perform(.bold))
        #expect(text.string == "a \\textit{b word c} d")
        #expect(text.selectedRange() == NSRange(location: word.location - 8, length: 4))
        #expect(editor.textStyles.bold == nil)
        text.undoManager?.undo()
        #expect(text.string == "a \\textit{b \\textbf{word} c} d")
        #expect(editor.document?.text == text.string)
        text.undoManager?.redo()
        #expect(editor.perform(.underline))
        #expect(text.string == "a \\textit{b \\underline{word} c} d")
        // The caret in it, the whole command goes.
        text.setSelectedRange(NSRange(location: 11, length: 0))
        #expect(editor.perform(.italic))
        #expect(text.string == "a b \\underline{word} c d" && text.selectedRange() == NSRange(location: 3, length: 0))
        #expect(editor.document?.text == text.string)
    }

    /// A block's fields, as a completion's: Tab goes from a figure's file to
    /// its caption and label.
    /// Escape that reaches the editor through the window, not its own keys, passes up the
    /// chain instead of to NSTextView, which doesn't take it and would throw.
    @Test func escapeOutsideASnippetPassesOn() {
        open("text")
        text.cancelOperation(nil)
        #expect(text.string == "text")
    }

    @Test func blocksTabThroughTheirFields() {
        open("")
        #expect(editor.perform(.block, "figure"))
        let string = text.string as NSString
        #expect(text.selectedRange() == NSRange(location: string.range(of: "]{}").location + 2, length: 0))
        text.insertTab(nil)
        #expect(text.selectedRange().location == NSMaxRange(string.range(of: "\\caption{")))
        text.insertTab(nil)
        #expect(text.selectedRange().location == NSMaxRange(string.range(of: "fig:")))
    }

    /// A line revealed far down is at the top exactly, and stays there as the column
    /// narrows: TextKit 2 estimates what's above it, and the width changes that. The
    /// lines wrap at once, at the width AppKit's tracking gives as a live resize ends.
    @Test(arguments: [false, true]) func aRevealedLineStaysAtTheTop(syntax: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.shown = true
        open((1...6000).map { (syntax ? "\\section{Line \($0)} " : "Line \($0) ")
            + String(repeating: "word ", count: $0 % 40) }.joined(separator: "\n"), caret: 0)
        /// From the top of what shows to the line's paragraph.
        func top(_ line: Int) -> CGFloat? {
            let clip = editor.scrollView.contentView
            return text.textRange(NSRange(location: text.document.lineStart(line), length: 0))
                .flatMap { text.textLayoutManager?.textLayoutFragment(for: $0.location) }
                .map { $0.layoutFragmentFrame.minY + text.textContainerOrigin.y - clip.bounds.minY - editor.scrollView.contentInsets.top }
        }
        editor.reveal(line: 5000, atTop: true, focus: false)
        #expect(top(5000) == 0, "Actual top: \(String(describing: top(5000)))")
        editor.scrollView.setFrameSize(NSSize(width: 350, height: 400))
        #expect(top(5000) == 0, "Actual top: \(String(describing: top(5000)))")
        #expect(text.textContainer?.size.width == text.frame.width - 2 * text.textContainerInset.width)
    }

    /// A file shown again comes back scrolled where it was left, as its caret does, while its
    /// text is as it was; changed since, it opens at its top.
    @Test func aFileShownAgainIsWhereItWasLeft() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.shown = true
        let long = (1...2000).map { "Line \($0)" }.joined(separator: "\n")
        open(long, caret: 0, path: "a.tex")
        editor.reveal(line: 1200, atTop: true, focus: false)
        let left = try #require(text.shownTop)
        open("short", path: "b.tex")
        open(long, path: "a.tex")
        #expect(text.shownTop?.offset == left.offset && text.shownTop?.below == left.below)
        open("short", path: "b.tex")
        open(long + "\nmore", path: "a.tex")
        #expect(editor.scrollView.contentView.bounds.minY == -editor.scrollView.contentInsets.top)
    }

    /// A command is its own named undo step between the typing before and after it.
    @Test func aCommandIsItsOwnUndoStep() throws {
        open("", caret: 0)
        let undo = try #require(text.undoManager)
        // Each step an event of its own, in its own top-level undo group, as AppKit gives it.
        undo.groupsByEvent = false
        func step(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }
        step { text.insertText("a", replacementRange: typed) }
        step { text.insertText("b", replacementRange: typed) }
        step { editor.perform(.bold) }
        #expect(undo.undoActionName == "Bold")
        step { text.insertText("c", replacementRange: typed) }
        #expect(text.string == "ab\\textbf{c}")
        undo.undo()
        #expect(text.string == "ab\\textbf{}")
        #expect(undo.undoActionName == "Bold")
        undo.undo()
        #expect(text.string == "ab")
        #expect(text.document.text == text.string)
    }

    /// Jump to Selection centres the selection, far down a long file whose heights TextKit
    /// has only estimated.
    @Test func jumpToSelectionCentresIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.shown = true
        open((1...6000).map { "\\section{Line \($0)} " + String(repeating: "word ", count: $0 % 40) }.joined(separator: "\n"), caret: 0)
        let start = text.document.lineStart(5000)
        text.setSelectedRange(NSRange(location: start, length: 4))
        text.centerSelectionInVisibleArea(nil)
        let clip = editor.scrollView.contentView
        let fragment = try #require(text.textRange(NSRange(location: start, length: 0))
            .flatMap { text.textLayoutManager?.textLayoutFragment(for: $0.location) })
        let line = try #require(fragment.textLineFragments.first)
        let middle = fragment.layoutFragmentFrame.minY + line.typographicBounds.midY + text.textContainerOrigin.y
        let shown = clip.bounds.height - editor.scrollView.contentInsets.top - editor.scrollView.contentInsets.bottom
        let centre = clip.bounds.minY + editor.scrollView.contentInsets.top + shown / 2
        // Within a line: TextKit settles the heights above as it lays out what now shows.
        #expect(abs(middle - centre) < (text.defaultParagraphStyle?.minimumLineHeight ?? 18), "Line at \(middle), centre \(centre)")
    }

    /// Move Line Up and Down take the selections' lines past their neighbours, the selections
    /// going with them, in one undo step; a last line without a line break keeps none.
    @Test func linesMoveUpAndDown() throws {
        open("a\nb\nc\nd", caret: 2)
        #expect(editor.perform(.moveLineUp))
        #expect(text.string == "b\na\nc\nd" && text.selectedRange() == NSRange(location: 0, length: 0))
        #expect(!editor.perform(.moveLineUp))
        #expect(text.string == "b\na\nc\nd")
        // Down to the end: the moved line takes the last one's place, without its break.
        text.setSelectedRange(NSRange(location: 4, length: 1))
        #expect(editor.perform(.moveLineDown))
        #expect(text.string == "b\na\nd\nc" && text.selectedRange() == NSRange(location: 6, length: 1))
        #expect(!editor.perform(.moveLineDown))
        // The last line, without a break, up, in an undo group of its own as a key press has.
        let undo = try #require(text.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(editor.perform(.moveLineUp))
        undo.endUndoGrouping()
        #expect(text.string == "b\na\nc\nd" && text.selectedRange() == NSRange(location: 4, length: 1))
        #expect(text.undoManager?.undoActionName == "Move Line Up")
        text.undoManager?.undo()
        #expect(text.string == "b\na\nd\nc")
        #expect(text.document.text == text.string)
    }

    /// Several selections move together; a selection ending at a line's start leaves that line.
    @Test func severalSelectionsMoveTogether() {
        open("1\n2\n3\n4\n5\n6", caret: 0)
        // Lines 2–3 (selected up to line 4's start) and line 5.
        text.setSelectedRanges([NSValue(range: NSRange(location: 2, length: 4)), NSValue(range: NSRange(location: 8, length: 1))],
                               affinity: .downstream, stillSelecting: false)
        #expect(editor.perform(.moveLineUp))
        #expect(text.string == "2\n3\n1\n5\n4\n6")
        #expect(text.selectedRanges.map(\.rangeValue) == [NSRange(location: 0, length: 4), NSRange(location: 6, length: 1)])
        #expect(text.document.text == text.string)
    }

    /// SyncTeX's word: an inverse search's column selects the word there, and a
    /// forward search sends the word at the caret.
    @Test func syncTeXGoesToTheWord() {
        open("Ünï words \\word, the word\nnext", caret: 1)
        #expect(editor.currentSyncWord?.text == "Ünï")
        editor.reveal(line: 1, column: 21, focus: false)
        #expect(text.selectedRange() == NSRange(location: 21, length: 4))
        #expect(editor.currentSyncWord?.text == "word")
    }

    @Test func syncTeXRetainsTheClickedOccurrenceAndUTF16Column() throws {
        let source = "before\n😀 echo echo echo\n"
        let range = (source as NSString).range(of: "echo", options: .backwards)
        open(source, caret: range.location + 2)
        let word = try #require(editor.currentSyncWord)
        #expect(word.text == "echo" && word.offset == 2)
        #expect(word.context == "😀 echo echo echo\n")
        #expect(word.contextOffset == 13)
        #expect(editor.currentLine == 2 && editor.currentColumn == 15)
    }

    /// A file opened with the keyboard asked for takes it once the editor shows,
    /// as a project opens; one chosen in the sidebar leaves it where it is.
    @Test func theKeyboardFollowsTheOpen() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // Something else with the keyboard, as the Files list.
        let list = NSTextView()
        window.contentView!.addSubview(list)
        window.contentView!.addSubview(editor.scrollView)
        window.makeFirstResponder(list)
        editor.open(path: "a.tex", text: "one")
        editor.shown = true
        #expect(window.firstResponder === text)
        editor.shown = false
        window.makeFirstResponder(list)
        editor.open(path: "b.tex", text: "two", focus: false)
        editor.shown = true
        #expect(window.firstResponder === list)
    }

    /// A chosen completion goes in as its snippet: typed in one place, a
    /// field is typed in all of its places, and Tab goes to the next.
    @Test(.timeLimit(.minutes(1)))
    func completionsFillTheirFields() throws {
        open("  \\beg")
        // Without a window the list holds the core's items unseen.
        text.complete(nil)
        let offered = try #require(text.offered)
        #expect(offered.start == 2 && offered.items.first?.label == "\\begin")
        // Return accepts the selected item, the first.
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(text.offered == nil)
        #expect(text.string == "  \\begin{env}\n    \n  \\end{env}")
        #expect(text.selectedRange() == NSRange(location: 9, length: 3))
        text.insertText("itemize", replacementRange: typed)
        #expect(text.string == "  \\begin{itemize}\n    \n  \\end{itemize}")
        text.insertTab(nil)
        #expect(text.selectedRange() == NSRange(location: 22, length: 0))
        // The last field reached, Tab indents again.
        text.insertTab(nil)
        #expect(text.string == "  \\begin{itemize}\n      \n  \\end{itemize}")
        // The core's copy went through every step with it.
        #expect(text.document.text == text.string)
    }

    /// The list follows typing; arrows choose, Escape and a move away close it
    /// with nothing put in, and typed keys only go into the document.
    @Test func theCompletionListTakesOnlyItsKeys() throws {
        open("\\")
        text.insertText("b", replacementRange: typed)
        let all = try #require(text.offered).items.count
        text.insertText("e", replacementRange: typed)
        #expect(try #require(text.offered).items.count < all)
        text.deleteBackward(nil)
        #expect(text.offered?.items.count == all)
        text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(text.offered == nil && text.string == "\\b")
        // The second item, chosen with the arrow.
        text.complete(nil)
        let second = try #require(text.offered?.items[1])
        text.doCommand(by: #selector(NSResponder.moveDown(_:)))
        text.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(text.string == second.text)
        // A typed key that matches nothing closes it and goes in.
        open("\\be")
        text.complete(nil)
        text.insertText(" ", replacementRange: typed)
        #expect(text.offered == nil && text.string == "\\be ")
        // Moving the caret closes it.
        open("\\be")
        text.complete(nil)
        #expect(text.offered != nil)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(text.offered == nil)
    }

    /// Shown again with fewer rows, in another size, or with none, the list never
    /// asks for a row it no longer has.
    @Test func theCompletionListKeepsItsRowsInStep() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let list = CompletionList()
        let rows = (0..<20).map { (label: "\\item\($0)", kind: CompletionKind.command) }
        func show(_ count: Int, size: CGFloat) {
            list.show(Array(rows.prefix(count)), font: .monospacedSystemFont(ofSize: size, weight: .regular), theme: .overleaf,
                      under: NSRect(x: 100, y: 300, width: 1, height: 14), in: window)
            for child in window.childWindows ?? [] { child.layoutIfNeeded() }
        }
        show(20, size: 11)
        list.move(15)
        show(2, size: 24)
        #expect(list.selection == 0 && window.childWindows?.count == 1)
        show(0, size: 11)
        #expect(window.childWindows?.isEmpty != false)
    }

    /// The selected row is drawn as the focused list's, the accent's, from the first show,
    /// though the document keeps the keyboard.
    @Test func theCompletionListSelectsAsTheFocusedList() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let list = CompletionList()
        list.show((0..<3).map { (label: "\\item\($0)", kind: CompletionKind.command) }, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                  theme: .overleaf, under: NSRect(x: 100, y: 300, width: 1, height: 14), in: window)
        let panel = try #require(window.childWindows?.first)
        panel.layoutIfNeeded()
        let table = try #require(panel.firstResponder as? NSTableView)
        #expect(table.rowView(atRow: 0, makeIfNecessary: false)?.isEmphasized == true)
        #expect(NSApp.keyWindow !== panel && !panel.canBecomeKey)
        list.close()
    }

    @Test func autosaveReadsOnlyCommittedTextDuringIMEComposition() {
        open("start")
        text.insertText("x", replacementRange: typed)
        #expect(editor.document?.text == "startx")

        text.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: typed)
        #expect(text.hasMarkedText())
        #expect(text.string == "startxあ" && text.document.text == text.string)
        // ProjectModel's pending autosave reads this payload.
        #expect(editor.document?.text == "startx")
        text.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0), replacementRange: typed)
        #expect(text.string == "startxあい" && text.document.text == text.string)
        #expect(editor.document?.text == "startx")

        text.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: typed)
        #expect(!text.hasMarkedText())
        #expect(text.string == "startx" && text.document.text == text.string)
        #expect(editor.document?.text == text.string)

        text.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: typed)
        text.insertText("亜", replacementRange: typed)
        #expect(!text.hasMarkedText())
        #expect(text.string == "startx亜" && text.document.text == text.string)
        #expect(editor.document?.text == text.string)
    }

    @Test func replacingASelectionStaysProvisionalUntilUnmarked() {
        open("before old after")
        text.setSelectedRange(NSRange(location: 7, length: 3))
        text.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0), replacementRange: typed)
        #expect(text.string == "before 候補 after")
        #expect(editor.document?.text == "before old after")

        text.unmarkText()
        #expect(!text.hasMarkedText())
        #expect(editor.document?.text == "before 候補 after")
        // A later composition starts from the newly committed text.
        text.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: typed)
        #expect(editor.document?.text == "before 候補 after")
        text.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: typed)
        #expect(editor.document?.text == text.string)
    }

    @Test func switchingFilesDuringCompositionKeepsUndoWithItsOwnText() {
        open("first", path: "a.tex")
        text.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: typed)
        #expect(editor.document?.text == "first")

        open("second", path: "b.tex")
        #expect(!text.hasMarkedText())
        #expect(editor.document?.text == "second" && text.document.text == "second")
        #expect(text.undoManager?.canUndo == false)
        // The old undo referred to provisional text that wasn't saved to a.tex.
        open("first", path: "a.tex")
        text.undoManager?.undo()
        #expect(text.string == "first" && editor.document?.text == "first")
    }

    /// Native result ranges are relative to the checked substring; formatted
    /// prose and comments remain eligible while TeX names stay protected.
    @Test func spellingIsTheProses() {
        let line = "🙂 \\emph{wrod} \\label{sec:wrod} \\cite[see]{wrod} \\usepackage[utf8]{wrod} \\includegraphics{wrod.pdf} $wrod$ % wrod"
        open(line)
        let checked = NSRange(location: 3, length: (line as NSString).length - 3)
        let text = line as NSString
        let misspelt = ["emph", "wrod"].flatMap { word in
            var ranges: [NSRange] = [], from = checked.location
            while case let r = text.range(of: word, range: NSRange(location: from, length: text.length - from)), r.location != NSNotFound {
                ranges.append(NSRange(location: r.location - checked.location, length: r.length))
                from = NSMaxRange(r)
            }
            return ranges
        }
        let results = misspelt.flatMap { range in
            [NSTextCheckingResult.spellCheckingResult(range: range),
             NSTextCheckingResult.correctionCheckingResult(range: range, replacementString: "word"),
             NSTextCheckingResult.replacementCheckingResult(range: range, replacementString: "word")]
        }
        let kept = editor.textView(self.text, didCheckTextIn: checked, types: NSTextCheckingAllTypes, options: [:], results: results,
                                   orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 6)
        // The emphasised word and the comment's.
        let expected = [text.range(of: "wrod"), text.range(of: "wrod", options: .backwards)]
            .map { NSRange(location: $0.location - checked.location, length: $0.length) }
        #expect(kept.map(\.range) == expected.flatMap { Array(repeating: $0, count: 3) })
        #expect(kept.map(\.resultType) == expected.flatMap { _ in [.spelling, .correction, .replacement] })
    }

    /// Correction and text replacement are the user's system settings, applied in prose only
    /// (above); smart quotes and dashes would rewrite TeX, so they stay off.
    @Test func substitutionsFollowTheSystemButQuotesAndDashes() {
        #expect(text.isAutomaticSpellingCorrectionEnabled == NSSpellChecker.isAutomaticSpellingCorrectionEnabled)
        #expect(text.isAutomaticTextReplacementEnabled == NSSpellChecker.isAutomaticTextReplacementEnabled)
        #expect(!text.isAutomaticQuoteSubstitutionEnabled && !text.isAutomaticDashSubstitutionEnabled)
    }

    /// A check can start inside a multiline environment. Text arguments and
    /// comments are still prose, including non-ASCII words inside dollar maths.
    @Test func spellingDistinguishesMathAndVerbatimFromTheirProse() {
        let source = """
        🙂
        \\begin{align}
        mathwrod &= \\text{prosewrod} % commentwrod
        \\end{align}
        $\\text{naïvve} + dollarwrod$
        \\verb|verbwrod|
        \\begin{verbatim}
        codewrod
        \\end{verbatim}
        afterwrod
        """
        open(source)
        let string = source as NSString
        let start = string.range(of: "mathwrod").location
        let checked = NSRange(location: start, length: string.length - start)
        let words = ["mathwrod", "prosewrod", "commentwrod", "naïvve", "dollarwrod", "verbwrod", "codewrod", "afterwrod"]
        let relative = { (word: String) in
            let range = string.range(of: word)
            return NSRange(location: range.location - checked.location, length: range.length)
        }
        let results = words.map { NSTextCheckingResult.correctionCheckingResult(range: relative($0), replacementString: "word") }
        let kept = editor.textView(text, didCheckTextIn: checked, types: NSTextCheckingAllTypes, options: [:], results: results,
                                   orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: words.count)
        #expect(kept.map(\.range) == ["prosewrod", "commentwrod", "naïvve", "afterwrod"].map(relative))
    }

    private func inWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.shown = true
        return window
    }

    /// The colour the editor draws `word` in, once laid out.
    private func colour(of word: String) throws -> NSColor? {
        let manager = try #require(text.textLayoutManager)
        text.layoutSubtreeIfNeeded()
        manager.textViewportLayoutController.layoutViewport()
        let bitmap = try #require(text.bitmapImageRepForCachingDisplay(in: text.visibleRect))
        text.cacheDisplay(in: text.visibleRect, to: bitmap)
        let range = try #require(text.textRange((text.string as NSString).range(of: word)))
        var colour: NSColor?
        manager.enumerateRenderingAttributes(from: range.location, reverse: false) { _, attributes, _ in
            colour = attributes[.foregroundColor] as? NSColor
            return false
        }
        return colour
    }

    private func renderedText() throws -> Data {
        text.layoutSubtreeIfNeeded()
        let bitmap = try #require(text.bitmapImageRepForCachingDisplay(in: text.visibleRect))
        text.cacheDisplay(in: text.visibleRect, to: bitmap)
        return try #require(bitmap.tiffRepresentation)
    }

    /// A new line shows its colours once laid out, without the caret moving again.
    @Test func newLinesAreColoured() async throws {
        // Held to the end: the text lays out in it.
        let window = inWindow()
        defer { withExtendedLifetime(window) {} }
        open("x")
        text.insertText("\n\\section", replacementRange: typed)
        try await waitUntil { (try? self.colour(of: "\\section")) == SyntaxTheme.overleaf.colours.command }
    }

    /// Choosing another colour theme recolours what is open.
    @Test func aThemeRecoloursTheText() async throws {
        // Held to the end: the text lays out in it.
        let window = inWindow()
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.close() }
        open("\\section{A} % note")
        text.syntaxTheme = .texstudio
        try await waitUntil { (try? self.colour(of: "\\section")) == SyntaxTheme.texstudio.colours.command } state: {
            "TeXstudio: \(String(describing: try? self.colour(of: "\\section")))"
        }
        #expect(try colour(of: "% note") == SyntaxTheme.texstudio.colours.comment)
        let before = try renderedText()
        text.syntaxTheme = .system
        try await waitUntil { (try? self.colour(of: "\\section")) == NSColor.systemPink } state: {
            "System: \(String(describing: try? self.colour(of: "\\section")))"
        }
        #expect(try renderedText() != before, "A theme change must repaint the already-visible text.")
        text.syntaxTheme = .overleaf
        try await waitUntil { (try? self.colour(of: "\\section")) == SyntaxTheme.overleaf.colours.command }
    }

    /// With Increase Contrast every theme colour reaches 7:1 on the text's background, as little
    /// changed as that takes: one that has it already stays as it is.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func increasedContrastRaisesTheThemes(appearance: NSAppearance.Name) throws {
        func resolved(_ color: NSColor) -> NSColor {
            var out = color
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
            return out
        }
        let background = resolved(.textBackgroundColor)
        for theme in [SyntaxTheme.overleaf, .texstudio] {
            let c = theme.colours
            for color in [c.command, c.keyword, c.argument, c.maths, c.comment, c.invalid].map(resolved) {
                let raised = color.contrasting(in: appearance, by: 7)
                #expect(raised.contrast(with: background) >= 7, "\(theme) \(color)")
                if color.contrast(with: background) >= 7 { #expect(raised == color) }
            }
        }
        // Overleaf's Light comments, at 4.2:1, are raised; its commands, at 8.6:1, are not.
        if appearance == .aqua {
            #expect(resolved(SyntaxTheme.overleaf.colours.comment).contrast(with: background) < 4.5)
        }
    }

    /// A double-click goes to the PDF from the word it selects; a single click only places the caret.
    @Test func aDoubleClickGoesToThePDF() throws {
        let window = inWindow()
        open("one two", caret: 0)
        text.layoutSubtreeIfNeeded()
        var went = 0
        text.forwardSync = { { went += 1 } }
        let glyph = text.firstRect(forCharacterRange: NSRange(location: 4, length: 1), actualRange: nil)
        let point = window.convertPoint(fromScreen: NSPoint(x: glyph.minX + 1, y: glyph.midY))
        func event(_ type: NSEvent.EventType, clicks: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        for clicks in 1...2 {
            // The release ends the text view's own tracking.
            NSApp.postEvent(try event(.leftMouseUp, clicks: clicks), atStart: false)
            text.mouseDown(with: try event(.leftMouseDown, clicks: clicks))
            #expect(went == clicks - 1)
        }
        #expect(text.selectedRange() == NSRange(location: 4, length: 3))
    }

    /// Go to Line…'s sheet puts the caret at its line's start.
    @Test func goToLinePutsTheCaretOnTheLine() {
        open((1...300).map { "line \($0)" }.joined(separator: "\n"), caret: 0)
        editor.reveal(line: 120, focus: false)
        #expect(editor.currentLine == 120 && editor.currentColumn == 0)
    }

    /// The text's context menu starts with Go to PDF Position, as the PDF's with
    /// Go to Source Position, while there's somewhere to go, over the system's plain-text menu.
    @Test func theContextMenuGoesToThePDF() throws {
        open("x")
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(text.menu(for: click)?.items.first?.title != MenuCommand.syncForward.title)
        var went = false
        text.forwardSync = { { went = true } }
        let menu = try #require(text.menu(for: click))
        #expect(menu.items.first?.title == MenuCommand.syncForward.title)
        #expect(menu.items[1].isSeparatorItem)
        menu.performActionForItem(at: 0)
        #expect(went)
        let titles = menu.items.map(\.title)
        #expect(["Cut", "Copy", "Paste", "Spelling and Grammar"].allSatisfy(titles.contains))
        // Plain text: nothing to style.
        #expect(!titles.contains("Font") && !text.isRichText && !text.importsGraphics && !text.usesFontPanel)
    }
}
