import AppKit
import Testing
@testable import TeXLocal

@MainActor
struct SourceEditorTests {
    private let editor = SourceEditor()
    private var text: SourceTextView { editor.textView }
    private let typed = NSRange(location: NSNotFound, length: 0)

    private func open(_ string: String, caret: Int? = nil, path: String = "main.tex") {
        editor.open(path: path, text: string, focus: false)
        text.setSelectedRange(NSRange(location: caret ?? (string as NSString).length, length: 0))
    }

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
        open("two, changed", path: "b.tex")
        open("elsewhere", path: "a.tex")
        #expect(text.undoManager !== a)
    }

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

    @Test func aTextViewOnItsOwnMirrorsItsEdits() {
        let view = SourceTextView.plainDocument()
        view.load("one")
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.string == "xone" && view.document.text == "xone")
    }

    @Test func bracketsCloseAndAreSteppedOver() {
        open("")
        text.insertText("{", replacementRange: typed)
        #expect(text.string == "{}" && text.selectedRange() == NSRange(location: 1, length: 0))
        text.insertText("}", replacementRange: typed)
        #expect(text.string == "{}" && text.selectedRange() == NSRange(location: 2, length: 0))
        open("x", caret: 0)
        text.insertText("(", replacementRange: typed)
        #expect(text.string == "(x")
        open("ab")
        text.setSelectedRange(NSRange(location: 0, length: 2))
        text.insertText("[", replacementRange: typed)
        #expect(text.string == "[ab]" && text.selectedRange() == NSRange(location: 1, length: 2))
        open("")
        text.insertText("{", replacementRange: typed)
        text.deleteBackward(nil)
        #expect(text.string == "")
        open("{}", caret: 1)
        text.deleteBackward(nil)
        #expect(text.string == "}")
    }

    @Test func escapedBracketsCloseEscaped() {
        open("\\")
        text.insertText("[", replacementRange: typed)
        #expect(text.string == "\\[\\]" && text.selectedRange() == NSRange(location: 2, length: 0))
        text.insertText("x", replacementRange: typed)
        text.insertText("\\", replacementRange: typed)
        text.insertText("]", replacementRange: typed)
        #expect(text.string == "\\[x\\]" && text.selectedRange() == NSRange(location: 5, length: 0))
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
        open("  a{}", caret: 4)
        text.insertNewline(nil)
        #expect(text.string == "  a{\n  \n  }" && text.selectedRange().location == 7)
        open("x", caret: 0)
        text.insertTab(nil)
        #expect(text.string == "  x")
        text.insertBacktab(nil)
        #expect(text.string == "x")
        open("     y", caret: 5)
        text.deleteBackward(nil)
        #expect(text.string == "    y")
    }

    struct Step: Sendable {
        enum Command: Sendable { case comment, bold, italic }
        let text: String, selection: NSRange, command: Command, result: String, selected: NSRange
    }

    @Test(arguments: [
        Step(text: "a\n  b", selection: NSRange(location: 0, length: 5), command: .comment,
             result: "% a\n%   b", selected: NSRange(location: 2, length: 7)),
        Step(text: "word", selection: NSRange(location: 0, length: 4), command: .bold,
             result: "\\textbf{word}", selected: NSRange(location: 8, length: 4)),
        Step(text: "a \\textit{b \\textbf{word} c} d", selection: NSRange(location: 20, length: 4), command: .bold,
             result: "a \\textit{b word c} d", selected: NSRange(location: 12, length: 4)),
        Step(text: "a \\textit{b \\underline{word} c} d", selection: NSRange(location: 11, length: 0), command: .italic,
             result: "a b \\underline{word} c d", selected: NSRange(location: 3, length: 0)),
    ])
    func aCommandIsOneUndoStepThatKeepsTheSelection(_ step: Step) {
        open(step.text)
        text.setSelectedRange(step.selection)
        let command: EditorCommand = switch step.command {
        case .comment: .comment
        case .bold: .bold
        case .italic: .italic
        }
        #expect(editor.perform(command))
        #expect(text.string == step.result && text.selectedRange() == step.selected)
        #expect(editor.document?.text == text.string)
        text.undoManager?.undo()
        #expect(text.string == step.text)
        #expect(editor.document?.text == text.string)
        text.undoManager?.redo()
        #expect(text.string == step.result)
        #expect(editor.document?.text == text.string)
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
        #expect(text.undoManager?.undoActionName == "Insert")
        open("")
        #expect(editor.perform(.block, "figure", title: "Figure"))
        #expect(text.undoManager?.undoActionName == "Insert Figure")
    }

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

    /// TextKit 2 estimates what's above a revealed line, and a new width changes that; lines wrap at once, at the width AppKit's tracking gives as a live resize ends.
    @Test func aRevealedLineStaysAtTheTop() {
        // Held to the end: the text lays out in it.
        let window = inWindow()
        defer { withExtendedLifetime(window) {} }
        open((1...2000).map { "\\section{Line \($0)} " + String(repeating: "word ", count: $0 % 40) }.joined(separator: "\n"), caret: 0)
        func top(_ line: Int) -> CGFloat? {
            let clip = editor.textView.enclosingScrollView!.contentView
            return text.textRange(NSRange(location: text.document.lineStart(line), length: 0))
                .flatMap { text.textLayoutManager?.textLayoutFragment(for: $0.location) }
                .map { $0.layoutFragmentFrame.minY + text.textContainerOrigin.y - clip.bounds.minY - clip.contentInsets.top }
        }
        editor.reveal(line: 1700, atTop: true, focus: false)
        #expect(top(1700) == 0, "Actual top: \(String(describing: top(1700)))")
        editor.textView.enclosingScrollView!.setFrameSize(NSSize(width: 350, height: 400))
        #expect(top(1700) == 0, "Actual top: \(String(describing: top(1700)))")
        #expect(text.textContainer?.size.width == text.frame.width - 2 * text.textContainerInset.width)
    }

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

    @Test func linesMoveUpAndDown() throws {
        open("a\nb\nc\nd", caret: 2)
        #expect(editor.perform(.moveLineUp))
        #expect(text.string == "b\na\nc\nd" && text.selectedRange() == NSRange(location: 0, length: 0))
        #expect(!editor.perform(.moveLineUp))
        #expect(text.string == "b\na\nc\nd")
        text.setSelectedRange(NSRange(location: 4, length: 1))
        #expect(editor.perform(.moveLineDown))
        #expect(text.string == "b\na\nd\nc" && text.selectedRange() == NSRange(location: 6, length: 1))
        #expect(!editor.perform(.moveLineDown))
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

    @Test func severalSelectionsMoveTogether() {
        open("1\n2\n3\n4\n5\n6", caret: 0)
        text.setSelectedRanges([NSValue(range: NSRange(location: 2, length: 4)), NSValue(range: NSRange(location: 8, length: 1))],
                               affinity: .downstream, stillSelecting: false)
        #expect(editor.perform(.moveLineUp))
        #expect(text.string == "2\n3\n1\n5\n4\n6")
        #expect(text.selectedRanges.map(\.rangeValue) == [NSRange(location: 0, length: 4), NSRange(location: 6, length: 1)])
        #expect(text.document.text == text.string)
    }

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

    @Test(.timeLimit(.minutes(1)))
    func completionsFillTheirFields() throws {
        open("  \\beg")
        text.complete(nil)
        let offered = try #require(text.offered)
        #expect(offered.start == 2 && offered.items.first?.label == "\\begin")
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(text.offered == nil && text.undoManager?.undoActionName == "Completion")
        #expect(text.string == "  \\begin{env}\n    \n  \\end{env}")
        #expect(text.selectedRange() == NSRange(location: 9, length: 3))
        text.insertText("itemize", replacementRange: typed)
        #expect(text.string == "  \\begin{itemize}\n    \n  \\end{itemize}")
        text.insertTab(nil)
        #expect(text.selectedRange() == NSRange(location: 22, length: 0))
        text.insertTab(nil)
        #expect(text.string == "  \\begin{itemize}\n      \n  \\end{itemize}")
        #expect(text.document.text == text.string)
    }

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
        text.complete(nil)
        let second = try #require(text.offered?.items[1])
        text.doCommand(by: #selector(NSResponder.moveDown(_:)))
        text.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(text.string == second.text)
        open("\\be")
        text.complete(nil)
        text.insertText(" ", replacementRange: typed)
        #expect(text.offered == nil && text.string == "\\be ")
        open("\\be")
        text.complete(nil)
        #expect(text.offered != nil)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(text.offered == nil)
    }

    /// The session's autosave waits while marked (IME) text shows; the text itself is the mirror's at every step.
    @Test func markedTextIsToldAsItComesAndGoes() {
        open("start")
        var told: [Bool] = []
        text.composing = { told.append($0) }
        text.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: typed)
        text.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0), replacementRange: typed)
        #expect(told == [true] && text.string == "startあい" && text.document.text == text.string)
        text.unmarkText()
        #expect(told == [true, false] && !text.hasMarkedText())
        text.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: typed)
        text.insertText("亜", replacementRange: typed)
        #expect(told == [true, false, true, false] && !text.hasMarkedText())
        #expect(text.string == "startあい亜" && text.document.text == text.string)
    }

    @Test func switchingFilesDuringCompositionKeepsUndoWithItsOwnText() {
        open("first", path: "a.tex")
        text.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: typed)

        open("second", path: "b.tex")
        #expect(!text.hasMarkedText())
        #expect(editor.document?.text == "second" && text.document.text == "second")
        #expect(text.undoManager?.canUndo == false)
        // The old undo referred to provisional text that wasn't saved to a.tex.
        open("first", path: "a.tex")
        text.undoManager?.undo()
        #expect(text.string == "first" && editor.document?.text == "first")
    }

    @Test func spellingIsTheProses() {
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
        afterwrod \\emph{emphwrod} \\label{sec:labelwrod} \\cite[see]{citewrod} \\usepackage[utf8]{pkgwrod} \\includegraphics{filewrod.pdf}
        """
        open(source)
        let string = source as NSString
        let start = string.range(of: "mathwrod").location
        let checked = NSRange(location: start, length: string.length - start)
        let words = ["mathwrod", "prosewrod", "commentwrod", "naïvve", "dollarwrod", "verbwrod", "codewrod", "afterwrod", "emph",
                     "emphwrod", "labelwrod", "citewrod", "pkgwrod", "filewrod"]
        let relative = { (word: String) in
            let range = string.range(of: word)
            return NSRange(location: range.location - checked.location, length: range.length)
        }
        let results = words.flatMap { word in
            [NSTextCheckingResult.spellCheckingResult(range: relative(word)),
             NSTextCheckingResult.correctionCheckingResult(range: relative(word), replacementString: "word"),
             NSTextCheckingResult.replacementCheckingResult(range: relative(word), replacementString: "word")]
        }
        let kept = editor.textView(text, didCheckTextIn: checked, types: NSTextCheckingAllTypes, options: [:], results: results,
                                   orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: words.count)
        let prose = ["prosewrod", "commentwrod", "naïvve", "afterwrod", "emphwrod"]
        #expect(kept.map(\.range) == prose.flatMap { Array(repeating: relative($0), count: 3) })
        #expect(kept.map(\.resultType) == prose.flatMap { _ in [.spelling, .correction, .replacement] })
    }

    private func inWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.shown = true
        return window
    }

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

    @Test func newLinesAreColoured() async throws {
        // Held to the end: the text lays out in it.
        let window = inWindow()
        defer { withExtendedLifetime(window) {} }
        open("x")
        text.insertText("\n\\section", replacementRange: typed)
        try await waitUntil { (try? self.colour(of: "\\section")) == SyntaxTheme.overleaf.colours.command }
    }

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
            for color in [c.command, c.argument, c.maths, c.comment, c.invalid].map({ $0.legibleAsText(in: name) }) {
                for ground in [background, currentLine] {
                    #expect(color.contrast(with: ground) >= ([.aqua, .darkAqua].contains(name) ? 4.5 : 7), "\(theme) \(color) on \(ground)")
                }
            }
        }
        if name == .aqua { #expect(resolved(SyntaxTheme.overleaf.colours.command) == NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) }
    }

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

    @Test func aClickInTheGutterSelectsTheLine() throws {
        let window = inWindow()
        open("one\ntwo\nthree", caret: 0)
        text.layoutSubtreeIfNeeded()
        text.issueLines = [2: .init(isError: true, message: "Missing $ inserted")]
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

    @Test func anIssuesBoxFitsItsRoom() throws {
        let font = NSFont.systemFont(ofSize: 13), symbol = try #require(NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil))
        let box = IssueMessageView()
        box.show("Paragraph ended before \\section was\n  complete", others: 0, symbol: symbol, font: font)
        let whole = try #require(box.fit(in: 1000))
        #expect(!whole.cut && whole.width == whole.width.rounded())
        let cut = try #require(box.fit(in: whole.width - 40))
        #expect(cut.cut && cut.width == (whole.width - 40).rounded(.down))
        let alone = try #require(box.fit(in: 40))
        #expect(alone.cut && alone.width < 40)
        #expect(box.fit(in: alone.width - 1) == nil)
        box.show("Paragraph ended before \\section was complete", others: 2, symbol: symbol, font: font)
        #expect(try #require(box.fit(in: 1000)).width > whole.width)
    }

    private func layOut(width: CGFloat? = nil) throws {
        if let width { editor.scrollView.frame.size.width = width }
        editor.scrollView.layoutSubtreeIfNeeded()
        try #require(text.textLayoutManager).textViewportLayoutController.layoutViewport()
    }

    @Test func anIssuesMessageIsAtItsLinesEnd() throws {
        let window = inWindow()
        defer { withExtendedLifetime(window) {} }
        open("one\nUse \\foo here.\n", caret: 0)
        text.issueLines = [2: .init(isError: true, message: "Undefined control sequence: \\foo")]
        try layOut()
        let row = try #require(text.issueRows.first)
        let message = try #require(row.message)
        #expect(row.line == 2 && message.view.superview === text && message.rect.maxX == row.band.maxX - 1)
    }

    @Test func aClickOnAnIssuesMessageShowsTheIssue() throws {
        let window = inWindow()
        open("one\ntwo\nthree", caret: 5)
        text.issueLines = [2: .init(isError: true, message: "Missing $ inserted")]
        try layOut()
        var asked: [Int] = []
        text.issueClicked = { asked.append($0) }
        let message = try #require(text.issueRows.first?.message).rect
        func event(_ type: NSEvent.EventType, at point: NSPoint, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: text.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let inside = NSPoint(x: message.midX, y: message.midY)
        // The release ends the tracking.
        NSApp.postEvent(try event(.leftMouseUp, at: NSPoint(x: message.minX - 20, y: message.midY)), atStart: false)
        text.mouseDown(with: try event(.leftMouseDown, at: inside))
        #expect(asked.isEmpty)
        NSApp.postEvent(try event(.leftMouseUp, at: inside), atStart: false)
        text.mouseDown(with: try event(.leftMouseDown, at: inside))
        #expect(asked == [2] && text.selectedRange() == NSRange(location: 5, length: 0))
        NSApp.postEvent(try event(.leftMouseUp, at: inside, .shift), atStart: false)
        text.mouseDown(with: try event(.leftMouseDown, at: inside, .shift))
        #expect(asked == [2] && text.selectedRange() == NSRange(location: 5, length: 2))
        text.setSelectedRange(NSRange(location: 5, length: 0))
        let above = NSPoint(x: text.textContainerOrigin.x + 20, y: message.midY - message.height)
        NSApp.postEvent(try event(.leftMouseDragged, at: above), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, at: above), atStart: false)
        text.mouseDown(with: try event(.leftMouseDown, at: inside))
        #expect(asked == [2] && NSMaxRange(text.selectedRange()) == 7 && (1...3).contains(text.selectedRange().location))
    }

    @Test func theRotorsStepThroughHeadingsAndIssues() throws {
        open("a\n\\section{One}\nb\n\\section{Two}\nc", caret: 0)
        text.headings = { [(2, "One"), (4, "Two")] }
        text.issueLines = [3: .init(isError: true, message: "Undefined control sequence"), 5: .init(isError: false, message: "Marked")]
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
        #expect(step(issues, from: error)?.customLabel == "Warning on line 5: Marked")
        #expect(step(issues, from: nil, filter: "undefined")?.targetRange == error.targetRange && step(issues, from: nil, filter: "missing") == nil)
    }
}
