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

    /// A text view made on its own is its storage's delegate: its edits reach the core's mirror.
    @Test func aTextViewOnItsOwnMirrorsItsEdits() {
        let view = SourceTextView.plainDocument()
        view.load("one")
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.string == "xone" && view.document.text == "xone")
    }

    /// `plainDocument()` sets only what a new text view isn't already: the rest is as a scroll view's plain document needs it too.
    @Test func aPlainDocumentIsSetUpForAScrollView() {
        let view = SourceTextView.plainDocument()
        #expect(!view.isRichText && !view.importsGraphics && !view.allowsImageEditing && !view.usesRuler)
        #expect(view.isVerticallyResizable && !view.isHorizontallyResizable && view.minSize == .zero)
        #expect(view.textContainer?.widthTracksTextView == true)
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
        // An empty pair the editor closed goes as one; one that was there loses only its bracket.
        open("")
        text.insertText("{", replacementRange: typed)
        text.deleteBackward(nil)
        #expect(text.string == "")
        open("{}", caret: 1)
        text.deleteBackward(nil)
        #expect(text.string == "}")
    }

    /// After a backslash a bracket closes with a backslash too, and both of the closer's
    /// characters are stepped over; an escaped backslash before it is a line break's.
    @Test func escapedBracketsCloseEscaped() {
        open("\\")
        text.insertText("[", replacementRange: typed)
        #expect(text.string == "\\[\\]" && text.selectedRange() == NSRange(location: 2, length: 0))
        text.insertText("x", replacementRange: typed)
        text.insertText("\\", replacementRange: typed)
        text.insertText("]", replacementRange: typed)
        #expect(text.string == "\\[x\\]" && text.selectedRange() == NSRange(location: 5, length: 0))
        // A command typed inside keeps the closer whole, and the bracket alone steps over it.
        open("\\")
        text.insertText("(", replacementRange: typed)
        for c in "\\pi" { text.insertText(String(c), replacementRange: typed) }
        #expect(text.string == "\\(\\pi\\)" && text.selectedRange() == NSRange(location: 5, length: 0))
        text.insertText(")", replacementRange: typed)
        #expect(text.string == "\\(\\pi\\)" && text.selectedRange() == NSRange(location: 7, length: 0))
        open("\\")
        text.insertText("{", replacementRange: typed)
        #expect(text.string == "\\{\\}")
        text.deleteBackward(nil)
        #expect(text.string == "\\")
        open("\\")
        text.insertText("[", replacementRange: typed)
        text.insertNewline(nil)
        #expect(text.string == "\\[\n\n\\]" && text.selectedRange() == NSRange(location: 3, length: 0))
        open("\\\\")
        text.insertText("[", replacementRange: typed)
        #expect(text.string == "\\\\[]")
    }

    /// Escape ends a snippet's fields, opens the list where there's something to complete, and
    /// is never passed on: the window would leave full screen.
    @Test func escapeStaysInTheEditor() throws {
        final class Catcher: NSResponder {
            var cancelled = false
            override func cancelOperation(_ sender: Any?) { cancelled = true }
        }
        let catcher = Catcher()
        text.nextResponder = catcher
        open("plain")
        text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!catcher.cancelled && text.offered == nil)
        open("\\be")
        text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!catcher.cancelled && text.offered != nil)
    }

    /// Settings' two typing switches, off: a bracket goes in alone and comes out alone, and
    /// the list waits to be asked for, then follows the typing as before.
    @Test func typingAssistanceCanBeTurnedOff() throws {
        let defaults = UserDefaults.standard, keys = [EditorPrefs.autoPairKey, EditorPrefs.autoCompleteKey]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.set(false, forKey: key) }
        open("")
        text.insertText("{", replacementRange: typed)
        #expect(text.string == "{")
        open("{}", caret: 1)
        text.deleteBackward(nil)
        #expect(text.string == "}")
        open("\\")
        text.insertText("b", replacementRange: typed)
        #expect(text.offered == nil)
        text.complete(nil)
        let all = try #require(text.offered).items.count
        text.insertText("e", replacementRange: typed)
        #expect(try #require(text.offered).items.count < all)
    }

    /// Without its numbers the gutter is a margin, and the text starts further left.
    @Test func hidingLineNumbersNarrowsTheGutter() {
        open("a")
        let numbered = text.textContainerOrigin.x
        text.showsLineNumbers = false
        #expect(text.textContainerOrigin.x < numbered)
        text.showsLineNumbers = true
        #expect(text.textContainerOrigin.x == numbered)
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
    @Test func blocksTabThroughTheirFields() {
        open("")
        #expect(editor.perform(.block, "figure"))
        let string = text.string as NSString
        #expect(text.selectedRange() == NSRange(location: string.range(of: "]{}").location + 2, length: 0))
        text.insertTab(nil)
        #expect(text.selectedRange().location == NSMaxRange(string.range(of: "\\caption{")))
        text.insertTab(nil)
        #expect(text.selectedRange().location == NSMaxRange(string.range(of: "fig:")))
        #expect(text.undoManager?.undoActionName == "Insert")
        open("")
        #expect(editor.perform(.block, "figure", title: "Figure"))
        #expect(text.undoManager?.undoActionName == "Insert Figure")
    }

    /// Writing Tools are kept to the prose: commands, their names, maths and comments are passed over.
    @Test func writingToolsPassOverTheLaTeX() {
        let source = "Some \\emph{prose} with $x^2$ and \\label{sec:a}. % note"
        open(source)
        let string = source as NSString
        let ignored = editor.textView(text, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: string.length)).map(\.rangeValue)
        func isIgnored(_ word: String) -> Bool {
            ignored.contains { NSIntersectionRange($0, string.range(of: word)).length > 0 }
        }
        #expect(isIgnored("\\emph") && isIgnored("$x^2$") && isIgnored("sec:a") && isIgnored("% note"))
        #expect(!isIgnored("Some") && !isIgnored("prose") && !isIgnored("with"))
        #expect(text.writingToolsBehavior == .limited)
    }

    /// The context menu has the editor's own commands first and none of the system's that do
    /// nothing for LaTeX source.
    @Test func theContextMenuIsTheSourcesOwn() throws {
        open("word", caret: 0)
        text.forwardSync = { _ in {} }
        let menu = NSMenu()
        for (title, action) in [("Cut", #selector(NSText.cut(_:))), ("Speech", #selector(NSTextView.startSpeaking(_:))),
                                ("Layout Orientation", #selector(NSTextView.changeLayoutOrientation(_:)))] {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        let transformations = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        transformations.submenu = NSMenu()
        transformations.submenu?.addItem(NSMenuItem(title: "Make Upper Case", action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: ""))
        menu.addItem(transformations)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let shown = try #require(editor.textView(text, menu: menu, for: event, at: 0))
        #expect(shown.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Go to PDF Position", "Comment Selection", "-", "Cut"])
    }

    /// A line revealed far down is at the top exactly, and stays there as the column
    /// narrows: TextKit 2 estimates what's above it, and the width changes that. The
    /// lines wrap at once, at the width AppKit's tracking gives as a live resize ends.
    @Test(arguments: [false, true]) func aRevealedLineStaysAtTheTop(syntax: Bool) {
        // Held to the end: the text lays out in it.
        let window = inWindow()
        defer { withExtendedLifetime(window) {} }
        open((1...6000).map { (syntax ? "\\section{Line \($0)} " : "Line \($0) ")
            + String(repeating: "word ", count: $0 % 40) }.joined(separator: "\n"), caret: 0)
        /// From the top of what shows to the line's paragraph.
        func top(_ line: Int) -> CGFloat? {
            let clip = editor.textView.enclosingScrollView!.contentView
            return text.textRange(NSRange(location: text.document.lineStart(line), length: 0))
                .flatMap { text.textLayoutManager?.textLayoutFragment(for: $0.location) }
                .map { $0.layoutFragmentFrame.minY + text.textContainerOrigin.y - clip.bounds.minY - clip.contentInsets.top }
        }
        editor.reveal(line: 5000, atTop: true, focus: false)
        #expect(top(5000) == 0, "Actual top: \(String(describing: top(5000)))")
        editor.textView.enclosingScrollView!.setFrameSize(NSSize(width: 350, height: 400))
        #expect(top(5000) == 0, "Actual top: \(String(describing: top(5000)))")
        #expect(text.textContainer?.size.width == text.frame.width - 2 * text.textContainerInset.width)
    }

    /// A file shown again comes back scrolled where it was left, as its caret does, while its
    /// text is as it was; changed since, it opens at its top.
    @Test func aFileShownAgainIsWhereItWasLeft() throws {
        // Held to the end: the text lays out in it.
        let window = inWindow()
        defer { withExtendedLifetime(window) {} }
        let long = (1...2000).map { "Line \($0)" }.joined(separator: "\n")
        open(long, caret: 0, path: "a.tex")
        editor.reveal(line: 1200, atTop: true, focus: false)
        let left = try #require(text.shownTop)
        open("short", path: "b.tex")
        open(long, path: "a.tex")
        #expect(text.shownTop?.offset == left.offset && text.shownTop?.below == left.below)
        open("short", path: "b.tex")
        open(long + "\nmore", path: "a.tex")
        let clip = try #require(editor.textView.enclosingScrollView?.contentView)
        #expect(clip.bounds.minY == -clip.contentInsets.top)
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
        #expect(text.offered == nil && text.undoManager?.undoActionName == "Completion")
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

    /// The editor's scroll view in a window.
    private func inWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
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

    /// An edit recolours the shown lines after it, which it can change: display maths opened
    /// above them makes a stray closing delimiter theirs.
    @Test func anEditRecoloursTheLinesBelowIt() async throws {
        let window = inWindow()
        defer { withExtendedLifetime(window) {} }
        open("a\nb\nxyz\n\\]", caret: 0)
        let colours = SyntaxTheme.overleaf.colours
        try await waitUntil { (try? self.colour(of: "]")) == colours.invalid }
        text.insertText("\\[\n", replacementRange: NSRange(location: 2, length: 0))
        try await waitUntil { (try? self.colour(of: "]")) == colours.maths }
        text.undoManager?.undo()
        try await waitUntil { (try? self.colour(of: "]")) == colours.invalid }
    }

    /// With Reduce Motion a bracket's partner is filled where it is, not bounced, until the caret next moves.
    @Test func reduceMotionMarksABracketsPartnerInPlace() throws {
        let window = inWindow()
        defer { withExtendedLifetime(window) {} }
        open("(a)", caret: 0)
        text.reducesMotion = { true }
        _ = try colour(of: "a")
        func filled() throws -> [Int] {
            let manager = try #require(text.textLayoutManager)
            var offsets: [Int] = []
            manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attributes, range in
                if attributes[.backgroundColor] != nil { offsets.append(self.text.offset(range.location)) }
                return true
            }
            return offsets
        }
        text.moveRight(nil)
        #expect(try filled() == [2])
        text.moveRight(nil)
        #expect(try filled() == [])
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
        try await waitUntil { (try? self.colour(of: "\\section")) == SyntaxTheme.system.colours.command } state: {
            "System: \(String(describing: try? self.colour(of: "\\section")))"
        }
        #expect(try renderedText() != before, "A theme change must repaint the already-visible text.")
        text.syntaxTheme = .overleaf
        try await waitUntil { (try? self.colour(of: "\\section")) == SyntaxTheme.overleaf.colours.command }
    }

    /// Every theme colour reaches the HIG's 4.5:1 on the text's background and on the current
    /// line's, the system's fill over it, and 7:1 with Increase Contrast, as little changed as
    /// that takes: one that has it already stays as it is.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
    func theThemesAreLegible(name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        // Its own reading of a colour, not the app's `resolved(in:)`, which made the colours under test.
        func resolved(_ color: NSColor) -> NSColor {
            var out = color
            appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
            return out
        }
        let background = resolved(.textBackgroundColor), fill = resolved(.secondarySystemFill)
        // The fill as the window server mixes it in: 235 on white, 48 on Dark's 30.
        func under(_ component: KeyPath<NSColor, CGFloat>) -> CGFloat {
            background[keyPath: component] * (1 - fill.alphaComponent) + fill[keyPath: component] * fill.alphaComponent
        }
        let currentLine = NSColor(srgbRed: under(\.redComponent), green: under(\.greenComponent), blue: under(\.blueComponent), alpha: 1)
        for theme in SyntaxTheme.allCases {
            let c = theme.colours
            // By the name: an Increase Contrast appearance made here is the plain one, the setting being off.
            for color in [c.command, c.keyword, c.argument, c.maths, c.comment, c.invalid].map({ $0.legibleAsText(in: name) }) {
                for ground in [background, currentLine] {
                    #expect(color.contrast(with: ground) >= ([.aqua, .darkAqua].contains(name) ? 4.5 : 7), "\(theme) \(color) on \(ground)")
                }
            }
        }
        // Overleaf's Light commands, at 8.6:1, are its own blue.
        if name == .aqua { #expect(resolved(SyntaxTheme.overleaf.colours.command) == NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) }
    }

    /// A double-click selects the word, as the system's does, and goes to the PDF, quietly; a click
    /// only places the caret.
    @Test func aDoubleClickGoesToThePDF() throws {
        let window = inWindow()
        open("one two", caret: 0)
        text.layoutSubtreeIfNeeded()
        var went: [Bool] = []
        text.forwardSync = { quietly in { went.append(quietly) } }
        let glyph = text.firstRect(forCharacterRange: NSRange(location: 4, length: 1), actualRange: nil)
        let point = window.convertPoint(fromScreen: NSPoint(x: glyph.minX + 1, y: glyph.midY))
        func event(_ type: NSEvent.EventType, clicks: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        // The release ends the text view's own tracking.
        NSApp.postEvent(try event(.leftMouseUp, clicks: 1), atStart: false)
        text.mouseDown(with: try event(.leftMouseDown, clicks: 1))
        #expect(went.isEmpty && text.selectedRange() == NSRange(location: 4, length: 0))
        NSApp.postEvent(try event(.leftMouseUp, clicks: 2), atStart: false)
        text.mouseDown(with: try event(.leftMouseDown, clicks: 2))
        #expect(went == [true] && text.selectedRange() == NSRange(location: 4, length: 3))
    }

    /// A click in the gutter selects its line, with Shift from the selection there was; on a
    /// line the build marked it also asks for the issue.
    @Test func aClickInTheGutterSelectsTheLine() throws {
        let window = inWindow()
        open("one\ntwo\nthree", caret: 0)
        text.layoutSubtreeIfNeeded()
        text.issueLines = [2: true]
        var asked: [Int] = []
        text.issueClicked = { asked.append($0) }
        func click(line: Int, shift: Bool = false) throws {
            let glyph = text.firstRect(forCharacterRange: NSRange(location: text.document.lineStart(line), length: 1), actualRange: nil)
            let inText = window.convertPoint(fromScreen: NSPoint(x: glyph.minX, y: glyph.midY))
            let point = NSPoint(x: text.convert(NSPoint(x: 5, y: 0), to: nil).x, y: inText.y)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? .shift : [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            // The release ends the tracking.
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            text.mouseDown(with: try event(.leftMouseDown))
        }
        try click(line: 1)
        #expect(text.selectedRange() == NSRange(location: 0, length: 4) && asked.isEmpty)
        try click(line: 3, shift: true)
        #expect(text.selectedRange() == NSRange(location: 0, length: 13))
        try click(line: 2)
        #expect(text.selectedRange() == NSRange(location: 4, length: 4) && asked == [2])
    }

    /// VoiceOver's rotors step through the file's headings and the lines with build issues, either
    /// way; an issue is named with what it says, where that's known, and found by it.
    @Test func theRotorsStepThroughHeadingsAndIssues() throws {
        open("a\n\\section{One}\nb\n\\section{Two}\nc", caret: 0)
        text.headings = { [(2, "One"), (4, "Two")] }
        text.issueLines = [3: true, 5: false]
        text.issueMessages = [3: "Undefined control sequence"]
        let rotors = text.accessibilityCustomRotors()
        let headings = try #require(rotors.first { $0.type == .heading }), issues = try #require(rotors.first { $0.type == .custom })
        #expect(issues.label == "Issues")
        func step(_ rotor: NSAccessibilityCustomRotor, from: NSAccessibilityCustomRotor.ItemResult?, next: Bool = true,
                  filter: String = "") -> NSAccessibilityCustomRotor.ItemResult? {
            let search = NSAccessibilityCustomRotor.SearchParameters()
            search.currentItem = from
            search.searchDirection = next ? .next : .previous
            search.filterString = filter
            return text.rotor(rotor, resultFor: search)
        }
        let one = try #require(step(headings, from: nil))
        #expect(one.customLabel == "One" && one.targetRange == NSRange(location: 2, length: 14))
        let two = try #require(step(headings, from: one))
        #expect(two.customLabel == "Two" && step(headings, from: two) == nil)
        #expect(step(headings, from: two, next: false)?.customLabel == "One")
        let error = try #require(step(issues, from: nil))
        #expect(error.customLabel == "Error on line 3: Undefined control sequence")
        #expect(step(issues, from: error)?.customLabel == "Warning on line 5")
        #expect(step(issues, from: nil, filter: "undefined")?.targetRange == error.targetRange && step(issues, from: nil, filter: "missing") == nil)
    }

    /// The View menu's text size steps a point at a time and stops at the ends of Settings' range.
    @Test func theTextSizeStepsWithinItsRange() {
        let defaults = UserDefaults.standard, before = defaults.object(forKey: EditorPrefs.fontSizeKey)
        defer { defaults.set(before, forKey: EditorPrefs.fontSizeKey) }
        defaults.set(27, forKey: EditorPrefs.fontSizeKey)
        for (step, size) in [(1, 28), (1, 28), (-1, 27)] {
            EditorPrefs.stepFontSize(by: step)
            #expect(defaults.integer(forKey: EditorPrefs.fontSizeKey) == size)
        }
    }

    /// Go to Line…'s sheet puts the caret at its line's start.
    @Test func goToLinePutsTheCaretOnTheLine() {
        open((1...300).map { "line \($0)" }.joined(separator: "\n"), caret: 0)
        editor.reveal(line: 120, focus: false)
        #expect(editor.currentLine == 120 && editor.currentColumn == 0)
    }
}
