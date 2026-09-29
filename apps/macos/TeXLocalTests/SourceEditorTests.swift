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
    /// text as CodeMirror's does: text put in at its start goes before it.
    @Test func commentsToggleAsOneStep() {
        open("a\n  b")
        text.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(editor.perform(.comment))
        // At the least indentation of the lines, as CodeMirror puts it.
        #expect(text.string == "% a\n%   b")
        #expect(text.selectedRange() == NSRange(location: 2, length: 7))
        text.undoManager?.undo()
        #expect(text.string == "a\n  b")
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

    /// A chosen completion goes in as its snippet: typed in one place, a
    /// field is typed in all of its places, and Tab goes to the next.
    @Test func completionsFillTheirFields() throws {
        open("  \\beg")
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
        #expect(text.document.text() == text.string)
    }

    /// Misspellings count in the prose and comments, not in commands, labels
    /// or maths; the results are relative to the range checked.
    @Test func spellingIsTheProses() {
        let line = "x \\emph{wrod} \\label{sec:wrod} $wrod$ % wrod"
        open(line)
        let checked = NSRange(location: 2, length: (line as NSString).length - 2)
        let text = line as NSString
        let misspelt = ["emph", "wrod"].flatMap { word in
            var ranges: [NSRange] = [], from = checked.location
            while case let r = text.range(of: word, range: NSRange(location: from, length: text.length - from)), r.location != NSNotFound {
                ranges.append(NSRange(location: r.location - checked.location, length: r.length))
                from = NSMaxRange(r)
            }
            return ranges
        }
        let results = misspelt.map { NSTextCheckingResult.spellCheckingResult(range: $0) }
        let kept = editor.textView(self.text, didCheckTextIn: checked, types: NSTextCheckingAllTypes, options: [:], results: results,
                                   orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 6)
        // The emphasised word and the comment's.
        #expect(kept.map { text.substring(with: NSRange(location: $0.range.location + checked.location, length: $0.range.length)) } == ["wrod", "wrod"])
        #expect(kept.map { $0.range.location + checked.location } == [8, 40])
    }

    @Test func findSelectsAsYouTypeAndReplaces() {
        var reported = FindMatches()
        editor.onFindMatches = { reported = $0 }
        open("a b a b a", caret: 1)
        editor.setFind(FindQuery(search: "a", replace: "c"))
        #expect(text.selectedRange() == NSRange(location: 4, length: 1))
        #expect(reported == FindMatches(index: 2, total: 3))
        editor.findStep(1)
        #expect(text.selectedRange() == NSRange(location: 8, length: 1))
        editor.findStep(1)
        #expect(text.selectedRange() == NSRange(location: 0, length: 1))
        editor.replace(all: false)
        #expect(text.string == "c b a b a" && text.selectedRange() == NSRange(location: 4, length: 1))
        editor.replace(all: true)
        #expect(text.string == "c b c b c")
        #expect(reported.total == 0)
        // Replace All is one undo step.
        open("a a", path: "other.tex")
        editor.replace(all: true)
        #expect(text.string == "c c")
        text.undoManager?.undo()
        #expect(text.string == "a a")
    }
}
