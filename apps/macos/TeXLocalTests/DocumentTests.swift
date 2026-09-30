import Foundation
import PDFKit
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
    @Test func theTreeNestsAsTheHeadingsDo() async throws {
        let tree = Outline.tree(try await outline(
            "\\subsection{}\n\\section{A}\n\\subsection{A1}\n\\subsubsection{A1a}\n\\subsection{A2}\n\\section{B}"))
        #expect(tree.map(\.item).map(Outline.displayTitle) == ["Untitled Subsection", "A", "B"])
        #expect(tree[0].children == nil && tree[2].children == nil)
        #expect(tree[1].children?.map(\.item.title) == ["A1", "A2"])
        #expect(tree[1].children?[0].children?.map(\.item.title) == ["A1a"])
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

/// The PDF view's fits, off screen.
@MainActor
struct PDFFitTests {
    /// Fit Height shows the whole page, its page-break margins too, and keeps it
    /// whole as the view resizes.
    @Test func fitHeightKeepsTheWholePageInView() throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        let image = NSImage(size: NSSize(width: 612, height: 792), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        view.document = document
        let controller = PDFController()
        controller.view = view
        controller.fitHeight()
        for height in [500.0, 380] {
            view.setFrameSize(NSSize(width: 600, height: height))
            view.layoutDocumentView()
            // In page space, magnified by the scale.
            let shown = try #require(view.documentView).frame.height * view.scaleFactor
            #expect(isClose(shown, height, within: 1), "pages \(shown) in \(height)")
            #expect(controller.fit == .height)
        }
    }

    private func pages(_ count: Int) throws -> PDFDocument {
        let image = NSImage(size: NSSize(width: 612, height: 792), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let document = PDFDocument()
        for index in 0..<count { document.insert(try #require(PDFPage(image: image)), at: index) }
        return document
    }

    /// The first page's top, in the view.
    private func firstTop(_ view: PDFView) throws -> CGFloat {
        let page = try #require(view.document?.page(at: 0))
        return view.convert(CGPoint(x: 0, y: page.bounds(for: view.displayBox).maxY), from: page).y
    }

    /// SwiftUI sets the frame again, unchanged, on each of PDFKit's scroll steps:
    /// a step from the start stays. A new size at the start keeps the first page's
    /// top in view as the fitted scale changes.
    @Test func theStartKeepsOnlyOnANewSize() throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.document = try pages(3)
        view.layoutDocumentView()
        let clip = try #require(view.documentView?.enclosingScrollView?.contentView)
        let start = clip.bounds.origin
        clip.scroll(to: CGPoint(x: start.x, y: start.y + (clip.isFlipped ? 0.5 : -0.5)))
        let stepped = clip.bounds.origin
        #expect(stepped != start)
        view.setFrameSize(view.frame.size)
        #expect(clip.bounds.origin == stepped)

        clip.scroll(to: start)
        let scale = view.scaleFactor
        view.setFrameSize(NSSize(width: 900, height: 500))
        view.layoutDocumentView()
        #expect(view.scaleFactor > scale)
        let top = try firstTop(view)
        #expect(top <= view.bounds.maxY + view.pageBreakMargins.top * view.scaleFactor + 0.5, "top \(top)")
        #expect(top >= view.bounds.maxY - 0.5, "top \(top)")
    }

    /// Dark paper draws into the tiles: white turns black, and a hue is kept.
    /// The knob follows the paper.
    @Test func darkPaperInvertsTheLightnessOnly() throws {
        let image = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 10, height: 10).fill()
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            NSRect(x: 10, y: 0, width: 10, height: 10).fill()
            return true
        }
        let page = try #require(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.document = document
        let box = page.bounds(for: .cropBox)
        func drawn(dark: Bool) throws -> (white: NSColor, red: NSColor) {
            view.darkPaper = dark
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width), pixelsHigh: Int(box.height),
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
            context.translateBy(x: -box.minX, y: -box.minY)
            view.draw(page, to: context)
            return (try #require(bitmap.colorAt(x: 5, y: 5)), try #require(bitmap.colorAt(x: 15, y: 5)))
        }
        let dark = try drawn(dark: true)
        #expect(dark.white.brightnessComponent < 0.05)
        #expect(dark.red.redComponent > dark.red.greenComponent + 0.2, "\(dark.red)")
        #expect(view.documentView?.enclosingScrollView?.scrollerKnobStyle == .light)
        let white = try drawn(dark: false)
        #expect(white.white.brightnessComponent > 0.95)
        #expect(view.documentView?.enclosingScrollView?.scrollerKnobStyle == .dark)
    }
}

/// Find in PDF across a rebuild, off screen.
@MainActor
struct PDFFindTests {
    /// Each page's text drawn as text, so PDFKit finds it.
    private func document(_ pages: [String]) throws -> PDFDocument {
        let document = PDFDocument()
        for text in pages {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            view.string = text
            let page = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
            document.insert(page, at: document.pageCount)
        }
        return document
    }

    /// The bar stays: its matches are the new PDF's, the current one is kept,
    /// and the pages don't move.
    @Test func aRebuildFindsAgainInPlace() throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.displayMode = .singlePageContinuous
        view.document = try document(["needle", "filler", "needle", "needle"])
        let controller = PDFController()
        controller.view = view
        controller.finding = true
        controller.findText = "needle"
        controller.find(controller.findText)
        controller.step(1)

        let rebuilt = try document(["needle", "needle", "filler", "needle", "needle"])
        view.document = rebuilt
        view.layoutDocumentView()
        let place = try #require(view.documentView).visibleRect
        controller.documentShown()

        #expect(controller.finding)
        #expect(controller.matches.count == 4)
        #expect(controller.matches.allSatisfy { $0.pages.first?.document === rebuilt })
        #expect(controller.matchIndex == 1)
        #expect(view.currentSelection?.pages.first === controller.matches[1].pages.first)
        #expect(try #require(view.documentView).visibleRect == place)
    }
}
