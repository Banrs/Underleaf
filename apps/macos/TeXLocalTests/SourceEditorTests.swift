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
        text.setSelectedRange(.caret(caret ?? (string as NSString).length))
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
        #expect(document.edit(.caret(4), with: "\u{0}\nc", changing: nil, mirroring: false).isEmpty)
        #expect(document.lineCount == 3 && document.lineStart(3) == 6 && document.text == "a\u{0}\nb\u{0}\nc")
    }

    /// Each key goes through the core (whose rules are its own tests'): a bracket, a newline, Tab.
    @Test func typingIsTheCores() {
        open("")
        type("{", "}")
        #expect(text.string == "{}" && text.selectedRange() == .caret(2))
        open("  a{}", caret: 4)
        text.insertNewline(nil)
        #expect(text.string == "  a{\n  \n  }" && text.selectedRange().location == 7)
        open("x", caret: 0)
        text.insertTab(nil)
        #expect(text.string == "  x" && text.document.text == text.string)
    }

    /// A project closing leaves its editor read-only: a key steps over no closer and offers no completions.
    @Test func aReadOnlyEditorAsksTheCoreNothing() {
        open("")
        type("{")
        text.isEditable = false
        type("}")
        #expect(text.string == "{}" && text.selectedRange() == .caret(1))
        text.complete(nil)
        #expect(text.completions.offered == nil)
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
        #expect(!catcher.cancelled && text.completions.offered == nil)
        open("\\be")
        text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!catcher.cancelled && text.completions.offered != nil)
    }

    /// With completion off, only a list asked for follows the typing.
    @Test func typingAssistanceCanBeTurnedOff() throws {
        text.autoPair = false
        text.autoComplete = false
        open("")
        type("{", "\\", "b")
        #expect(text.string == "{\\b" && text.completions.offered == nil)
        text.complete(nil)
        let all = try #require(text.completions.offered).items.count
        type("e")
        #expect(try #require(text.completions.offered).items.count < all)
    }

    @Test func aCommandIsOneUndoStepThatKeepsTheSelection() {
        open("word")
        text.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(editor.perform(.bold))
        #expect(text.string == "\\textbf{word}" && text.selectedRange() == NSRange(location: 8, length: 4))
        text.undoManager?.undo()
        #expect(text.string == "word" && text.document.text == text.string)
        text.undoManager?.redo()
        #expect(text.string == "\\textbf{word}" && text.document.text == text.string)
    }

    @Test func blocksTabThroughTheirFields() {
        open("")
        #expect(editor.perform(.block(id: "figure")))
        let string = text.string as NSString
        #expect(text.selectedRange() == .caret(string.range(of: "]{}").location + 2))
        text.insertTab(nil)
        #expect(text.selectedRange().location == NSMaxRange(string.range(of: "\\caption{")))
        text.insertTab(nil)
        #expect(text.selectedRange().location == NSMaxRange(string.range(of: "fig:")) && text.undoManager?.undoActionName == "Insert")
        open("")
        #expect(editor.perform(.block(id: "figure", title: "Figure")))
        #expect(text.undoManager?.undoActionName == "Insert Figure")
    }

    @Test func writingToolsPassOverTheLaTeX() {
        let string = "Some \\emph{prose}" as NSString
        open(string as String)
        let ignored = editor.textView(text, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: string.length)).map(\.rangeValue)
        func isIgnored(_ word: String) -> Bool { ignored.contains { NSIntersectionRange($0, string.range(of: word)).length > 0 } }
        #expect(isIgnored("\\emph") && !isIgnored("Some") && !isIgnored("prose"))
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
            return text.textRange(.caret(text.document.lineStart(line)))
                .flatMap { text.textLayoutManager?.textLayoutFragment(for: $0.location) }
                .map { $0.layoutFragmentFrame.minY + text.textContainerOrigin.y - clip.bounds.minY - clip.contentInsets.top }
        }
        editor.reveal(line: 1700, atTop: true, focus: false)
        #expect(top(1700) == 0, "Actual top: \(String(describing: top(1700)))")
        editor.textView.enclosingScrollView!.setFrameSize(NSSize(width: 350, height: 400))
        #expect(top(1700) == 0, "Actual top: \(String(describing: top(1700)))")
        #expect(text.textContainer?.size.width == text.frame.width - 2 * text.textContainerInset.width)
    }

    /// 27.2: until a scroll prepares content, TextKit's content view can end at the scroll view's insets, which left the lines
    /// under the status bar undrawn after a launch or a resize. Once laid out, the source has prepared all that shows.
    @Test func theShownTextIsPreparedBeforeAnyScroll() async throws {
        let window = inWindow()
        // The bar's accessory gives the pane its safe area, which the scroll view takes as its insets.
        try #require(window.contentView).additionalSafeAreaInsets.bottom = BarMetrics.height
        window.orderFrontUnseen()
        open(String(repeating: "A line of text.\n", count: 200), caret: 0)
        window.setContentSize(NSSize(width: 700, height: 450))
        editor.scrollView.frame = try #require(window.contentView).bounds
        try await waitUntil { text.preparedContentRect.contains(text.visibleRect) } state: {
            "prepared \(text.preparedContentRect), shown \(text.visibleRect)"
        }
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

    /// From here each `grouping` is a top-level undo group of its own, as AppKit groups an event's changes.
    private func groupingByEvent() throws -> UndoManager {
        let undo = try #require(text.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        return undo
    }

    @Test func aCommandIsItsOwnUndoStep() async throws {
        open("", caret: 0)
        let undo = try groupingByEvent()
        await undo.grouping { type("a") }
        await undo.grouping { type("b") }
        await undo.grouping { editor.perform(.bold) }
        #expect(undo.undoActionName == "Bold")
        await undo.grouping { type("c") }
        #expect(text.string == "ab\\textbf{c}")
        undo.undo()
        #expect(text.string == "ab\\textbf{}" && undo.undoActionName == "Bold")
        undo.undo()
        #expect(text.string == "ab" && text.document.text == text.string)
    }

    @Test func aMovedLineIsOneUndoStep() async throws {
        open("a\nb\nc\nd", caret: 2)
        let undo = try groupingByEvent()
        await undo.grouping { #expect(editor.perform(.moveLineUp)) }
        #expect(text.string == "b\na\nc\nd" && text.selectedRange() == .caret(0) && undo.undoActionName == "Move Line Up")
        #expect(!editor.perform(.moveLineUp))
        undo.undo()
        #expect(text.string == "a\nb\nc\nd" && text.document.text == text.string)
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
        let offered = try #require(text.completions.offered)
        #expect(offered.start == 2 && offered.items.first?.label == "\\begin")
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(text.completions.offered == nil && text.undoManager?.undoActionName == "Completion")
        #expect(text.string == "  \\begin{env}\n    \n  \\end{env}" && text.selectedRange() == NSRange(location: 9, length: 3))
        type("itemize")
        text.insertTab(nil)
        #expect(text.selectedRange() == .caret(22))
        text.insertTab(nil)
        #expect(text.string == "  \\begin{itemize}\n      \n  \\end{itemize}" && text.document.text == text.string)
    }

    @Test func theCompletionListTakesOnlyItsKeys() throws {
        inWindow()
        open("\\")
        type("b")
        let all = try #require(text.completions.offered).items.count
        type("e")
        #expect(try #require(text.completions.offered).items.count < all)
        text.deleteBackward(nil)
        #expect(text.completions.offered?.items.count == all)
        text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(text.completions.offered == nil && text.string == "\\b")
        text.complete(nil)
        let second = try #require(text.completions.offered?.items[1])
        text.doCommand(by: #selector(NSResponder.moveDown(_:)))
        text.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(text.string == second.text)
        open("\\be")
        text.complete(nil)
        type(" ")
        #expect(text.completions.offered == nil && text.string == "\\be ")
        open("\\be")
        text.complete(nil)
        #expect(text.completions.offered != nil)
        text.setSelectedRange(.caret(0))
        #expect(text.completions.offered == nil)
    }

    /// The list is a view over the editor's text, and nothing in it takes the keyboard: a click chooses a row, and the
    /// text view goes on typing and moving through the rows.
    @Test func theCompletionListNeverTakesTheKeyboard() throws {
        inWindow()
        open("\\")
        type("b")
        _ = try #require(text.completions.offered)
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
        text.setMarkedText("あ", selectedRange: .caret(1), replacementRange: typed)
        text.setMarkedText("あい", selectedRange: .caret(2), replacementRange: typed)
        #expect(told == [true] && text.string == "startあい" && text.document.text == text.string)
        text.unmarkText()
        #expect(told == [true, false] && !text.hasMarkedText())
        text.setMarkedText("あ", selectedRange: .caret(1), replacementRange: typed)
        type("亜")
        #expect(told == [true, false, true, false] && !text.hasMarkedText() && text.string == "startあい亜" && text.document.text == text.string)
    }

    @Test func switchingFilesDuringCompositionKeepsUndoWithItsOwnText() {
        open("first", path: "a.tex")
        text.setMarkedText("仮", selectedRange: .caret(1), replacementRange: typed)

        open("second", path: "b.tex")
        #expect(!text.hasMarkedText() && text.string == "second" && text.document.text == "second" && text.undoManager?.canUndo == false)
        // The old undo referred to provisional text that wasn't saved to a.tex.
        open("first", path: "a.tex")
        text.undoManager?.undo()
        #expect(text.string == "first" && text.document.text == "first")
    }

    /// AppKit's results count from the range checked, which starts here inside a \label whose code range starts before it.
    @Test func spellingIsTheProses() {
        let string = "\\label{sec:labelwrod} \\emph{prosewrod}" as NSString
        open(string as String)
        let start = string.range(of: "labelwrod").location
        let checked = NSRange(location: start, length: string.length - start)
        let relative = { (word: String) in NSRange(location: string.range(of: word).location - start, length: (word as NSString).length) }
        let kept = editor.textView(text, didCheckTextIn: checked, types: NSTextCheckingAllTypes, options: [:],
                                   results: ["labelwrod", "prosewrod"].map { .spellCheckingResult(range: relative($0)) },
                                   orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 2)
        #expect(kept.map(\.range) == [relative("prosewrod")])
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
        text.insertText("\\[\n", replacementRange: .caret(2))
        try await waitUntilColoured("]", theme.color(.mathDelimiter))
        text.undoManager?.undo()
        try await waitUntilColoured("]", theme.color(.invalid))
    }

    /// Another app's text for the file shown keeps the caret and the top line where they were, as Xcode does.
    @Test func aReloadKeepsTheCaretAndTheTopLine() throws {
        inWindow()
        let long = (1...400).map { "Line \($0)" }.joined(separator: "\n")
        open(long, caret: 0)
        editor.reveal(line: 100, atTop: true, focus: false)
        let caret = NSRange(location: text.document.lineStart(120) + 2, length: 3)
        text.setSelectedRange(caret)
        let top = try #require(text.shownTop)
        editor.reload(text: long + "\nmore")
        #expect(text.selectedRange() == caret)
        #expect(text.shownTop?.offset == top.offset && text.shownTop?.below == top.below)
        editor.reload(text: "short")
        #expect(text.selectedRange() == .caret(5))
    }

    /// The list is a view of the scroll view's, over the text: a scroll the viewport needs no new layout for moves it too.
    @Test func theCompletionListFollowsAScroll() throws {
        inWindow()
        let lines = (1...200).map { $0 == 6 ? "\\be" : "Line \($0)" }
        // After "\be".
        open(lines.joined(separator: "\n"), caret: (lines[..<6].joined(separator: "\n") as NSString).length)
        try layOut()
        text.complete(nil)
        _ = try #require(text.completions.offered)
        let list = try #require(editor.scrollView.subviews.first { $0 is NSHostingView<CompletionRowsView> })
        let before = list.frame
        let clip = editor.scrollView.contentView
        let step = 3 * (text.defaultParagraphStyle?.minimumLineHeight ?? 16)
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + step))
        editor.scrollView.reflectScrolledClipView(clip)
        #expect(abs(before.minY - list.frame.minY - step) <= 1, "Moved by \(before.minY - list.frame.minY), scrolled by \(step)")
        // Its line scrolled out of sight: it closes.
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 30 * step))
        editor.scrollView.reflectScrolledClipView(clip)
        #expect(text.completions.offered == nil && list.superview == nil)
    }

    /// What's typed in a mirrored field goes in both its places at every step of Undo, and one Undo should take it all back.
    @Test func undoInAMirroredFieldKeepsItsPlacesAlike() throws {
        open("\\beg")
        let undo = try #require(text.undoManager)
        // Each key an event of its own, in its own top-level undo group, as AppKit gives it.
        undo.groupsByEvent = false
        func step(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }
        step {
            text.complete(nil)
            text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        #expect(text.string == "\\begin{env}\n  \n\\end{env}")
        for key in "itemize" { step { type(String(key)) } }
        #expect(text.string == "\\begin{itemize}\n  \n\\end{itemize}")
        undo.undo()
        let string = text.string as NSString
        let begun = string.substring(with: NSRange(location: 7, length: string.range(of: "}").location - 7))
        #expect(string.hasSuffix("\\end{\(begun)}") && text.document.text == text.string)
        // One Undo should take back the word typed in the field, but the mirror edits end the typing's coalescing.
        withKnownIssue("Typing in a mirrored field takes an Undo per key") {
            #expect(text.string == "\\begin{env}\n  \n\\end{env}")
        }
    }

    @Test func aThemeRecoloursTheText() async throws {
        let window = inWindow()
        window.orderFrontUnseen()
        defer { window.close() }
        open("\\section{A} % note")
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
        #expect(went.isEmpty && text.selectedRange() == .caret(4))
        try click(at: point, in: window, clicks: 2)
        #expect(went == [true] && text.selectedRange() == NSRange(location: 4, length: 3))
    }

    @Test func aClickInTheGutterSelectsTheLine() throws {
        let window = inWindow()
        open("one\ntwo\nthree", caret: 0)
        text.layoutSubtreeIfNeeded()
        show(issue(2, "Missing $ inserted"))
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

    /// An issue as the session's `issues` event has it, its one-line form the message itself.
    private func issue(_ line: Int, _ message: String, error: Bool = true, compact: String? = nil, tokens: [NSRange] = [],
                       others: [String] = []) -> IssuesEvent.Line {
        IssuesEvent.Line(line: line, error: error, message: message, short: message, compact: compact,
                         tokens: tokens.map { SourceRange(start: $0.location, length: $0.length) }, others: others)
    }

    private func show(_ issues: IssuesEvent.Line...) {
        text.issues.lines = Dictionary(uniqueKeysWithValues: issues.map { ($0.line, $0) })
    }

    private func layOut(width: CGFloat? = nil) throws {
        if let width { editor.scrollView.frame.size.width = width }
        editor.scrollView.layoutSubtreeIfNeeded()
        try #require(text.textLayoutManager).textViewportLayoutController.layoutViewport()
    }

    /// The box is a point inside its band's end on the first wrapped line; narrower panes cut its words short, then leave
    /// the symbol alone, then nothing, with a help tag's words. An undefined command is underlined where it stands.
    @Test func anIssuesMessageIsAtItsLinesEnd() throws {
        let window = inWindow()
        let undefined = issue(2, "Undefined control sequence: \\foo", compact: "Undefined: \\foo",
                              tokens: [NSRange(location: 4, length: 4), NSRange(location: 19, length: 4)])
        open("one\nUse \\foo here, and \\foo there.\n\n", caret: 0)
        show(issue(1, "Marked", error: false), undefined, issue(4, "Emergency stop", others: ["Missing \\begin{document}"]))
        try layOut()
        let padding = try #require(text.textContainer).lineFragmentPadding
        let digit = ("0" as NSString).size(withAttributes: [.font: try #require(text.font)]).width
        let font = NSFont.systemFont(ofSize: 13)
        var rows = text.issues.rows
        // The last line is the document's empty one, laid out with the paragraph before it.
        #expect(rows.map(\.line) == [1, 2, 4] && rows.map { $0.message?.view.rootView.isError } == [false, true, true])
        for row in rows {
            let message = try #require(row.message)
            #expect(!message.cut && message.rect.maxX == row.band.maxX - 1 && message.rect.minY == row.band.minY)
            #expect(row.band.contains(message.rect) && message.view.superview === text && message.view.frame == message.rect)
            // It takes no click.
            #expect(text.hitTest(text.convert(NSPoint(x: message.rect.midX, y: message.rect.midY), to: text.superview)) === text)
        }
        #expect(rows[0].tip == nil && rows[1].tip == nil && rows[2].tip == "Emergency stop\nMissing \\begin{document}")
        // Xcode 27's boxes at 13 pt for a 353.74 pt message: 406 pt alone, 418 with a count.
        let xcode = 353.7421875 as CGFloat
        #expect(IssueBox.Metrics.width(ofText: xcode, font: font, issues: 1) == 406 && IssueBox.Metrics.width(ofText: xcode, font: font, issues: 2) == 418)
        // Both places the command stands, each four characters wide to the pixel, and none for the other lines.
        let pixel = 1 / window.backingScaleFactor
        #expect(rows.map(\.tokens.count) == [0, 2, 0] && rows[1].tokens.allSatisfy { abs($0.width - 4 * digit) <= pixel })
        let start = text.textContainerOrigin.x + padding
        #expect(abs(rows[1].tokens[0].minX - (start + 4 * digit)) <= pixel / 2 && abs(rows[1].tokens[1].minX - (start + 19 * digit)) <= pixel / 2)
        // Narrower: fewer words, the box taking all the room from a character after the text, on whole points, in its view.
        try layOut(width: 520)
        let views = rows.map { $0.message?.view }
        rows = text.issues.rows
        let cut = try #require(rows[1].message)
        #expect(cut.cut && cut.rect.maxX == rows[1].band.maxX - 1 && cut.rect.width == cut.rect.width.rounded())
        #expect(cut.rect.minX >= start + 31 * digit && cut.rect.minX < start + 31 * digit + 1 && cut.view === views[1])
        #expect(rows[1].tip == "Undefined control sequence: \\foo" && rows[0].message?.cut == false)
        // Room for the symbol and not for words: the symbol alone, and the help tag's words.
        open("one\nUse \\foo here, and \\foo there, to the edge\n", caret: 0)
        show(undefined)
        try layOut(width: 480)
        let alone = try #require(text.issues.rows.first?.message)
        #expect(alone.cut && alone.rect.width == IssueBox.Metrics.width(ofText: nil, font: font, issues: 1) && text.issues.rows.first?.tip != nil)
        // No room: the band is left, and the help tag's words.
        open("one\nUse \\foo here, and \\foo there, to the edge\n", caret: 0)
        show(undefined)
        try layOut(width: 420)
        rows = text.issues.rows
        #expect(rows.count == 1 && rows[0].message == nil && rows[0].tip == "Undefined control sequence: \\foo" && rows[0].tokens.count == 2)
        #expect(!text.subviews.contains { $0 is IssueMessageView })
    }

    @Test func aClickOnAnIssuesMessageShowsTheIssue() throws {
        let window = inWindow()
        open("one\ntwo\nthree", caret: 5)
        show(issue(2, "Missing $ inserted"))
        try layOut()
        var asked: [Int] = []
        text.issueClicked = { asked.append($0) }
        let message = try #require(text.issues.rows.first?.message).rect
        // In the window's coordinates.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { text.convert(NSPoint(x: x, y: y), to: nil) }
        let inside = point(message.midX, message.midY)
        try click(at: inside, releasedAt: point(message.minX - 20, message.midY), in: window)
        #expect(asked.isEmpty)
        try click(at: inside, in: window)
        #expect(asked == [2] && text.selectedRange() == .caret(5))
        try click(at: inside, in: window, .shift)
        #expect(asked == [2] && text.selectedRange() == NSRange(location: 5, length: 2))
        text.setSelectedRange(.caret(5))
        let above = point(text.textContainerOrigin.x + 20, message.midY - message.height)
        NSApp.postEvent(try mouse(.leftMouseDragged, at: above, in: window), atStart: false)
        try click(at: inside, releasedAt: above, in: window)
        #expect(asked == [2] && NSMaxRange(text.selectedRange()) == 7 && (1...3).contains(text.selectedRange().location))
    }

    @Test func theRotorsStepThroughHeadingsAndIssues() throws {
        open("a\n\\section{One}\nb\n\\section{Two}\nc", caret: 0)
        text.headings = { [(2, "One"), (4, "Two")] }
        show(issue(3, "Undefined control sequence"), issue(5, "Marked", error: false))
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
