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

/// The reading is the core's (tests/fixtures/analyze.json); these check what the
/// views make of its outline.
@MainActor
struct OutlineTests {
    /// Headings as the core sends them, "2:A" for a section A, one a line of main.tex.
    private func outline(_ headings: String...) -> [OutlineItem] {
        headings.enumerated().map { index, heading in
            let parts = heading.split(separator: ":", maxSplits: 1)
            return OutlineItem(id: index, level: Int(parts[0])!, title: String(parts[1]), line: index + 1, file: "main.tex")
        }
    }

    @Test func theChainIsTheEnclosingHeadings() {
        let outline = outline("1:A", "2:B", "3:C", "2:D")
        #expect(Outline.chain(outline, to: 2).map(\.title) == ["A", "B", "C"])
        #expect(Outline.chain(outline, to: 3).map(\.title) == ["A", "D"])
        #expect(Outline.chain(outline, to: nil).isEmpty)
    }

    /// A line is under its file's last heading above it, wherever the file is read in;
    /// above the file's first, under none.
    @Test func theCurrentHeadingFollowsTheFile() {
        let project = [OutlineItem(id: 0, level: 1, title: "A", line: 1, file: "main.tex"),
                       OutlineItem(id: 1, level: 2, title: "A1", line: 3, file: "a.tex"),
                       OutlineItem(id: 2, level: 2, title: "A2", line: 5, file: "a.tex"),
                       OutlineItem(id: 3, level: 1, title: "B", line: 9, file: "main.tex")]
        #expect(Outline.current(project, file: "a.tex", line: 6) == 2)
        #expect(Outline.current(project, file: "a.tex", line: 1) == nil)
        #expect(Outline.current(project, file: "main.tex", line: 8) == 0)
        #expect(Outline.current(project, file: "main.tex", line: 9) == 3)
        #expect(Outline.current(project, file: "notes.tex", line: 1) == nil)
    }

    /// A subsection before any section has no parent: it sits flush, as does
    /// the section after it; the subsection under that section is one in.
    @Test func theTreeNestsAsTheHeadingsDo() {
        let tree = Outline.tree(outline("3:(untitled)", "2:A", "3:A1", "4:A1a", "3:A2", "2:B"))
        #expect(tree.map(\.item).map(Outline.displayTitle) == ["Untitled Subsection", "A", "B"])
        #expect(tree[0].children == nil && tree[2].children == nil)
        #expect(tree[1].children?.map(\.item.title) == ["A1", "A2"])
        #expect(tree[1].children?[0].children?.map(\.item.title) == ["A1a"])
    }

    /// A fold is keyed by the heading's file, level, title and which of its
    /// namesakes there it is, so headings added above leave it where it was.
    @Test func foldKeysSurviveRenumbering() {
        let keys = Outline.foldKeys(outline("2:A", "3:Results", "2:B", "3:Results"))
        #expect(keys == ["main.tex\t2:A#1", "main.tex\t3:Results#1", "main.tex\t2:B#1", "main.tex\t3:Results#2"])
        let later = Outline.foldKeys(outline("2:New", "3:Other", "2:A", "3:Results", "2:B", "3:Results"))
        #expect(Array(later.dropFirst(2)) == keys)
    }
}

@MainActor
struct FindTests {
    @Test func theMatchCountLabel() {
        #expect(FindMatches(index: 3, total: 12).label(for: "loop") == "3 of 12")
        #expect(FindMatches(index: 0, total: 12).label(for: "loop") == "12 matches")
        #expect(FindMatches(index: 0, total: 1).label(for: "loop") == "1 match")
        #expect(FindMatches(index: 2, total: 1000, limited: true).label(for: "a") == "2 of 1,000+")
        #expect(FindMatches(index: 2290, total: 2290).label(for: "a") == "2,290 of 2,290")
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
    /// A bottom panel changes height, while PDFKit already preserves the page's top.
    @Test(arguments: [NSScroller.Style.overlay, .legacy])
    func heightOnlyResizeKeepsPDFKitsScrollPosition(_ style: NSScroller.Style) throws {
        let document = try pages(3)
        let native = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let view = SyncPDFView(frame: native.frame)
        for pdf in [native, view] {
            pdf.document = document
            try #require(pdf.documentView?.enclosingScrollView).scrollerStyle = style
            pdf.autoScales = true
            pdf.layoutDocumentView()
        }
        let nativeClip = try #require(native.documentView?.enclosingScrollView?.contentView)
        let clip = try #require(view.documentView?.enclosingScrollView?.contentView)
        for height in [500.0, 350, 500] {
            native.setFrameSize(NSSize(width: 600, height: height))
            view.setFrameSize(NSSize(width: 600, height: height))
            #expect(isClose(clip.bounds.minX, nativeClip.bounds.minX))
            #expect(isClose(clip.bounds.minY, nativeClip.bounds.minY))
            #expect(isClose(view.scaleFactor, native.scaleFactor))
        }
    }

    @Test func fittingHeightAgainAtTheSameSizeDoesNotRewritePDFKitState() throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.document = try pages(3)
        let controller = PDFController()
        controller.view = view
        controller.fitHeight()
        var automaticWrites = 0, scaleWrites = 0
        let automatic = view.observe(\.autoScales, options: .new) { _, _ in
            MainActor.assumeIsolated { automaticWrites += 1 }
        }
        let scale = view.observe(\.scaleFactor, options: .new) { _, _ in
            MainActor.assumeIsolated { scaleWrites += 1 }
        }
        controller.fitHeight()
        view.setFrameSize(view.frame.size)
        view.setFrameSize(NSSize(width: 800, height: 500))
        #expect(automaticWrites == 0 && scaleWrites == 0)
        #expect(controller.fit == .height)
        withExtendedLifetime((automatic, scale)) {}
    }

    /// Fit Height shows the whole page, its page-break margins too, and keeps it
    /// whole as the view resizes.
    @Test(arguments: [0.0, 37.0])
    func fitHeightKeepsTheWholePageInView(_ bottomInset: CGFloat) throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.additionalSafeAreaInsets.bottom = bottomInset
        // The pane's mode is PDFView's default.
        #expect(view.displayMode == .singlePageContinuous)
        view.displaysPageBreaks = true
        view.document = try pages(1)
        let controller = PDFController()
        controller.view = view
        controller.fitHeight()
        for height in [500.0, 380] {
            view.setFrameSize(NSSize(width: 600, height: height))
            view.layoutDocumentView()
            // In page space, magnified by the scale.
            let shown = try #require(view.documentView).frame.height * view.scaleFactor
            #expect(isClose(shown, height - bottomInset, within: 1), "pages \(shown) in \(height - bottomInset)")
            #expect(controller.fit == .height)
        }
    }

    /// The toolbar's percentage follows every zoom, a pinch's steps too (the scroll
    /// view's magnification, which posts no PDFViewScaleChanged until a pinch ends),
    /// and any scale but the fitted one ends fitting.
    @Test func theScaleFollowsEveryZoom() throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.autoScales = true
        view.document = try pages(3)
        let controller = PDFController()
        controller.view = view
        func follows(_ fit: PDFController.Fit?, _ step: String) {
            #expect(controller.scale == view.scaleFactor, "\(step)")
            #expect(controller.fit == fit, "\(step)")
        }
        follows(.width, "opened")
        view.setFrameSize(NSSize(width: 800, height: 500))
        view.layoutDocumentView()
        follows(.width, "resized")
        controller.zoom(in: true)
        follows(nil, "zoomed in")
        controller.fitHeight()
        follows(.height, "fit height")
        controller.setScale(1.5)
        follows(nil, "set")
        controller.fitWidth()
        follows(.width, "fit width")
        let scrollView = try #require(view.subviews.lazy.compactMap { $0 as? NSScrollView }.first)
        scrollView.magnification = 2
        follows(nil, "pinched")
        #expect(controller.scale == 2)
        // Back at the width while autoScales is still on, as through a pinch: fitted again.
        scrollView.magnification = view.scaleFactorForSizeToFit
        follows(.width, "pinched back")
    }

    /// The menus and the saved workspace read the project's own PDF view: Zoom In
    /// stops at PDFKit's limit, Go to PDF Position needs a .tex file, and a
    /// reopened project returns to the page shown.
    @Test func theMenusAndTheSavedPageReadTheProjectsPDF() throws {
        let app = AppModel()
        let project = ProjectModel(id: "PDFFitTests", app: app)
        (project.pdfVersion, project.pdfURL) = (1, URL(filePath: "/dev/null"))
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.document = try pages(3)
        project.pdf.view = view
        // A document's first page is current once it's set: a shown PDF's count comes from it.
        project.pdf.pageChanged()
        #expect(project.pdf.pageCount == 3)
        view.layoutDocumentView()
        project.pdf.setScale(view.maxScaleFactor)
        #expect(!app.isEnabled(.viewZoomIn, on: project))
        #expect(app.isEnabled(.viewZoomOut, on: project))
        project.openPath = "references.bib"
        #expect(!app.isEnabled(.syncForward, on: project))
        project.openPath = "main.tex"
        #expect(app.isEnabled(.syncForward, on: project))
        project.pdf.go(toPage: 2)
        project.pdf.pageChanged()
        #expect(project.saved.pdfPage == 2)
    }

    /// The context menu: Go to Source Position and the zooms, without PDFKit's page
    /// layouts and page turns.
    @Test func theContextMenuGoesToTheSourceAndZooms() throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.document = try pages(2)
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 300, y: 250), modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(view.menu(for: click))
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [MenuCommand.syncInverse.title, "-", "Zoom In", "Zoom Out"])
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

    /// SwiftUI sets the frame again, unchanged, on each of PDFKit's scroll steps:
    /// a step from the start stays. A new size at the start keeps the first page's
    /// top in view as the fitted scale changes.
    @Test func theStartKeepsOnlyOnANewSize() throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
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
        let first = try #require(view.document?.page(at: 0))
        let top = view.convert(CGPoint(x: 0, y: first.bounds(for: view.displayBox).maxY), from: first).y
        #expect(top <= view.bounds.maxY + view.pageBreakMargins.top * view.scaleFactor + 0.5, "top \(top)")
        #expect(top >= view.bounds.maxY - 0.5, "top \(top)")
    }

    /// Under a toolbar, as in the window: a rebuilt PDF, shown at the destination of
    /// what showed, doesn't move.
    @Test func theShownDestinationStaysPut() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar()
        let view = SyncPDFView(frame: try #require(window.contentView).bounds)
        window.contentView?.addSubview(view)
        // The scroll view's insets for the toolbar.
        window.layoutIfNeeded()
        view.autoScales = true
        view.document = try pages(3)
        view.layoutDocumentView()
        let clip = try #require(view.documentView?.enclosingScrollView?.contentView)
        #expect(clip.contentInsets.top > 0)
        view.go(to: PDFDestination(page: try #require(view.document?.page(at: 1)), at: CGPoint(x: 0, y: 400)))
        let place = clip.bounds.origin
        for _ in 0..<3 {
            view.go(to: try #require(view.shownDestination))
            #expect(abs(clip.bounds.minY - place.y) < 0.5, "\(clip.bounds.origin) from \(place)")
        }
    }

    /// App appearance does not recolor the PDF; PDFKit owns the background and scrollers.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func nativeRenderingPreservesTheDocumentColors(_ appearance: NSAppearance.Name) throws {
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
        let native = PDFView(frame: view.frame)
        view.backgroundColor = .windowBackgroundColor
        native.backgroundColor = .windowBackgroundColor
        view.appearance = NSAppearance(named: appearance)
        native.appearance = view.appearance
        view.document = document
        native.document = document
        #expect(view.backgroundColor == native.backgroundColor)
        #expect(view.pageShadowsEnabled == native.pageShadowsEnabled)
        #expect(view.documentView?.enclosingScrollView?.scrollerKnobStyle == native.documentView?.enclosingScrollView?.scrollerKnobStyle)
        #expect(view.documentView?.enclosingScrollView?.scrollerStyle == native.documentView?.enclosingScrollView?.scrollerStyle)
        let box = page.bounds(for: .cropBox)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width), pixelsHigh: Int(box.height),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.translateBy(x: -box.minX, y: -box.minY)
        view.draw(page, to: context)
        let white = try #require(bitmap.colorAt(x: 5, y: 5)), red = try #require(bitmap.colorAt(x: 15, y: 5))
        #expect(white.brightnessComponent > 0.95)
        #expect(red.redComponent > 0.95 && red.greenComponent < 0.05 && red.blueComponent < 0.05)
    }
}

/// Find in PDF across a rebuild, off screen.
@MainActor
struct PDFFindTests {
    /// Each page's text drawn as text, so PDFKit finds it.
    private func document(_ pages: [String], width: CGFloat = 612) throws -> PDFDocument {
        let document = PDFDocument()
        for text in pages {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 792))
            view.string = text
            let page = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
            document.insert(page, at: document.pageCount)
        }
        return document
    }

    /// Forward search flashes the word at the caret where it's nearest SyncTeX's
    /// box: on the box's line, a whole word before one run into others (as PDF
    /// text may run words TeX sets close), else the next line; nothing further off.
    @Test func theFlashFindsTheWordNearestTheBox() throws {
        // Kept: a page holds its document weakly.
        let pdf = try document(["alphabet alpha\nbeta\n\n\n\n\n\ngamma"]), page = try #require(pdf.page(at: 0))
        let text = try #require(page.string) as NSString
        func rect(_ range: NSRange) throws -> CGRect { try #require(page.selection(for: range)).bounds(for: page) }
        let first = try rect(text.range(of: "alphabet alpha")), second = try rect(text.range(of: "beta"))
        #expect(page.bounds(of: "alpha", near: first) == (try rect(text.range(of: "alpha", options: .backwards))))
        #expect(page.bounds(of: "beta", near: first) == second)
        #expect(page.bounds(of: "gamma", near: second) == nil)
    }

    /// A double-click sends the word, and where in it the click fell.
    @Test func aClickSendsTheWordAndTheLetter() throws {
        let pdf = try document(["alpha beta"]), page = try #require(pdf.page(at: 0))
        let text = try #require(page.string) as NSString
        let letter = try #require(page.selection(for: text.range(of: "e"))).bounds(for: page)
        let word = try #require(page.word(at: CGPoint(x: letter.midX, y: letter.midY)))
        #expect(word.0 == "beta" && word.offset == 1)
    }

    /// One source line spans many PDF rows, and SyncTeX can report a middle row first.
    @Test func forwardSearchRetainsRepeatedWordsAcrossWrappedRows() throws {
        let source = String(repeating: "An echo repeats in this sentence. ", count: 8)
        let pdf = try document([source], width: 180), page = try #require(pdf.page(at: 0))
        let rendered = try #require(page.string)
        let sourceRanges = source.ranges(of: "echo"), renderedRanges = rendered.ranges(of: "echo")
        #expect(sourceRanges.count == 8 && renderedRanges.count == 8)
        let lines = try #require(page.selection(for: NSRange(location: 0, length: (rendered as NSString).length))).selectionsByLine()
        let boxes = lines.map { line -> ForwardLoc in
            let rect = line.bounds(for: page)
            return ForwardLoc(page: 1, h: rect.minX, v: page.bounds(for: .cropBox).maxY - rect.minY, width: rect.width, height: rect.height)
        }
        #expect(boxes.count > 3)
        let nativeOrder = Array(boxes.dropFirst(boxes.count / 2)) + Array(boxes.prefix(boxes.count / 2))
        for index in [0, 3, 7] {
            let word = SyncTeXWord(text: "echo", offset: 0, context: source, contextOffset: NSRange(sourceRanges[index], in: source).location)
            let hit = try #require(pdf.bounds(of: word, near: nativeOrder))
            let expected = try #require(page.selection(for: NSRange(renderedRanges[index], in: rendered))).bounds(for: page)
            #expect(hit.page === page && hit.rect == expected)
        }
    }

    @Test func forwardSearchUsesTheReportedParagraphForIdenticalText() throws {
        let paragraph = "An echo repeats. An echo repeats. An echo repeats."
        let pdf = try document([paragraph + "\n\n" + paragraph], width: 180), page = try #require(pdf.page(at: 0))
        let rendered = try #require(page.string), occurrences = rendered.ranges(of: "echo")
        #expect(occurrences.count == 6)
        let expected = try #require(page.selection(for: NSRange(occurrences[5], in: rendered))).bounds(for: page)
        let loc = ForwardLoc(page: 1, h: expected.minX, v: page.bounds(for: .cropBox).maxY - expected.minY,
                             width: expected.width, height: expected.height)
        let word = SyncTeXWord(text: "echo", offset: 0, context: paragraph,
                              contextOffset: (paragraph as NSString).range(of: "echo", options: .backwards).location)
        let hit = try #require(pdf.bounds(of: word, near: [loc]))
        #expect(hit.page === page && hit.rect == expected)
        let inverse = try #require(page.syncWord(at: CGPoint(x: expected.midX, y: expected.midY)))
        #expect(inverse.text == "echo" && inverse.context == rendered)
        #expect(inverse.contextOffset == NSRange(occurrences[5], in: rendered).location)
        let start = NSRange(occurrences[3], in: rendered).location - 3 // "An " before this paragraph’s first echo.
        let lines = try #require(page.selection(for: NSRange(location: start, length: (rendered as NSString).length - start))).selectionsByLine()
        let boxes = lines.map { line -> ForwardLoc in
            let rect = line.bounds(for: page)
            return ForwardLoc(page: 1, h: rect.minX, v: page.bounds(for: .cropBox).maxY - rect.minY, width: rect.width, height: rect.height)
        }
        for index in 0..<3 {
            let word = SyncTeXWord(text: "echo", offset: 0, context: paragraph,
                                  contextOffset: NSRange(paragraph.ranges(of: "echo")[index], in: paragraph).location)
            let hit = try #require(pdf.bounds(of: word, near: boxes))
            #expect(hit.rect == (try #require(page.selection(for: NSRange(occurrences[index + 3], in: rendered)))).bounds(for: page))
        }
    }

    @Test func forwardSearchKeepsTheNativeBoxWhenMacroContextIsAmbiguous() throws {
        let pdf = try document(["echo echo"]), page = try #require(pdf.page(at: 0))
        let rendered = try #require(page.string)
        let rect = try #require(page.selection(for: NSRange(location: 0, length: (rendered as NSString).length))).bounds(for: page)
        let loc = ForwardLoc(page: 1, h: rect.minX, v: page.bounds(for: .cropBox).maxY - rect.minY, width: rect.width, height: rect.height)
        let word = SyncTeXWord(text: "echo", offset: 0, context: "\\LaTeX echo", contextOffset: 7)
        #expect(pdf.bounds(of: word, near: [loc]) == nil)
    }

    /// PDFKit searches off the main thread and posts what it finds to the main queue.
    private func found(_ controller: PDFController, in document: PDFDocument) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.matches.first?.pages.first?.document !== document, .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The bar stays: its matches are the new PDF's, the current one is kept,
    /// and the pages don't move.
    @Test func aRebuildFindsAgainInPlace() async throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let first = try document(["needle", "filler", "needle", "needle"])
        view.document = first
        let controller = PDFController()
        controller.view = view
        controller.finding = true
        controller.findText = "needle"
        controller.find(controller.findText)
        try await found(controller, in: first)
        controller.step(1)

        let rebuilt = try document(["needle", "needle", "filler", "needle", "needle"])
        view.document = rebuilt
        view.layoutDocumentView()
        let place = try #require(view.documentView).visibleRect
        controller.documentShown()
        try await found(controller, in: rebuilt)

        #expect(controller.finding)
        #expect(controller.matches.count == 4)
        #expect(controller.matches.allSatisfy { $0.pages.first?.document === rebuilt })
        #expect(controller.matchIndex == 1)
        #expect(view.currentSelection?.pages.first === controller.matches[1].pages.first)
        #expect(try #require(view.documentView).visibleRect == place)
    }
}
