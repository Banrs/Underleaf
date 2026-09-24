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
        XCTAssertFalse(ids.contains("edit.find"))
        XCTAssertFalse(ids.contains("edit.comment"))
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

        try await core.perform("delete_project", ["id": info.id])
    }
}
