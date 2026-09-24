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
        XCTAssertTrue(ids.contains("view.uiScaleUp"))
        XCTAssertFalse(ids.contains("edit.find"))
        XCTAssertFalse(ids.contains("edit.comment"))
        XCTAssertFalse(ids.contains("edit.undo"))
        XCTAssertFalse(ids.contains("edit.redo"))
    }

    /// A file of the repository this test was built from.
    private func repo(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    /// The menu has every command the web declares, with the same chord —
    /// except Settings…, which the Settings scene adds with ⌘, itself.
    func testTheMenuHasEveryWebCommand() throws {
        let source = try String(contentsOf: repo("web/src/workspace.js"), encoding: .utf8)
        var ids: Set<String> = []
        for line in source.split(separator: "\n") {
            guard let match = line.firstMatch(of: /\{ id: '([^']+)'/) else { continue }
            let id = String(match.1)
            ids.insert(id)
            guard id != "app.settings" else { continue }
            let accel = line.firstMatch(of: /accel: '([^']+)'/)
                .map { String($0.1).replacingOccurrences(of: "\\\\", with: "\\") }
            XCTAssertEqual(MenuCommand(rawValue: id)?.accel, accel, id)
        }
        XCTAssertEqual(Set(MenuCommand.allCases.map(\.rawValue)), ids.subtracting(["app.settings"]))
    }

    @MainActor
    func testInterfaceSizesAreTheWebs() throws {
        let source = try String(contentsOf: repo("web/src/prefs.js"), encoding: .utf8)
        let list = try XCTUnwrap(source.firstMatch(of: /UI_SCALES = \[([^\]]*)\]/)?.1)
        XCTAssertEqual(list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }, AppModel.uiScales)
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
