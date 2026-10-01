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
    /// Both fits follow viewport and native layout changes; a user zoom leaves the fit.
    @Test(arguments: [PDFDisplayMode.singlePageContinuous, .singlePage, .twoUpContinuous, .twoUp])
    func fittingAndZoomingUsePDFKit(_ mode: PDFDisplayMode) throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.displayMode = mode
        view.document = try pages(3)
        let controller = PDFController()
        controller.view = view
        for fit in [PDFController.Fit.width, .height] {
            view.displayMode = mode
            if fit == .width { controller.fitWidth() } else { controller.fitHeight() }
            for size in [NSSize(width: 600, height: 500), NSSize(width: 720, height: 640)] {
                view.setFrameSize(size)
                view.additionalSafeAreaInsets.top = 40
                view.layoutSubtreeIfNeeded()
                let row = view.rowSize(for: try #require(view.currentPage))
                #expect(isClose(fit == .width ? row.width : row.height,
                                fit == .width ? view.viewportSize.width : view.viewportSize.height, within: 1))
                #expect(controller.fit == fit && controller.scale == view.scaleFactor)
            }
            view.displayMode = mode == .twoUp ? .singlePage : .twoUp
            view.displaysAsBook = true
            view.displayDirection = .horizontal
            view.currentPage?.rotation = 90
            view.layoutDocumentView()
            let row = view.rowSize(for: try #require(view.currentPage))
            #expect(isClose(fit == .width ? row.width : row.height,
                            fit == .width ? view.viewportSize.width : view.viewportSize.height, within: 1))
            controller.setDocument(try pages(2))
            #expect(controller.fit == fit)
        }
        view.scaleFactor *= 1.2
        #expect(controller.fit == nil && controller.scale == view.scaleFactor)
        controller.setScale(1.5)
        #expect(view.scaleFactor == 1.5 && controller.scale == 1.5)
        view.setFrameSize(NSSize(width: 800, height: 500))
        view.layoutSubtreeIfNeeded()
        controller.setDocument(try pages(3))
        #expect(view.scaleFactor == 1.5 && controller.fit == nil)
        controller.zoom(in: true)
        #expect(controller.scale == view.scaleFactor && controller.fit == nil)
        view.displayMode = .singlePage
        view.autoScales = true
        #expect(controller.fit == nil)
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

    /// SyncTeX navigation extends PDFKit's native context menu.
    @Test func theContextMenuGoesToTheSource() throws {
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.document = try pages(2)
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 300, y: 250), modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(view.menu(for: click))
        #expect(menu.items.first?.title == MenuCommand.syncInverse.title)
        #expect(menu.items.count > 1)
        #expect(menu.allowsContextMenuPlugIns)
        let label = NSTextField(labelWithString: "Some words")
        view.document = try #require(PDFDocument(data: label.dataWithPDF(inside: NSRect(x: 0, y: 0, width: 100, height: 30))))
        view.setCurrentSelection(view.document?.findString("words").first, animate: false)
        #expect(try #require(view.menu(for: click)).items.contains { $0.action == #selector(PDFView.copy(_:)) })
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

    /// Dark paper draws into the tiles: white turns black, and a hue is kept.
    /// The knob follows the paper, and VoiceOver names the pane.
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
        #expect(view.documentView?.enclosingScrollView?.accessibilityLabel() == "PDF")
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

    /// SyncTeX navigation resolves the clicked word and letter.
    @Test func aClickSendsTheWordAndTheLetter() throws {
        let pdf = try document(["alpha beta"]), page = try #require(pdf.page(at: 0))
        let text = try #require(page.string) as NSString
        let letter = try #require(page.selection(for: text.range(of: "e"))).bounds(for: page)
        let word = try #require(page.word(at: CGPoint(x: letter.midX, y: letter.midY)))
        #expect(word.0 == "beta" && word.offset == 1)
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
