import SwiftUI
import XCTest
@testable import TeXLocal

final class SyncTeXGeometryTests: XCTestCase {
    // A US Letter page whose box starts at the origin, and one offset the way
    // some producers write a crop box.
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    let offset = CGRect(x: 10, y: 20, width: 612, height: 792)

    func testForwardBoxFlipsFromTopLeftToBottomLeft() {
        let loc = ForwardLoc(page: 1, h: 72, v: 100, width: 468, height: 10)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: letter)
        // Baseline 100pt below the top edge is 692pt above the bottom edge.
        XCTAssertEqual(rect.minX, 70)
        XCTAssertEqual(rect.minY, 690)
        XCTAssertEqual(rect.width, 472)
        XCTAssertEqual(rect.height, 14)
    }

    func testForwardBoxIsNeverNarrowerThanAWord() {
        let loc = ForwardLoc(page: 1, h: 72, v: 100, width: 0, height: nil)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: letter)
        XCTAssertEqual(rect.width, 28)
        XCTAssertEqual(rect.height, 16)
    }

    func testInversePointRoundTripsThroughAnOffsetBox() {
        let synctex = SyncTeXGeometry.synctexPoint(CGPoint(x: 82, y: 712), pageBounds: offset)
        XCTAssertEqual(synctex, CGPoint(x: 72, y: 100))
        let loc = ForwardLoc(page: 1, h: synctex.x, v: synctex.y, width: 0, height: 0)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: offset)
        XCTAssertEqual(rect.minX + 2, 82)
        XCTAssertEqual(rect.minY + 2, 712)
    }
}

final class OutlineTests: XCTestCase {
    func testSectionsWithDepthTitlesAndLines() {
        let text = """
        \\documentclass{article}
        \\section{Intro}
        % \\section{Commented out}
        \\subsection*[short]{Details}
        text \\section{}
        """
        let items = Outline.parse(text)
        XCTAssertEqual(items.map(\.title), ["Intro", "Details", "(untitled)"])
        XCTAssertEqual(items.map(\.level), [2, 3, 2])
        XCTAssertEqual(items.map(\.line), [2, 4, 5])
    }

    func testWordsCountAsTheWebCountsThem() {
        // Each count is what web/src/state.js lineWords gives, run in Node.
        let cases: [(Substring, Int)] = [
            ("Hello world", 2),
            ("\\section{Introduction} text here", 3),
            ("A \\textbf{bold} and \\emph{it} word", 5),
            ("Cost is 50\\% of total % a comment here", 4),
            ("\\begin{itemize}[leftmargin=*] item", 3),
            ("\\cite[p.~4]{knuth} says so", 3),
            ("\\foo*[x bar", 2),
            ("$x^2 + y_1$ is math", 4),
            ("Ünïcödé naïve café", 3),
            ("e\u{301}t\u{E9}", 1),
            ("x=1 2 3 ---", 1),
            ("tab\tseparated\u{A0}words", 3),
            ("don't stop", 2),
            ("a\\\\%b c", 3),
            ("50% off", 0),
            ("a % b\u{2028}c d", 4),
            ("a % b\u{2028}c % d", 3),
            ("", 0),
        ]
        for (line, words) in cases {
            XCTAssertEqual(Outline.lineWords(line), words, String(line))
        }
    }

    func testLinesBreakWhereTheEditorBreaksThemAndCommentsHoldNoWords() {
        let doc = Outline.analyze("\\section{One} two words\r\n  % three four\rfive\n")
        XCTAssertEqual(doc.lines, 4)
        XCTAssertEqual(doc.words, 4)
        XCTAssertEqual(doc.outline.map(\.title), ["One"])
        XCTAssertEqual(Outline.analyze("").lines, 1)
    }

    func testTheBreadcrumbIsTheChainOfEnclosingHeadings() {
        let outline = Outline.parse("""
        \\chapter{A}
        \\section{B}
        \\subsection{C}
        \\section{D}
        text
        """)
        XCTAssertEqual(Outline.chain(outline, at: 3).map(\.title), ["A", "B", "C"])
        XCTAssertEqual(Outline.chain(outline, at: 5).map(\.title), ["A", "D"])
        XCTAssertEqual(Outline.chain(outline, at: 0).map(\.title), [])
    }
}

final class OutlineDisplayTests: XCTestCase {
    func testDepthFollowsTheNestingNotTheLevel() {
        // A subsection before any section has no parent: it sits flush, as
        // does the section after it; the subsection under that section is
        // one in.
        let outline = Outline.parse("""
        \\subsection{}
        \\section{First Section}
        \\subsection{Detail}
        \\subsubsection{Finer}
        \\section{Second}
        """)
        XCTAssertEqual(Outline.depths(outline), [0, 0, 1, 2, 0])
    }

    func testTheTreeNestsAsTheHeadingsDo() {
        let outline = Outline.parse("""
        \\subsection{}
        \\section{A}
        \\subsection{A1}
        \\subsection{A2}
        \\section{B}
        """)
        let tree = Outline.tree(outline)
        XCTAssertEqual(tree.map(\.item.title), ["(untitled)", "A", "B"])
        XCTAssertNil(tree[0].children)
        XCTAssertEqual(tree[1].children?.map(\.item.title), ["A1", "A2"])
        XCTAssertNil(tree[2].children)
    }

    func testEmptyHeadingsAreNamedByKind() {
        let outline = Outline.parse("\\subsection{}\n\\chapter{}\n\\section{Named}")
        XCTAssertEqual(outline.map(Outline.displayTitle), ["Untitled Subsection", "Untitled Chapter", "Named"])
    }
}

/// The pane bar's groups measured off screen, with no window shown.
@MainActor
final class PaneBarLayoutTests: XCTestCase {
    /// The UI kit's two toolbars: Unified Compact and Unified.
    func testTheBarsAreTheKitsToolbarHeights() {
        XCTAssertEqual(PaneSize.compact.barHeight, 40)
        XCTAssertEqual(PaneSize.large.barHeight, 52)
    }

    /// Controls sit 8 pt from the bar's top and bottom, as in the kit. The
    /// accessory-bar bezel measures 22 and 34 pt, 2 pt under the kit's 24
    /// and 36, so the group keeps within 8 to 9 pt of each edge.
    func testAGroupFitsItsBarWithTheKitsInsets() {
        let two = ToolGroup(items: [
            Segment(id: "a", title: "Undo", systemImage: "arrow.uturn.backward", action: {}),
            Segment(id: "b", title: "Redo", systemImage: "arrow.uturn.forward", action: {}),
        ])
        .buttonStyle(.accessoryBar)
        for size in [PaneSize.compact, .large] {
            let height = NSHostingView(rootView: two.controlSize(size.controlSize)).fittingSize.height
            XCTAssertLessThanOrEqual(height, size.barHeight - 16, "\(size)")
            XCTAssertGreaterThanOrEqual(height, size.barHeight - 18, "\(size)")
        }
    }
}

@MainActor
final class SplitLayoutTests: XCTestCase {
    /// Two panes in a split of `size`, the second dragged to `last` points.
    private func split(_ size: NSSize, vertical: Bool = true, _ panes: [SplitPane],
                       last: CGFloat) -> (NSSplitView, SplitController.Coordinator) {
        let split = NSSplitView(frame: NSRect(origin: .zero, size: size))
        split.isVertical = vertical
        split.dividerStyle = .thin
        let coordinator = SplitController.Coordinator()
        coordinator.panes = panes
        coordinator.views = [NSView(), NSView()]
        coordinator.views.forEach(split.addArrangedSubview)
        split.delegate = coordinator
        let length = vertical ? size.width : size.height
        split.setPosition(length - last - split.dividerThickness, ofDividerAt: 0)
        return (split, coordinator)
    }

    private func widths(_ split: NSSplitView) -> [CGFloat] {
        split.arrangedSubviews.map(\.frame.width)
    }

    /// A pane squeezed to its minimum by a small window gets its share back
    /// as the window grows, rather than staying at the minimum.
    func testAPaneGetsItsShareBackAfterASmallWindow() throws {
        // Source | PDF with the PDF dragged narrow.
        let (split, coordinator) = split(NSSize(width: 936, height: 400),
                                         [SplitPane(minimum: 140) { EmptyView() }, SplitPane(minimum: 140) { EmptyView() }],
                                         last: 200)
        XCTAssertEqual(widths(split), [735, 200])
        split.setFrameSize(NSSize(width: 300, height: 400))
        XCTAssertEqual(widths(split), [159, 140])
        // Hidden now, it would come back at the share it had, not squeezed.
        XCTAssertEqual(try XCTUnwrap(coordinator.share(split, of: 1)), 200 / 935, accuracy: 0.001)
        split.setFrameSize(NSSize(width: 936, height: 400))
        XCTAssertEqual(widths(split), [735, 200])
    }

    /// A pane that keeps its size gives way beyond its largest share: the
    /// build panel in a small window leaves the editors the room.
    func testAPaneKeepsWithinItsLargestShare() {
        let (split, _) = split(NSSize(width: 400, height: 1000), vertical: false, [
            SplitPane(minimum: 120) { EmptyView() },
            SplitPane(minimum: 80, maxFraction: 0.4, keepsSize: true) { EmptyView() },
        ], last: 300)
        XCTAssertEqual(split.arrangedSubviews[1].frame.height, 300)
        split.setFrameSize(NSSize(width: 400, height: 500))
        XCTAssertEqual(split.arrangedSubviews[1].frame.height, 200)
        split.setFrameSize(NSSize(width: 400, height: 1000))
        XCTAssertEqual(split.arrangedSubviews[1].frame.height, 300)
    }
}

final class CompileResultTests: XCTestCase {
    func testTheSourceFindCountReadsAsXcodesDoes() {
        XCTAssertEqual(FindMatches(index: 3, total: 12).label(for: "loop"), "3 of 12")
        XCTAssertEqual(FindMatches(index: 0, total: 12).label(for: "loop"), "12 matches")
        XCTAssertEqual(FindMatches(index: 0, total: 1).label(for: "loop"), "1 match")
        XCTAssertEqual(FindMatches(index: 2, total: 1000, limited: true).label(for: "a"), "2 of 1000+")
        XCTAssertEqual(FindMatches().label(for: "loop"), "Not found")
        XCTAssertEqual(FindMatches().label(for: ""), "")
    }

    func testDurationsReadTheSameEverywhere() throws {
        let json = #"{"ok":true,"durationMs":1234,"pdf":null,"errors":[],"warnings":[],"log":""}"#
        let result = try JSONDecoder().decode(CompileResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.durationText, "1.2 s")
    }
}

final class RenameTests: XCTestCase {
    func testTheOpenFileMovesWithItsFolder() {
        XCTAssertEqual(remapPath("ch/intro.tex", from: "ch/intro.tex", to: "ch/start.tex"), "ch/start.tex")
        XCTAssertEqual(remapPath("ch/intro.tex", from: "ch", to: "chapters"), "chapters/intro.tex")
        XCTAssertEqual(remapPath("ch/a/b.tex", from: "ch/a", to: "x"), "x/b.tex")
        // A sibling that shares the prefix is not inside the folder.
        XCTAssertEqual(remapPath("chapter.tex", from: "ch", to: "chapters"), "chapter.tex")
        XCTAssertEqual(remapPath("main.tex", from: "ch", to: "chapters"), "main.tex")
    }
}

final class PDFFindTests: XCTestCase {
    func testTheCountReadsAsTheWebsDoes() {
        XCTAssertEqual(PDFFind.countLabel(query: "", total: 0, index: 1, limited: false), "")
        XCTAssertEqual(PDFFind.countLabel(query: "x", total: 0, index: 1, limited: false), "Not found")
        XCTAssertEqual(PDFFind.countLabel(query: "x", total: 12, index: 3, limited: false), "3 of 12")
        XCTAssertEqual(PDFFind.countLabel(query: "e", total: 5000, index: 1, limited: true), "1 of 5000+")
    }

    func testQueriesAreTrimmedAndCapped() {
        XCTAssertEqual(PDFFind.normalize("  theorem \n"), "theorem")
        XCTAssertEqual(PDFFind.normalize(" \t "), "")
        XCTAssertEqual(PDFFind.normalize(String(repeating: "a", count: 300)).count, 256)
    }
}

final class CommandTests: XCTestCase {
    func testAcceleratorsBecomeMenuShortcuts() {
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Return"), KeyboardShortcut(.return, modifiers: .command))
        XCTAssertEqual(MenuCommand.shortcut(for: "Ctrl+Shift+Return"), KeyboardShortcut(.return, modifiers: [.control, .shift]))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Plus"), KeyboardShortcut("=", modifiers: .command))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Shift+\\"), KeyboardShortcut("\\", modifiers: [.command, .shift]))
        XCTAssertEqual(MenuCommand.shortcut(for: "CmdOrCtrl+Alt+F"), KeyboardShortcut("f", modifiers: [.command, .option]))
    }

    func testEveryAcceleratorParses() {
        for command in MenuCommand.allCases where command.accel != nil {
            XCTAssertNotNil(command.shortcut, command.rawValue)
        }
    }

    func testTheEditorKeepsTheChordsItImplements() {
        let ids = Set(MenuCommand.editorHostKeys.map(\.id))
        XCTAssertTrue(ids.contains("compile.run"))
        XCTAssertTrue(ids.contains("edit.gotoLine"))
        XCTAssertTrue(ids.contains("view.zoomIn"))
        XCTAssertFalse(ids.contains("edit.find"))
        XCTAssertFalse(ids.contains("edit.findNext"))
        XCTAssertFalse(ids.contains("edit.findPrevious"))
        XCTAssertFalse(ids.contains("edit.comment"))
        XCTAssertFalse(ids.contains("edit.undo"))
        XCTAssertFalse(ids.contains("edit.redo"))
    }

    /// web/src/workspace.js as the test scheme's pre-action copies it into
    /// the scratch folder. The tests run inside TeXLocal.app, and reading the
    /// repository in ~/Documents from there asks macOS for Documents access
    /// again after every re-signing build, blocking the read until someone
    /// answers the prompt or it times out.
    private func webWorkspace() throws -> URL {
        let data = try XCTUnwrap(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        return URL(fileURLWithPath: data).appendingPathComponent("workspace.js")
    }

    /// The web's commands with no place in the Mac menus: Settings…, which the
    /// Settings scene adds with ⌘, itself, and the interface size, which on
    /// the Mac is the system's to set.
    private let webOnly: Set<String> = ["app.settings", "view.uiScaleUp", "view.uiScaleDown"]

    /// The menu has every other command the web declares, with the same chord.
    func testTheMenuHasEveryWebCommand() throws {
        let source = try String(contentsOf: webWorkspace(), encoding: .utf8)
        var ids: Set<String> = []
        for line in source.split(separator: "\n") {
            guard let match = line.firstMatch(of: /\{ id: '([^']+)'/) else { continue }
            let id = String(match.1)
            ids.insert(id)
            guard !webOnly.contains(id) else { continue }
            let accel = line.firstMatch(of: /accel: '([^']+)'/)
                .map { String($0.1).replacingOccurrences(of: "\\\\", with: "\\") }
            XCTAssertEqual(MenuCommand(rawValue: id)?.accel, accel, id)
        }
        XCTAssertEqual(Set(MenuCommand.allCases.map(\.rawValue)), ids.subtracting(webOnly))
    }
}

/// The menu bar the running app built, as AppKit sees it.
@MainActor
final class MenuBarTests: XCTestCase {
    private func items() -> [NSMenuItem] {
        func all(_ menu: NSMenu) -> [NSMenuItem] {
            // As AppKit asks before it shows a menu, for any filled in lazily.
            menu.delegate?.menuNeedsUpdate?(menu)
            return menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) }
        }
        return NSApp.mainMenu.map(all) ?? []
    }

    private func item(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        items().first { item in
            var mask = item.keyEquivalentModifierMask
            // AppKit also spells Shift as an upper-case key.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            return item.keyEquivalent.lowercased() == key && mask == modifiers
        }
    }

    func testTheSettingsSceneGivesCommandComma() {
        XCTAssertNotNil(item(","), "Settings… ⌘,")
    }

    func testUndoAndRedoAreTheAppsOwn() throws {
        // Not the standard undo:/redo: items, which ask WebKit's undo manager.
        XCTAssertNotEqual(try XCTUnwrap(item("z")).action, Selector(("undo:")))
        XCTAssertNotEqual(try XCTUnwrap(item("z", [.command, .shift])).action, Selector(("redo:")))
    }

    func testFindNextAndPreviousAreCommandG() throws {
        XCTAssertEqual(try XCTUnwrap(item("g")).title, "Find Next")
        XCTAssertEqual(try XCTUnwrap(item("g", [.command, .shift])).title, "Find Previous")
    }

    func testTheSidebarToggleIsCommandBackslash() throws {
        XCTAssertTrue(try XCTUnwrap(item("\\")).title.hasSuffix("Sidebar"))
    }

    func testTheBottomPanelIsTheBuildPanel() throws {
        let title = try XCTUnwrap(item("l", [.command, .shift])).title
        XCTAssertTrue(["Show Build Panel", "Hide Build Panel"].contains(title), title)
    }

    /// Replacing the text-editing group must keep the spelling commands the
    /// editor's WebKit spell checking answers to.
    func testSpellingIsInTheEditMenu() {
        XCTAssertNotNil(item(";"), "Check Document Now ⌘;")
        XCTAssertNotNil(item(":"), "Show Spelling and Grammar ⌘:")
    }
}

@MainActor
final class CoreTests: XCTestCase {
    func testCommandsRoundTripThroughTheRustCore() async throws {
        // The test scheme points TEXLOCAL_DATA at a scratch folder.
        XCTAssertNotNil(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        let core = Core.shared
        let name = "XCTest \(UUID().uuidString.prefix(8))"
        let info = try await core.call("create_project", ["name": name, "template": "blank"], as: ProjectInfo.self)
        XCTAssertEqual(info.mainFile, "main.tex")

        try await core.perform("write_file", ["id": info.id, "path": "a.tex", "text": "hé"])
        let file = try await core.call("read_file", ["id": info.id, "path": "a.tex"], as: FileText.self)
        XCTAssertEqual(file.text, "hé")

        let tree = try await core.call("file_tree", ["id": info.id], as: [TreeNode].self)
        XCTAssertTrue(tree.contains { $0.path == "a.tex" })

        do {
            _ = try await core.call("read_file", ["id": info.id, "path": "../../x"], as: FileText.self)
            XCTFail("a path outside the project must be refused")
        } catch let error as CoreError {
            XCTAssertEqual(error.status, 400)
        }

        // Not delete_project: it moves the folder to the Trash through Finder,
        // which a headless test host cannot drive. The core's own tests cover
        // that path; here the scratch project is simply removed.
        let data = try XCTUnwrap(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: data).appendingPathComponent(info.id))
    }
}
