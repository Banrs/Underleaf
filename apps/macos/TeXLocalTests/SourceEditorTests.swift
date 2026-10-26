import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

struct SourceEditorTests {
    private let editor = SourceEditor()
    private var text: SourceTextView { editor.textView }
    private let typed = NSRange(location: NSNotFound, length: 0)
    private let defaults = TestDefaults()
    private let held = Held()
    private final class Held {
        var window: NSWindow?
        var folder: URL?
        deinit { folder.map { try? FileManager.default.removeItem(at: $0) } }
    }

    private func open(_ string: String, caret: Int? = nil, path: String = "main.tex") {
        editor.open(path: path, text: string, focus: false)
        text.setSelectedRange(.caret(caret ?? (string as NSString).length))
    }

    private func type(_ keys: String...) {
        for key in keys { text.insertText(key, replacementRange: typed) }
    }

    private func opened(_ main: String, with files: [String: String] = [:]) async throws -> (AppModel, ProjectModel) {
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        let info = try await newProject()
        held.folder = info.folder
        try info.write(main, to: info.mainFile)
        for (path, text) in files { try info.write(text, to: path) }
        let app = AppModel(defaults: defaults.store)
        app.autoCompile = false
        await app.open(info.id)
        return (app, try #require(app.project))
    }

    @Test func eachFileKeepsItsUndo() throws {
        open("one", caret: 0, path: "a.tex")
        type("x")
        let a = try #require(text.undoManager)
        open("two", path: "b.tex")
        #expect(text.undoManager !== a && text.undoManager?.canUndo == false)
        open("main", path: "main.tex")
        editor.rename(from: "a.tex", to: "b.tex")
        open("xone", path: "b.tex")
        #expect(text.undoManager === a)
        text.undoManager?.undo()
        #expect(text.string == "one")
        open("main, changed", path: "main.tex")
        open("elsewhere", path: "b.tex")
        #expect(text.undoManager !== a)
    }

    @Test func aNulCharacterKeepsTheMirrorInStep() {
        let document = SourceDocument(text: "a\u{0}\nb")
        #expect(document.lineCount == 2)
        #expect(document.edit(.caret(4), with: "\u{0}\nc", changing: nil, mirroring: false).isEmpty)
        #expect(document.lineCount == 3 && document.lineStart(3) == 6 && document.text == "a\u{0}\nb\u{0}\nc")
    }

    @Test func typingIsTheCores() {
        open("")
        type("{", "}")
        #expect(text.string == "{}" && text.selectedRange() == .caret(2))
        open("  a{}", caret: 4)
        text.insertNewline(nil)
        #expect(text.string == "  a{\n    \n  }" && text.selectedRange().location == 9)
        open("x", caret: 0)
        text.insertTab(nil)
        #expect(text.string == "  x" && text.document.text == text.string)
    }

    @Test func jumpAtARefOpensItsLabelsFileAtTheLabel() async throws {
        let (app, project) = try await opened("See \\ref{fig:a}.", with: ["figures.tex": "Figures.\n\\label{fig:a}\n"])
        let text = project.editor.textView
        try await waitUntil(timeout: .seconds(5)) { text.document.definition(at: 10) != nil }
        text.setSelectedRange(.caret(10))
        app.perform(.jumpToDefinition, on: project)
        try await waitUntil(timeout: .seconds(5)) { project.editor.path == "figures.tex" }
        #expect(project.editor.currentLine == 2 && (text.string as NSString).substring(with: text.selectedRange()) == "fig:a")
        await app.close()
    }

    @Test func aRenamesEditsAreOneUndoStepInTheSource() async throws {
        let original = "\\label{a} see \\ref{a}"
        let (app, project) = try await opened(original)
        let text = project.editor.textView, undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        text.setSelectedRange(.caret(19))
        app.perform(.editRename, on: project)
        guard case .rename(let symbol)? = app.prompt else { Issue.record("Rename opened no sheet"); return }
        try await project.renameSymbol(symbol, to: "b")
        #expect(text.string == "\\label{b} see \\ref{b}" && undo.undoActionName == "Rename")
        undo.undo()
        #expect(text.string == original && !undo.canUndo)
        await app.close()
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
        #expect(shown.items.map { $0.isSeparatorItem ? "-" : $0.title }
            == ["Jump to Definition", "Find Usages", "Go to PDF Position", "Comment Selection", "-", "Cut"])
        var performed: [MenuCommand] = []
        editor.command = { performed.append($0) }
        let sync = shown.items[2]
        NSApp.sendAction(try #require(sync.action), to: sync.target, from: sync)
        #expect(performed == [.syncForward])
    }

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

    private func farLine() -> NSRange {
        inWindow()
        open((1...6000).map { "\\section{Line \($0)} " + String(repeating: "word ", count: $0 % 40) }.joined(separator: "\n"), caret: 0)
        return NSRange(location: text.document.lineStart(5000), length: 4)
    }

    @Test func jumpToSelectionCentresIt() throws {
        let range = farLine()
        text.setSelectedRange(range)
        text.centerSelectionInVisibleArea(nil)
        let fragment = try #require(text.textRange(.caret(range.location))
            .flatMap { text.textLayoutManager?.textLayoutFragment(for: $0.location) })
        let line = try #require(fragment.textLineFragments.first)
        let middle = fragment.layoutFragmentFrame.minY + line.typographicBounds.midY + text.textContainerOrigin.y
        let lineHeight = text.defaultParagraphStyle?.minimumLineHeight ?? 18
        #expect(abs(middle - text.shownRect.midY) < lineHeight, "Line at \(middle), centre \(text.shownRect.midY)")
    }

    @Test func aFarRangeScrolledToShows() throws {
        let range = farLine()
        text.scrollRangeToVisible(range)
        let segments = try #require(text.segments(range))
        #expect(text.shownRect.contains(segments), "Range at \(segments), shown \(text.shownRect)")
    }

    @Test func theShownTextIsPreparedBeforeAnyScroll() async throws {
        let window = inWindow()
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

    @Test func syncTeXGoesToTheWordASearchToItsMatchAndBothTellAUTF16Column() {
        open("Ünï words \\word, the word\nnext", caret: 1)
        editor.reveal(line: 1, column: 21, focus: false)
        #expect(text.selectedRange() == NSRange(location: 21, length: 4))
        editor.reveal(line: 1, column: 22, length: 2, focus: false)
        #expect(text.selectedRange() == NSRange(location: 22, length: 2))
        editor.reveal(line: 1, column: 22, length: 9, focus: false)
        #expect(text.selectedRange() == NSRange(location: 22, length: 3))
        open("before\n😀 echo echo echo\n", caret: 22, path: "b.tex")
        #expect(editor.currentLine == 2 && editor.currentColumn == 15)
    }

    @Test func completionsFillTheirFields() throws {
        open("  \\beg")
        let undo = try #require(text.undoManager)
        text.complete(nil)
        #expect(text.completions.offered?.start == 2 && text.completions.offered?.items.first?.label == "\\begin")
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        endEvent()
        #expect(text.completions.offered == nil && undo.undoActionName == "Completion")
        #expect(text.string == "  \\begin{env}\n    \n  \\end{env}" && text.selectedRange() == NSRange(location: 9, length: 3))
        for key in "itemize" {
            type(String(key))
            endEvent()
        }
        #expect(text.string == "  \\begin{itemize}\n    \n  \\end{itemize}")
        text.setSelectedRange(.caret(0))
        endEvent()
        undo.undo()
        #expect(text.string == "  \\begin{env}\n    \n  \\end{env}" && text.document.text == text.string)
        undo.undo()
        #expect(text.string == "  \\beg")
    }

    private func endEvent() { _ = (UndoManager.self as AnyObject).perform(NSSelectorFromString("_endTopLevelGroupings")) }

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

    private var completionList: NSView? { editor.scrollView.subviews.first { $0 is NSHostingView<CompletionRowsView> } }

    @Test func theCompletionListNeverTakesTheKeyboard() throws {
        inWindow()
        open("\\")
        type("b")
        let list = try #require(completionList)
        list.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        #expect(all(list).count > 1 && !all(list).contains { $0.acceptsFirstResponder })
    }

    @Test func theCompletionListFollowsAScroll() throws {
        inWindow()
        let lines = (1...200).map { $0 == 6 ? "\\be" : "Line \($0)" }
        open(lines.joined(separator: "\n"), caret: (lines[..<6].joined(separator: "\n") as NSString).length)
        try layOut()
        text.complete(nil)
        let list = try #require(completionList)
        let before = list.frame
        let clip = editor.scrollView.contentView
        let step = 3 * (text.defaultParagraphStyle?.minimumLineHeight ?? 16)
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + step))
        editor.scrollView.reflectScrolledClipView(clip)
        #expect(abs(before.minY - list.frame.minY - step) <= 1, "Moved by \(before.minY - list.frame.minY), scrolled by \(step)")
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 30 * step))
        editor.scrollView.reflectScrolledClipView(clip)
        #expect(text.completions.offered == nil && list.superview == nil)
    }

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
        open("first", path: "a.tex")
        text.undoManager?.undo()
        #expect(text.string == "first" && text.document.text == "first")
    }

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

    private func click(at point: NSPoint, releasedAt release: NSPoint? = nil, in window: NSWindow, clicks: Int = 1,
                       _ modifiers: NSEvent.ModifierFlags = []) throws {
        NSApp.postEvent(try mouse(.leftMouseUp, at: release ?? point, in: window, clicks: clicks, modifiers), atStart: false)
        text.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window, clicks: clicks, modifiers))
    }

    private func colour(of word: String) throws -> NSColor? {
        let manager = try #require(text.textLayoutManager)
        text.layoutSubtreeIfNeeded()
        manager.textViewportLayoutController.layoutViewport()
        text.cacheDisplay(in: text.visibleRect, to: try #require(text.bitmapImageRepForCachingDisplay(in: text.visibleRect)))
        let range = try #require(text.textRange((text.string as NSString).range(of: word)))
        var colour: NSColor?
        manager.enumerateRenderingAttributes(from: range.location, reverse: false) { _, attributes, _ in
            colour = attributes[.foregroundColor] as? NSColor
            return false
        }
        return colour
    }

    private func waitUntilColoured(_ word: String, _ expected: NSColor) async throws {
        try await waitUntil { (try? self.colour(of: word)) == expected } state: { "\(word): \(String(describing: try? self.colour(of: word)))" }
    }

    @Test func anEditRecoloursTheLinesBelowIt() async throws {
        inWindow()
        open("a\nb\nxyz\n\\]", caret: 0)
        let theme = SyntaxTheme.system
        try await waitUntilColoured("]", theme.color(.invalid))
        text.insertText("\\[\n", replacementRange: .caret(2))
        try await waitUntilColoured("]", theme.color(.maths))
        text.undoManager?.undo()
        try await waitUntilColoured("]", theme.color(.invalid))
        text.setSelectedRange(.caret(text.length))
        type("\n\\section")
        try await waitUntilColoured("\\section", theme.color(.command))
    }

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
        open("\\textbf{x}", caret: 0)
        text.layoutSubtreeIfNeeded()
        let name = text.firstRect(forCharacterRange: NSRange(location: 3, length: 1), actualRange: nil)
        try click(at: window.convertPoint(fromScreen: NSPoint(x: name.minX + 1, y: name.midY)), in: window, clicks: 2)
        #expect(went == [true] && text.selectedRange().length > 0)
    }

    @Test func aClickInTheGutterSelectsTheLine() throws {
        let window = inWindow()
        open("one\ntwo\nthree", caret: 0)
        text.layoutSubtreeIfNeeded()
        show(issue(2, "Missing $ inserted"))
        var asked: [Int] = []
        text.issues.clicked = { asked.append($0) }
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

    @Test func aFoldHidesItsLinesUntilAnEditOrTheSelectionReachesIn() throws {
        let window = inWindow()
        open("\\begin{itemize}\n\\item a\n\\item b\n\\end{itemize}\nlast", caret: 0)
        func shown() throws -> [Int] {
            try layOut()
            return text.fragments.map { text.document.line(at: $0.offset) }
        }
        #expect(try shown() == [1, 2, 3, 4, 5])
        editor.perform(.fold)
        #expect(try shown() == [1, 4, 5])
        type("x")
        #expect(try shown() == [1, 4, 5] && text.folded == [NSRange(location: 17, length: 16)])
        let end = text.document.lineStart(2) - 1, after = text.document.lineStart(4)
        text.setSelectedRange(.caret(end))
        text.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(text.selectedRange() == .caret(after))
        text.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(text.selectedRange() == .caret(end) && text.folded.count == 1)
        text.setSelectedRange(.caret(text.document.lineStart(3)))
        #expect(text.folded.isEmpty && (try shown()) == [1, 2, 3, 4, 5])
        let glyph = text.firstRect(forCharacterRange: .caret(0), actualRange: nil)
        let y = text.convert(window.convertPoint(fromScreen: NSPoint(x: glyph.minX, y: glyph.midY)), from: nil).y
        #expect(text.foldClick(at: NSPoint(x: (text.gutter.numbersEnd + text.textContainerOrigin.x) / 2, y: y)))
        #expect(try shown() == [1, 4, 5])
        let kept = text.string
        editor.open(path: "other.tex", text: "other", focus: false)
        editor.open(path: "main.tex", text: kept, focus: false)
        #expect(try shown() == [1, 4, 5])
        text.textStorage?.replaceCharacters(in: .caret(text.document.lineStart(3)), with: "y")
        #expect(text.folded.isEmpty)
    }

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

    private func issue(_ line: Int, _ message: String, error: Bool = true, compact: String? = nil, tokens: [NSRange] = [],
                       others: [String] = []) -> IssuesEvent.Line {
        IssuesEvent.Line(line: line, error: error, message: message, short: message, compact: compact,
                         tokens: tokens.map { SourceRange(start: $0.location, length: $0.length) }, others: others, index: nil)
    }

    private func show(_ issues: IssuesEvent.Line...) {
        text.issues.lines = Dictionary(uniqueKeysWithValues: issues.map { ($0.line, $0) })
    }

    private func layOut(width: CGFloat? = nil) throws {
        if let width { editor.scrollView.frame.size.width = width }
        editor.scrollView.layoutSubtreeIfNeeded()
        try #require(text.textLayoutManager).textViewportLayoutController.layoutViewport()
    }

    @Test func anIssuesMessageIsAtItsLinesEnd() throws {
        inWindow()
        let undefined = issue(2, "Undefined control sequence: \\foo", compact: "Undefined: \\foo",
                              tokens: [NSRange(location: 4, length: 4), NSRange(location: 19, length: 4)])
        open("one\nUse \\foo here, and \\foo there.\n\n", caret: 0)
        show(issue(1, "Marked", error: false), undefined, issue(4, "Emergency stop", others: ["Missing \\begin{document}"]))
        try layOut()
        let padding = try #require(text.textContainer).lineFragmentPadding
        let digit = ("0" as NSString).size(withAttributes: [.font: try #require(text.font)]).width
        let font = NSFont.systemFont(ofSize: 13)
        var rows = text.issues.rows
        #expect(rows.map(\.line) == [1, 2, 4] && rows.map { $0.message?.view.rootView.isError } == [false, true, true])
        for row in rows {
            let message = try #require(row.message)
            #expect(!message.cut && message.rect.maxX == row.band.maxX - 1 && message.rect.minY == row.band.minY)
            #expect(row.band.contains(message.rect) && message.view.superview === text && message.view.frame == message.rect)
            #expect(text.hitTest(text.convert(NSPoint(x: message.rect.midX, y: message.rect.midY), to: text.superview)) === text)
        }
        #expect(rows[0].tip == nil && rows[1].tip == nil && rows[2].tip == "Emergency stop\nMissing \\begin{document}")
        #expect(rows.map(\.tokens.count) == [0, 2, 0])
        let start = text.textContainerOrigin.x + padding
        try layOut(width: 520)
        let views = rows.map { $0.message?.view }
        rows = text.issues.rows
        let cut = try #require(rows[1].message)
        #expect(cut.cut && cut.rect.maxX == rows[1].band.maxX - 1 && cut.rect.width == cut.rect.width.rounded())
        #expect(cut.rect.minX >= start + 31 * digit && cut.rect.minX < start + 31 * digit + 1 && cut.view === views[1])
        #expect(rows[1].tip == "Undefined control sequence: \\foo" && rows[0].message?.cut == false)
        open("one\nUse \\foo here, and \\foo there, to the edge\n", caret: 0)
        show(undefined)
        try layOut(width: 480)
        let alone = try #require(text.issues.rows.first?.message)
        #expect(alone.cut && alone.rect.width == IssueBox.Metrics.width(ofText: nil, font: font, issues: 1) && text.issues.rows.first?.tip != nil)
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
        text.issues.clicked = { asked.append($0) }
        let message = try #require(text.issues.rows.first?.message).rect
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
