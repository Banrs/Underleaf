import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

struct SourceEditorTests {
    private let editor = SourceEditor()
    private var text: SourceTextView { editor.textView }
    private let typed = NSRange(location: NSNotFound, length: 0)
    /// The window the text lays out in, held to the test's end.
    private let held = Held()
    private final class Held { var window: NSWindow? }

    private func open(_ string: String, caret: Int? = nil, path: String = "main.tex") {
        editor.open(path: path, text: string, focus: false)
        text.setSelectedRange(NSRange(location: caret ?? (string as NSString).length, length: 0))
    }

    /// Each key as the keyboard types it.
    private func type(_ keys: String...) {
        for key in keys { text.insertText(key, replacementRange: typed) }
    }

    /// An "x" typed in a.tex's "one", then b.tex's "two" opened: a.tex's undo.
    private func typedInA() throws -> UndoManager {
        open("one", caret: 0, path: "a.tex")
        type("x")
        let undo = try #require(text.undoManager)
        open("two", path: "b.tex")
        return undo
    }

    @Test func eachFileKeepsItsUndo() throws {
        let a = try typedInA()
        #expect(text.undoManager !== a && text.undoManager?.canUndo == false)
        open("xone", path: "a.tex")
        #expect(text.undoManager === a)
        text.undoManager?.undo()
        #expect(text.string == "one")
        open("two, changed", path: "b.tex")
        open("elsewhere", path: "a.tex")
        #expect(text.undoManager !== a)
    }

    @Test func aRenameOntoAFileGoneElsewhereKeepsItsUndo() throws {
        let a = try typedInA()
        open("main", path: "main.tex")
        // b.tex deleted in the Finder, so its kept state stays; a.tex takes its name.
        editor.rename(from: "a.tex", to: "b.tex")
        open("xone", path: "b.tex")
        #expect(text.undoManager === a)
    }

    /// The mirror keeps a U+0000 the editor keeps, and the offsets after it (#24), and gives it back in its text.
    @Test func aNulCharacterKeepsTheMirrorInStep() {
        let document = SourceDocument(text: "a\u{0}\nb")
        #expect(document.lineCount == 2)
        #expect(document.edit(NSRange(location: 4, length: 0), with: "\u{0}\nc", changing: nil, mirroring: false).isEmpty)
        #expect(document.lineCount == 3 && document.lineStart(3) == 6 && document.text == "a\u{0}\nb\u{0}\nc")
    }

    @Test func aTextViewOnItsOwnMirrorsItsEdits() {
        let view = SourceTextView.plainDocument()
        view.load("one")
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.string == "xone" && view.document.text == "xone")
    }

    /// Each key goes through the core, which closes brackets and steps over them, keeps the indentation and indents by Tab.
    @Test func typingIsTheCores() {
        open("")
        type("{")
        #expect(text.string == "{}" && text.selectedRange() == NSRange(location: 1, length: 0))
        type("}")
        #expect(text.string == "{}" && text.selectedRange() == NSRange(location: 2, length: 0))
        open("ab")
        text.setSelectedRange(NSRange(location: 0, length: 2))
        type("[")
        #expect(text.string == "[ab]" && text.selectedRange() == NSRange(location: 1, length: 2))
        open("")
        type("{")
        text.deleteBackward(nil)
        #expect(text.string == "")
        // A closer put in as \]: its bracket steps over both, and the backslash typed for it goes.
        open("\\")
        type("[", "x", "\\", "]")
        #expect(text.string == "\\[x\\]" && text.selectedRange() == NSRange(location: 5, length: 0))
        open("  a{}", caret: 4)
        text.insertNewline(nil)
        #expect(text.string == "  a{\n  \n  }" && text.selectedRange().location == 7)
        open("x", caret: 0)
        text.insertTab(nil)
        #expect(text.string == "  x")
        text.insertBacktab(nil)
        #expect(text.string == "x" && text.document.text == text.string)
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
        text.autoPair = false
        text.autoComplete = false
        open("")
        type("{")
        #expect(text.string == "{")
        open("{}", caret: 1)
        text.deleteBackward(nil)
        #expect(text.string == "}")
        open("\\")
        type("b")
        #expect(text.offered == nil)
        text.complete(nil)
        let all = try #require(text.offered).items.count
        type("e")
        #expect(try #require(text.offered).items.count < all)
    }

    struct Step: Sendable {
        let text: String, selection: NSRange, command: EditorCommand, result: String, selected: NSRange
    }

    @Test(arguments: [
        Step(text: "a\n  b", selection: NSRange(location: 0, length: 5), command: .comment,
             result: "% a\n%   b", selected: NSRange(location: 2, length: 7)),
        Step(text: "word", selection: NSRange(location: 0, length: 4), command: .bold,
             result: "\\textbf{word}", selected: NSRange(location: 8, length: 4)),
        Step(text: "a \\textit{b \\textbf{word} c} d", selection: NSRange(location: 20, length: 4), command: .bold,
             result: "a \\textit{b word c} d", selected: NSRange(location: 12, length: 4)),
    ])
    func aCommandIsOneUndoStepThatKeepsTheSelection(_ step: Step) {
        open(step.text)
        text.setSelectedRange(step.selection)
        #expect(editor.perform(step.command))
        #expect(text.string == step.result && text.selectedRange() == step.selected && editor.document?.text == text.string)
        text.undoManager?.undo()
        #expect(text.string == step.text && editor.document?.text == text.string)
        text.undoManager?.redo()
        #expect(text.string == step.result && editor.document?.text == text.string)
    }

    @Test func blocksTabThroughTheirFields() {
        open("")
        #expect(editor.perform(.block(id: "figure")))
        let string = text.string as NSString
        #expect(text.selectedRange() == NSRange(location: string.range(of: "]{}").location + 2, length: 0))
        text.insertTab(nil)
        #expect(text.selectedRange().location == NSMaxRange(string.range(of: "\\caption{")))
        text.insertTab(nil)
        #expect(text.selectedRange().location == NSMaxRange(string.range(of: "fig:")) && text.undoManager?.undoActionName == "Insert")
        open("")
        #expect(editor.perform(.block(id: "figure", title: "Figure")))
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
        inWindow()
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
        inWindow()
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

    /// From here each `event` is a top-level undo group of its own, as AppKit groups an event's changes.
    private func groupingByEvent() throws -> UndoManager {
        let undo = try #require(text.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        return undo
    }

    private func event(_ action: () -> Void) {
        text.undoManager?.beginUndoGrouping()
        action()
        text.undoManager?.endUndoGrouping()
    }

    @Test func aCommandIsItsOwnUndoStep() throws {
        open("", caret: 0)
        let undo = try groupingByEvent()
        event { type("a") }
        event { type("b") }
        event { editor.perform(.bold) }
        #expect(undo.undoActionName == "Bold")
        event { type("c") }
        #expect(text.string == "ab\\textbf{c}")
        undo.undo()
        #expect(text.string == "ab\\textbf{}" && undo.undoActionName == "Bold")
        undo.undo()
        #expect(text.string == "ab" && text.document.text == text.string)
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
        let undo = try groupingByEvent()
        event { #expect(editor.perform(.moveLineUp)) }
        #expect(text.string == "b\na\nc\nd" && text.selectedRange() == NSRange(location: 4, length: 1))
        #expect(undo.undoActionName == "Move Line Up")
        undo.undo()
        #expect(text.string == "b\na\nd\nc" && text.document.text == text.string)
    }

    @Test func syncTeXGoesToTheWordAndTellsAUTF16Column() {
        open("Ünï words \\word, the word\nnext", caret: 1)
        editor.reveal(line: 1, column: 21, focus: false)
        #expect(text.selectedRange() == NSRange(location: 21, length: 4))
        open("before\n😀 echo echo echo\n", caret: 22, path: "b.tex")
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
        #expect(text.string == "  \\begin{env}\n    \n  \\end{env}" && text.selectedRange() == NSRange(location: 9, length: 3))
        type("itemize")
        #expect(text.string == "  \\begin{itemize}\n    \n  \\end{itemize}")
        text.insertTab(nil)
        #expect(text.selectedRange() == NSRange(location: 22, length: 0))
        text.insertTab(nil)
        #expect(text.string == "  \\begin{itemize}\n      \n  \\end{itemize}" && text.document.text == text.string)
    }

    @Test func theCompletionListTakesOnlyItsKeys() throws {
        open("\\")
        type("b")
        let all = try #require(text.offered).items.count
        type("e")
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
        type(" ")
        #expect(text.offered == nil && text.string == "\\be ")
        open("\\be")
        text.complete(nil)
        #expect(text.offered != nil)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(text.offered == nil)
    }

    /// The list is a view over the editor's text, and nothing in it takes the keyboard: a click chooses a row, and the
    /// text view goes on typing and moving through the rows.
    @Test func theCompletionListNeverTakesTheKeyboard() throws {
        inWindow()
        open("\\")
        type("b")
        _ = try #require(text.offered)
        let list = try #require(editor.scrollView.subviews.first { $0 is NSHostingView<CompletionRowsView> })
        list.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        #expect(all(list).count > 1 && !all(list).contains { $0.acceptsFirstResponder })
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
        type("亜")
        #expect(told == [true, false, true, false] && !text.hasMarkedText() && text.string == "startあい亜" && text.document.text == text.string)
    }

    @Test func switchingFilesDuringCompositionKeepsUndoWithItsOwnText() {
        open("first", path: "a.tex")
        text.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: typed)

        open("second", path: "b.tex")
        #expect(!text.hasMarkedText() && editor.document?.text == "second" && text.document.text == "second" && text.undoManager?.canUndo == false)
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

    @discardableResult
    private func inWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.shown = true
        held.window = window
        return window
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1,
                       _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    /// A press at `point` in the window: its release, posted first, ends the text view's own tracking.
    private func click(at point: NSPoint, releasedAt release: NSPoint? = nil, in window: NSWindow, clicks: Int = 1,
                       _ modifiers: NSEvent.ModifierFlags = []) throws {
        NSApp.postEvent(try mouse(.leftMouseUp, at: release ?? point, in: window, clicks: clicks, modifiers), atStart: false)
        text.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window, clicks: clicks, modifiers))
    }

    /// The shown text as drawn, which validates the shown fragments' colours.
    private func drawn() throws -> NSBitmapImageRep {
        let bitmap = try #require(text.bitmapImageRepForCachingDisplay(in: text.visibleRect))
        text.cacheDisplay(in: text.visibleRect, to: bitmap)
        return bitmap
    }

    private func colour(of word: String) throws -> NSColor? {
        let manager = try #require(text.textLayoutManager)
        text.layoutSubtreeIfNeeded()
        manager.textViewportLayoutController.layoutViewport()
        _ = try drawn()
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
        return try #require(drawn().tiffRepresentation)
    }

    /// Until `word` is drawn in `expected`; a timeout says what it was.
    private func waitUntilColoured(_ word: String, _ expected: NSColor) async throws {
        try await waitUntil { (try? self.colour(of: word)) == expected } state: { "\(word): \(String(describing: try? self.colour(of: word)))" }
    }

    @Test func newLinesAreColoured() async throws {
        inWindow()
        open("x")
        type("\n\\section")
        try await waitUntilColoured("\\section", SyntaxTheme.overleaf.color(.command))
    }

    @Test func anEditRecoloursTheLinesBelowIt() async throws {
        inWindow()
        open("a\nb\nxyz\n\\]", caret: 0)
        let theme = SyntaxTheme.overleaf
        try await waitUntilColoured("]", theme.color(.invalid))
        text.insertText("\\[\n", replacementRange: NSRange(location: 2, length: 0))
        try await waitUntilColoured("]", theme.color(.mathDelimiter))
        text.undoManager?.undo()
        try await waitUntilColoured("]", theme.color(.invalid))
    }

    @Test func reduceMotionMarksABracketsPartnerInPlace() throws {
        inWindow()
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
        let window = inWindow()
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.close() }
        open("\\section{A} % note")
        #expect(SyntaxTheme.all.map(\.id) == ["overleaf", "texstudio", "system"] && SyntaxTheme(rawValue: "gone") == nil)
        let texstudio = try #require(SyntaxTheme(rawValue: "texstudio")), system = try #require(SyntaxTheme(rawValue: "system"))
        text.syntaxTheme = texstudio
        try await waitUntilColoured("\\section", texstudio.color(.command))
        #expect(try colour(of: "% note") == texstudio.color(.comment))
        let before = try renderedText()
        text.syntaxTheme = system
        try await waitUntilColoured("\\section", system.color(.command))
        #expect(try renderedText() != before, "A theme change must repaint the already-visible text.")
        text.syntaxTheme = .overleaf
        try await waitUntilColoured("\\section", SyntaxTheme.overleaf.color(.command))
    }

    @Test func aDoubleClickGoesToThePDF() throws {
        let window = inWindow()
        open("one two", caret: 0)
        text.layoutSubtreeIfNeeded()
        var went: [Bool] = []
        text.forwardSync = { quietly in { went.append(quietly) } }
        let glyph = text.firstRect(forCharacterRange: NSRange(location: 4, length: 1), actualRange: nil)
        let point = window.convertPoint(fromScreen: NSPoint(x: glyph.minX + 1, y: glyph.midY))
        try click(at: point, in: window)
        #expect(went.isEmpty && text.selectedRange() == NSRange(location: 4, length: 0))
        try click(at: point, in: window, clicks: 2)
        #expect(went == [true] && text.selectedRange() == NSRange(location: 4, length: 3))
    }

    @Test func aClickInTheGutterSelectsTheLine() throws {
        let window = inWindow()
        open("one\ntwo\nthree", caret: 0)
        text.layoutSubtreeIfNeeded()
        text.issueLines = [2: .init(isError: true, message: "Missing $ inserted", short: "Missing $ inserted")]
        var asked: [Int] = []
        text.issueClicked = { asked.append($0) }
        func click(line: Int, shift: Bool = false) throws {
            let glyph = text.firstRect(forCharacterRange: NSRange(location: text.document.lineStart(line), length: 1), actualRange: nil)
            let inText = window.convertPoint(fromScreen: NSPoint(x: glyph.minX, y: glyph.midY))
            try self.click(at: NSPoint(x: text.convert(NSPoint(x: 5, y: 0), to: nil).x, y: inText.y), in: window, shift ? .shift : [])
        }
        try click(line: 1)
        #expect(text.selectedRange() == NSRange(location: 0, length: 4) && asked.isEmpty)
        try click(line: 3, shift: true)
        #expect(text.selectedRange() == NSRange(location: 0, length: 13))
        try click(line: 2)
        #expect(text.selectedRange() == NSRange(location: 4, length: 4) && asked == [2])
    }

    /// An issue's message is whole where there is room for it and cut at its tail, by the box, where there isn't, down to
    /// ten of its characters. An undefined command's is set in fewer words before it is cut, so that the name is kept.
    @Test func anIssuesMessageFitsItsRoom() {
        let font = NSFont.systemFont(ofSize: 12)
        func width(_ string: String) -> CGFloat { (string as NSString).size(withAttributes: [.font: font]).width }
        let message = "Paragraph ended before \\section was complete"
        let label = IssueLabel(message, compact: nil, font: font)
        #expect(abs(label.width - width(message)) < 0.01)
        let whole = label.text(in: label.width)
        #expect(whole?.cut == false && whole?.width == label.width)
        let cut = label.text(in: label.width - 1)
        #expect(cut?.cut == true && cut?.width == nil && cut?.text == message)
        #expect(label.text(in: width("Paragraph…") + 1)?.text == message)
        #expect(label.text(in: width("Paragra…") + 1) == nil && label.text(in: 0) == nil && label.text(in: -40) == nil)
        #expect(IssueLabel("Too short", compact: nil, font: font).text(in: width("Too sh")) == nil)
        let undefined = IssueLabel("Undefined control sequence: \\undefinedmacro", compact: "Undefined: \\undefinedmacro", font: font)
        #expect(undefined.text(in: undefined.width)?.cut == false)
        let short = undefined.text(in: undefined.width - 1)
        #expect(short?.text == "Undefined: \\undefinedmacro" && short?.width != nil)
        let shortCut = undefined.text(in: width("Undefined: \\undefin…") + 1)
        #expect(shortCut?.text == "Undefined: \\undefinedmacro" && shortCut?.width == nil)
    }

    private func layOut(width: CGFloat? = nil) throws {
        if let width { editor.scrollView.frame.size.width = width }
        editor.scrollView.layoutSubtreeIfNeeded()
        try #require(text.textLayoutManager).textViewportLayoutController.layoutViewport()
    }

    /// A line with an issue has its symbol and what it says in a box at the end of its first wrapped line, a point inside
    /// its band's end; a narrower pane cuts the words short, then leaves the symbol alone, then nothing, with a help tag's
    /// words for what isn't shown. An undefined command is underlined where it stands.
    @Test func anIssuesMessageIsAtItsLinesEnd() throws {
        let window = inWindow()
        // The core's: where the line has the command (crates/texlocal-core's `command_ranges`).
        let undefined = SourceTextView.LineIssue(isError: true, message: "Undefined control sequence: \\foo",
                                                 short: "Undefined control sequence: \\foo", compact: "Undefined: \\foo",
                                                 tokens: [NSRange(location: 4, length: 4), NSRange(location: 19, length: 4)])
        open("one\nUse \\foo here, and \\foo there.\n\n", caret: 0)
        text.issueLines = [1: .init(isError: false, message: "Marked", short: "Marked"), 2: undefined,
                           4: .init(isError: true, message: "Emergency stop", short: "Emergency stop", others: ["Missing \\begin{document}"])]
        try layOut()
        let padding = try #require(text.textContainer).lineFragmentPadding
        let digit = ("0" as NSString).size(withAttributes: [.font: try #require(text.font)]).width
        let font = NSFont.systemFont(ofSize: 13)
        var rows = text.issueRows
        // The last line is the document's empty one, laid out with the paragraph before it.
        #expect(rows.map(\.line) == [1, 2, 4] && rows.map(\.isError) == [false, true, true])
        for row in rows {
            let message = try #require(row.message)
            #expect(!message.cut && message.rect.maxX == row.band.maxX - 1 && message.rect.minY == row.band.minY)
            #expect(row.band.contains(message.rect) && message.view.superview === text && message.view.frame == message.rect)
            // It takes no click.
            #expect(text.hitTest(text.convert(NSPoint(x: message.rect.midX, y: message.rect.midY), to: text.superview)) === text)
        }
        #expect(rows[0].tip == nil && rows[1].tip == nil && rows[2].tip == "Emergency stop\nMissing \\begin{document}")
        // Two issues on a line: Xcode's count before the symbol, in a wider segment.
        let stop = ("Emergency stop" as NSString).size(withAttributes: [.font: font]).width
        #expect(abs(try #require(rows[2].message).rect.width - IssueBox.Metrics.width(ofText: stop, font: font, issues: 2)) < 0.01)
        // Xcode 27's boxes at 13 pt for its message "Cannot convert value of type 'String' to specified type 'Int'"
        // (353.74 pt), as measured: 406 pt alone, 418 with a count.
        let xcode = 353.7421875 as CGFloat
        #expect(IssueBox.Metrics.width(ofText: xcode, font: font, issues: 1) == 406 && IssueBox.Metrics.width(ofText: xcode, font: font, issues: 2) == 418)
        // Both places the command stands, each four characters wide to the pixel, and none for the other lines.
        let pixel = 1 / window.backingScaleFactor
        #expect(rows.map(\.tokens.count) == [0, 2, 0] && rows[1].tokens.allSatisfy { abs($0.width - 4 * digit) <= pixel })
        let start = text.textContainerOrigin.x + padding
        #expect(abs(rows[1].tokens[0].minX - (start + 4 * digit)) <= pixel / 2 && abs(rows[1].tokens[1].minX - (start + 19 * digit)) <= pixel / 2)
        // Narrower: the second line's message is in fewer words, its box taking all the room from a character after its
        // text, on whole points, as Xcode's, in the view it had.
        try layOut(width: 520)
        let views = rows.map { $0.message?.view }
        rows = text.issueRows
        let cut = try #require(rows[1].message)
        #expect(cut.cut && cut.rect.maxX == rows[1].band.maxX - 1 && cut.rect.width == cut.rect.width.rounded())
        #expect(cut.rect.minX >= start + 31 * digit && cut.rect.minX < start + 31 * digit + 1 && cut.view === views[1])
        #expect(rows[1].tip == "Undefined control sequence: \\foo" && rows[0].message?.cut == false)
        // Room for the symbol and not for words: the symbol alone, and the help tag's words.
        open("one\nUse \\foo here, and \\foo there, to the edge\n", caret: 0)
        text.issueLines = [2: undefined]
        try layOut(width: 480)
        let alone = try #require(text.issueRows.first?.message)
        #expect(alone.cut && alone.rect.width == IssueBox.Metrics.width(ofText: nil, font: font, issues: 1) && text.issueRows.first?.tip != nil)
        // No room: the band is left, and the help tag's words.
        open("one\nUse \\foo here, and \\foo there, to the edge\n", caret: 0)
        text.issueLines = [2: undefined]
        try layOut(width: 420)
        rows = text.issueRows
        #expect(rows.count == 1 && rows[0].message == nil && rows[0].tip == "Undefined control sequence: \\foo" && rows[0].tokens.count == 2)
        #expect(!text.subviews.contains { $0 is IssueMessageView })
    }

    @Test func aClickOnAnIssuesMessageShowsTheIssue() throws {
        let window = inWindow()
        open("one\ntwo\nthree", caret: 5)
        text.issueLines = [2: .init(isError: true, message: "Missing $ inserted", short: "Missing $ inserted")]
        try layOut()
        var asked: [Int] = []
        text.issueClicked = { asked.append($0) }
        let message = try #require(text.issueRows.first?.message).rect
        // In the window's coordinates.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { text.convert(NSPoint(x: x, y: y), to: nil) }
        let inside = point(message.midX, message.midY)
        try click(at: inside, releasedAt: point(message.minX - 20, message.midY), in: window)
        #expect(asked.isEmpty)
        try click(at: inside, in: window)
        #expect(asked == [2] && text.selectedRange() == NSRange(location: 5, length: 0))
        try click(at: inside, in: window, .shift)
        #expect(asked == [2] && text.selectedRange() == NSRange(location: 5, length: 2))
        text.setSelectedRange(NSRange(location: 5, length: 0))
        let above = point(text.textContainerOrigin.x + 20, message.midY - message.height)
        NSApp.postEvent(try mouse(.leftMouseDragged, at: above, in: window), atStart: false)
        try click(at: inside, releasedAt: above, in: window)
        #expect(asked == [2] && NSMaxRange(text.selectedRange()) == 7 && (1...3).contains(text.selectedRange().location))
    }

    @Test func theRotorsStepThroughHeadingsAndIssues() throws {
        open("a\n\\section{One}\nb\n\\section{Two}\nc", caret: 0)
        text.headings = { [(2, "One"), (4, "Two")] }
        text.issueLines = [3: .init(isError: true, message: "Undefined control sequence", short: "Undefined control sequence"),
                           5: .init(isError: false, message: "Marked", short: "Marked")]
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
