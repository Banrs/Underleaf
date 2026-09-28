import Foundation
import Testing
@testable import TeXLocal

@MainActor
struct SyncTeXGeometryTests {
    // A US Letter page whose box starts at the origin, and one offset the way
    // some producers write a crop box.
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    let offset = CGRect(x: 10, y: 20, width: 612, height: 792)

    @Test func theForwardBoxFlipsFromTopLeftToBottomLeft() {
        let loc = ForwardLoc(page: 1, h: 72, v: 100, width: 468, height: 10)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: letter)
        // Baseline 100pt below the top edge is 692pt above the bottom edge.
        #expect(rect == CGRect(x: 70, y: 690, width: 472, height: 14))
    }

    @Test func theForwardBoxIsNeverNarrowerThanAWord() {
        let loc = ForwardLoc(page: 1, h: 72, v: 100, width: 0, height: nil)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: letter)
        #expect(rect.size == CGSize(width: 28, height: 16))
    }

    @Test func theInversePointRoundTripsThroughAnOffsetBox() {
        let synctex = SyncTeXGeometry.synctexPoint(CGPoint(x: 82, y: 712), pageBounds: offset)
        #expect(synctex == CGPoint(x: 72, y: 100))
        let loc = ForwardLoc(page: 1, h: synctex.x, v: synctex.y, width: 0, height: 0)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: offset)
        #expect(CGPoint(x: rect.minX + 2, y: rect.minY + 2) == CGPoint(x: 82, y: 712))
    }
}

/// The counting rules are the core's (tests/fixtures/analyze.json); these
/// check what the views make of its outline.
@MainActor
struct OutlineTests {
    private func outline(_ text: String) async throws -> [OutlineItem] {
        try await Outline.analyze(text).items
    }

    @Test func theBreadcrumbIsTheChainOfEnclosingHeadings() async throws {
        let outline = try await outline("\\chapter{A}\n\\section{B}\n\\subsection{C}\n\\section{D}\ntext")
        #expect(Outline.chain(outline, at: 3).map(\.title) == ["A", "B", "C"])
        #expect(Outline.chain(outline, at: 5).map(\.title) == ["A", "D"])
        #expect(Outline.chain(outline, at: 0).isEmpty)
    }

    /// A subsection before any section has no parent: it sits flush, as does
    /// the section after it; the subsection under that section is one in.
    @Test func depthFollowsTheNestingNotTheLevel() async throws {
        let outline = try await outline(
            "\\subsection{}\n\\section{First Section}\n\\subsection{Detail}\n\\subsubsection{Finer}\n\\section{Second}")
        #expect(Outline.depths(outline) == [0, 0, 1, 2, 0])
    }

    @Test func theTreeNestsAsTheHeadingsDo() async throws {
        let tree = Outline.tree(try await outline("\\subsection{}\n\\section{A}\n\\subsection{A1}\n\\subsection{A2}\n\\section{B}"))
        #expect(tree.map(\.item).map(Outline.displayTitle) == ["Untitled Subsection", "A", "B"])
        #expect(tree[0].children == nil)
        #expect(tree[1].children?.map(\.item.title) == ["A1", "A2"])
        #expect(tree[2].children == nil)
    }

    /// A fold is keyed by the heading's level, title and which of its
    /// namesakes it is, so headings added above leave it where it was.
    @Test func foldKeysSurviveRenumbering() async throws {
        let text = "\\section{A}\n\\subsection{Results}\n\\section{B}\n\\subsection{Results}"
        let keys = Outline.foldKeys(try await outline(text))
        #expect(keys == ["2:A#1", "3:Results#1", "2:B#1", "3:Results#2"])
        let later = Outline.foldKeys(try await outline("\\section{New}\n\\subsection{Other}\n" + text))
        #expect(Array(later.dropFirst(2)) == keys)
    }

    @Test func emptyHeadingsAreNamedByKind() async throws {
        let outline = try await outline("\\subsection{}\n\\chapter{}\n\\section{Named}")
        #expect(outline.map(Outline.displayTitle) == ["Untitled Subsection", "Untitled Chapter", "Named"])
    }
}

@MainActor
struct FindTests {
    @Test func theMatchCountLabel() {
        #expect(FindMatches(index: 3, total: 12).label(for: "loop") == "3 of 12")
        #expect(FindMatches(index: 0, total: 12).label(for: "loop") == "12 matches")
        #expect(FindMatches(index: 0, total: 1).label(for: "loop") == "1 match")
        #expect(FindMatches(index: 2, total: 1000, limited: true).label(for: "a") == "2 of 1000+")
        #expect(FindMatches().label(for: "loop") == "Not found")
        #expect(FindMatches().label(for: "").isEmpty)
    }

    @Test func queriesAreTrimmedAndCapped() {
        #expect(PDFFind.normalize("  theorem \n") == "theorem")
        #expect(PDFFind.normalize(" \t ").isEmpty)
        #expect(PDFFind.normalize(String(repeating: "a", count: 300)).count == PDFFind.maxQuery)
    }
}
