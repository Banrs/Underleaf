import XCTest
@testable import TeXLocal

@MainActor
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

/// The counting rules are the core's (tests/fixtures/analyze.json); these
/// check what the views make of its outline.
@MainActor
final class OutlineTests: XCTestCase {
    func testTheBreadcrumbIsTheChainOfEnclosingHeadings() async throws {
        let outline = try await Outline.analyze("""
        \\chapter{A}
        \\section{B}
        \\subsection{C}
        \\section{D}
        text
        """).items
        XCTAssertEqual(Outline.chain(outline, at: 3).map(\.title), ["A", "B", "C"])
        XCTAssertEqual(Outline.chain(outline, at: 5).map(\.title), ["A", "D"])
        XCTAssertEqual(Outline.chain(outline, at: 0).map(\.title), [])
    }
}

@MainActor
final class OutlineDisplayTests: XCTestCase {
    func testDepthFollowsTheNestingNotTheLevel() async throws {
        // A subsection before any section has no parent: it sits flush, as
        // does the section after it; the subsection under that section is
        // one in.
        let outline = try await Outline.analyze("""
        \\subsection{}
        \\section{First Section}
        \\subsection{Detail}
        \\subsubsection{Finer}
        \\section{Second}
        """).items
        XCTAssertEqual(Outline.depths(outline), [0, 0, 1, 2, 0])
    }

    func testTheTreeNestsAsTheHeadingsDo() async throws {
        let outline = try await Outline.analyze("""
        \\subsection{}
        \\section{A}
        \\subsection{A1}
        \\subsection{A2}
        \\section{B}
        """).items
        let tree = Outline.tree(outline)
        XCTAssertEqual(tree.map(\.item.title), ["(untitled)", "A", "B"])
        XCTAssertNil(tree[0].children)
        XCTAssertEqual(tree[1].children?.map(\.item.title), ["A1", "A2"])
        XCTAssertNil(tree[2].children)
    }

    /// A fold is keyed by the heading's level, title and which of its
    /// namesakes it is, so headings added above leave it where it was.
    func testFoldKeysSurviveRenumbering() async throws {
        let text = "\\section{A}\n\\subsection{Results}\n\\section{B}\n\\subsection{Results}"
        let keys = Outline.foldKeys(try await Outline.analyze(text).items)
        XCTAssertEqual(keys, ["2:A#1", "3:Results#1", "2:B#1", "3:Results#2"])
        let later = Outline.foldKeys(try await Outline.analyze("\\section{New}\n\\subsection{Other}\n" + text).items)
        XCTAssertEqual(Array(later.dropFirst(2)), keys)
    }

    func testEmptyHeadingsAreNamedByKind() async throws {
        let outline = try await Outline.analyze("\\subsection{}\n\\chapter{}\n\\section{Named}").items
        XCTAssertEqual(outline.map(Outline.displayTitle), ["Untitled Subsection", "Untitled Chapter", "Named"])
    }
}

@MainActor
final class FindTests: XCTestCase {
    func testTheMatchCountLabel() {
        XCTAssertEqual(FindMatches(index: 3, total: 12).label(for: "loop"), "3 of 12")
        XCTAssertEqual(FindMatches(index: 0, total: 12).label(for: "loop"), "12 matches")
        XCTAssertEqual(FindMatches(index: 0, total: 1).label(for: "loop"), "1 match")
        XCTAssertEqual(FindMatches(index: 2, total: 1000, limited: true).label(for: "a"), "2 of 1000+")
        XCTAssertEqual(FindMatches().label(for: "loop"), "Not found")
        XCTAssertEqual(FindMatches().label(for: ""), "")
    }

    func testQueriesAreTrimmedAndCapped() {
        XCTAssertEqual(PDFFind.normalize("  theorem \n"), "theorem")
        XCTAssertEqual(PDFFind.normalize(" \t "), "")
        XCTAssertEqual(PDFFind.normalize(String(repeating: "a", count: 300)).count, 256)
    }
}
