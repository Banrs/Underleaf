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

    /// A block's fields, as a completion's: Tab goes from a figure's file to
    /// its caption and label.
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
    @Test func aRevealedLineStaysAtTheTop() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.shown = true
        open((1...6000).map { "Line \($0) " + String(repeating: "word ", count: $0 % 40) }.joined(separator: "\n"), caret: 0)
        /// From the top of what shows to the line's paragraph.
        func top(_ line: Int) -> CGFloat? {
            let clip = editor.scrollView.contentView
            return text.textRange(NSRange(location: text.document.lineStart(line), length: 0))
                .flatMap { text.textLayoutManager?.textLayoutFragment(for: $0.location) }
                .map { $0.layoutFragmentFrame.minY + text.textContainerOrigin.y - clip.bounds.minY - editor.scrollView.contentInsets.top }
        }
        editor.reveal(line: 5000, atTop: true, focus: false)
        #expect(top(5000) == 0)
        editor.scrollView.setFrameSize(NSSize(width: 350, height: 400))
        #expect(top(5000) == 0)
        #expect(text.textContainer?.size.width == text.frame.width - 2 * text.textContainerInset.width)
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
        // Off screen the system's list doesn't open, but the core's items are asked for.
        text.complete(nil)
        let range = text.rangeForUserCompletion
        #expect(range == NSRange(location: 2, length: 4))
        var index = 0
        let labels = try #require(text.completions(forPartialWordRange: range, indexOfSelectedItem: &index))
        #expect(labels.first == "\\begin")
        text.insertCompletion("\\begin", forPartialWordRange: range, movement: NSTextMovement.return.rawValue, isFinal: true)
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

    /// A new line shows its colours once laid out, without the caret moving again.
    @Test func newLinesAreColoured() throws {
        _ = inWindow()
        open("x")
        text.insertText("\n\\section", replacementRange: typed)
        let manager = try #require(text.textLayoutManager)
        manager.textViewportLayoutController.layoutViewport()
        let command = try #require(text.textRange((text.string as NSString).range(of: "\\section")))
        var colour: NSColor?
        manager.enumerateRenderingAttributes(from: command.location, reverse: false) { _, attributes, _ in
            colour = attributes[.foregroundColor] as? NSColor
            return false
        }
        #expect(colour == .systemPink)
    }

    /// Command-click goes to the PDF from the clicked spot; a plain click only places the caret.
    @Test func commandClickGoesToThePDF() throws {
        let window = inWindow()
        open("one two", caret: 0)
        text.layoutSubtreeIfNeeded()
        var went = false
        text.forwardSync = { { went = true } }
        let glyph = text.firstRect(forCharacterRange: NSRange(location: 4, length: 1), actualRange: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: window.convertPoint(fromScreen: NSPoint(x: glyph.minX + 1, y: glyph.midY)),
                                                    modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        text.mouseDown(with: click)
        #expect(went)
        #expect(text.selectedRange() == NSRange(location: 4, length: 0))
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
