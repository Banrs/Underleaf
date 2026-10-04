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
        #expect(tree.map(\.item.displayTitle) == ["Untitled Subsection", "A", "B"])
        #expect(tree[0].children == nil && tree[2].children == nil)
        #expect(tree[1].children?.map(\.item.title) == ["A1", "A2"])
        #expect(tree[1].children?[0].children?.map(\.item.title) == ["A1a"])
    }
}

/// Aa's levels: those the main file's class has, numbered and set as it sets them.
@MainActor
struct HeadingStylesTests {
    private func styles(_ name: String?, size: Int = 10, chapters: Bool = false) -> HeadingStyles {
        HeadingStyles(documentClass: name.map { DocumentClass(name: $0, pointSize: size) }, hasChapters: chapters)
    }

    private func markers(_ styles: HeadingStyles) -> [String?] {
        styles.levels.map(styles.marker)
    }

    @Test func theClassHasItsLevelsAndNumbersThem() {
        #expect(styles("article").levels.map(\.title) == ["Normal Text", "Part", "Section", "Subsection", "Subsubsection", "Paragraph"])
        #expect(markers(styles("article")) == [nil, "I", "1", "1.1", "1.1.1", nil])
        #expect(markers(styles("report")) == [nil, "I", "1", "1.1", "1.1.1", nil, nil])
        #expect(markers(styles("IEEEtran")) == [nil, "I", "A", "1", "a"])
        #expect(styles("IEEEtran").levels.map(\.title) == ["Normal Text", "Section", "Subsection", "Subsubsection", "Paragraph"])
        #expect(styles("letter").levels == [.normalText])
        // A class it doesn't know has every level, numbered as a book's once there are chapters.
        #expect(markers(styles("thesis", chapters: true)) == [nil, "I", "1", "1.1", "1.1.1", nil, nil])
        #expect(markers(styles(nil)) == [nil, "I", nil, "1", "1.1", "1.1.1", nil])
    }

    /// LaTeX's sizes against the text's, at the class's size option.
    @Test func theClassSetsTheLevelsSizes() {
        let book = styles("book"), part = HeadingLevel.sections[0], section = HeadingLevel.sections[2]
        #expect(book.font(part) == .init(scale: 2.488, bold: true, shape: .upright))
        #expect(abs(styles("article").font(part).scale - 2.074) < 0.001)
        #expect(abs(styles("article", size: 12).font(section).scale - 1.44) < 0.001)
        #expect(book.font(.normalText) == .init(scale: 1, bold: false, shape: .upright))
        #expect(styles("amsart").font(section) == .init(scale: 1, bold: false, shape: .smallCaps))
    }

    @Test func theClassIsTheOneNamedOutsideComments() {
        #expect(DocumentClass(in: "% \\documentclass{book}\n\\documentclass[11pt,\n a4paper]{ report }") == DocumentClass(name: "report", pointSize: 11))
        #expect(DocumentClass(in: "50\\% \\documentclass{book}") == DocumentClass(name: "book"))
        #expect(DocumentClass(in: "\\documentclass[fontsize=12pt]{scrartcl}")?.pointSize == 12)
        #expect(DocumentClass(in: "\\section{A}") == nil)
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

    @Test func fittingThePageAgainAtTheSameSizeDoesNotRewritePDFKitState() throws {
        let controller = PDFController()
        let view = controller.view
        view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try pages(3))
        controller.fitPage()
        var automaticWrites = 0, scaleWrites = 0
        let automatic = view.observe(\.autoScales, options: .new) { _, _ in
            MainActor.assumeIsolated { automaticWrites += 1 }
        }
        let scale = view.observe(\.scaleFactor, options: .new) { _, _ in
            MainActor.assumeIsolated { scaleWrites += 1 }
        }
        controller.fitPage()
        view.setFrameSize(view.frame.size)
        view.setFrameSize(NSSize(width: 800, height: 500))
        #expect(automaticWrites == 0 && scaleWrites == 0)
        #expect(controller.fit == .page)
        withExtendedLifetime((automatic, scale)) {}
    }

    /// Fit Page shows the whole page, its page-break margins too, and keeps it whole as
    /// the view resizes: by its height in a wide view, by its width in a narrow one; a page
    /// turned a quarter by its shape as shown (#25).
    @Test(arguments: [0.0, 37.0], [0, 90])
    func fitPageKeepsTheWholePageInView(_ bottomInset: CGFloat, _ rotation: Int) throws {
        let controller = PDFController()
        let view = controller.view
        view.setFrameSize(NSSize(width: 600, height: 500))
        view.additionalSafeAreaInsets.bottom = bottomInset
        // The pane's mode is PDFView's default.
        #expect(view.displayMode == .singlePageContinuous)
        view.displaysPageBreaks = true
        let document = try pages(1)
        document.page(at: 0)?.rotation = rotation
        controller.show(document)
        controller.fitPage()
        for (width, height) in [(600.0, 500.0), (600, 380), (300, 500), (420, 500), (1000, 300)] {
            view.setFrameSize(NSSize(width: width, height: height))
            view.layoutDocumentView()
            // In page space, magnified by the scale.
            let pages = try #require(view.documentView).frame.size
            let shown = CGSize(width: pages.width * view.scaleFactor, height: pages.height * view.scaleFactor)
            let room = CGSize(width: width, height: height - bottomInset)
            #expect(shown.width <= room.width + 1 && shown.height <= room.height + 1, "pages \(shown) in \(room)")
            #expect(isClose(shown.width, room.width, within: 1) || isClose(shown.height, room.height, within: 1),
                    "pages \(shown) in \(room)")
            #expect(controller.fit == .page)
        }
    }

    /// The toolbar's percentage follows every zoom, a pinch's steps too (the scroll
    /// view's magnification, which posts no PDFViewScaleChanged until a pinch ends),
    /// and any scale but the fitted one ends fitting.
    @Test func theScaleFollowsEveryZoom() throws {
        let controller = PDFController()
        let view = controller.view
        view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try pages(3))
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
        controller.fitPage()
        follows(.page, "fit page")
        controller.setScale(1.5)
        follows(nil, "set")
        controller.fitWidth()
        follows(.width, "fit width")
        let scrollView = try #require(view.documentView?.enclosingScrollView)
        scrollView.magnification = 2
        follows(nil, "pinched")
        #expect(controller.scale == 2)
        // Back at the width while autoScales is still on, as through a pinch: fitted again.
        scrollView.magnification = view.scaleFactorForSizeToFit
        follows(.width, "pinched back")
    }

    /// The first pinch's first step shows: the scroll view is watched from the first PDF.
    @Test func theScaleFollowsTheFirstPinch() throws {
        let controller = PDFController()
        controller.view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try pages(1))
        try #require(controller.view.documentView?.enclosingScrollView).magnification = 1.5
        #expect(controller.scale == 1.5 && controller.fit == nil)
    }

    /// The menus and the saved workspace read the project's own PDF view: Zoom In
    /// stops at PDFKit's limit, Go to PDF Position needs a .tex file, and a
    /// reopened project returns to the page shown.
    @Test func theMenusAndTheSavedPageReadTheProjectsPDF() throws {
        let app = AppModel()
        let project = ProjectModel(id: "PDFFitTests", app: app)
        project.pdfURL = URL(filePath: "/dev/null")
        let view = project.pdf.view
        project.pdf.restorePage = 3
        project.pdf.show(try pages(3))
        #expect(project.saved.pdfPage == 3)
        // The PDF can finish loading before SwiftUI gives the owned view its first size.
        view.setFrameSize(NSSize(width: 600, height: 500))
        view.layoutDocumentView()
        #expect(project.pdf.pageCount == 3)
        #expect(project.saved.pdfPage == 3)
        project.pdf.setScale(view.maxScaleFactor)
        #expect(!app.isEnabled(.viewZoomIn, on: project))
        #expect(app.isEnabled(.viewZoomOut, on: project))
        project.openPath = "references.bib"
        #expect(!app.isEnabled(.syncForward, on: project))
        project.openPath = "main.tex"
        #expect(app.isEnabled(.syncForward, on: project))
        project.pdf.go(toPage: 2)
        #expect(project.saved.pdfPage == 2)
    }

    /// A reopened project's PDF opens at the fit or scale it was left at, once it has a size,
    /// and a workspace saved before zooms were kept still opens.
    @Test(arguments: [PDFController.Zoom.fitPage, .scale(1.5), .fitWidth])
    func theSavedZoomComesBack(zoom: PDFController.Zoom) throws {
        let project = ProjectModel(id: "PDFFitTests", app: AppModel())
        project.pdfURL = URL(filePath: "/dev/null")
        project.pdf.restoreZoom = zoom
        project.pdf.show(try pages(3))
        // Kept until the view has a size to fit in.
        #expect(project.saved.pdfZoom == zoom)
        project.pdf.view.setFrameSize(NSSize(width: 600, height: 500))
        project.pdf.view.layoutDocumentView()
        #expect(project.pdf.restoreZoom == nil)
        #expect(project.saved.pdfZoom == zoom)
        if case .scale(let scale) = zoom { #expect(abs(project.pdf.view.scaleFactor - scale) < 0.001) }
        let old = Data(#"{"project":"p","line":1,"buildPanel":false,"pdfPage":2}"#.utf8)
        #expect(try JSONDecoder().decode(SavedWorkspace.self, from: old).pdfZoom == nil)
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

    /// A forward search marks SyncTeX's box beside the page, not with an annotation,
    /// which Print and VoiceOver would see.
    @Test func theForwardSearchMarkIsNoAnnotation() throws {
        let controller = PDFController()
        controller.view.setFrameSize(NSSize(width: 600, height: 500))
        let document = try pages(2)
        controller.show(document)
        controller.reveal(ForwardLoc(page: 1, h: 72, v: 150, width: 180, height: 10), word: nil)
        #expect(document.page(at: 0)?.annotations.isEmpty == true)
    }

    /// One mark at a time: a second search's replaces the first's, and a rebuilt PDF has none.
    @Test func aForwardSearchMarkReplacesTheLast() throws {
        let controller = PDFController()
        controller.view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try pages(2))
        controller.reveal(ForwardLoc(page: 1, h: 72, v: 150, width: 180, height: 10), word: nil)
        controller.reveal(ForwardLoc(page: 2, h: 72, v: 300, width: 180, height: 10), word: nil)
        #expect(controller.view.marks.count == 1)
        controller.show(try pages(2))
        #expect(controller.view.marks.isEmpty)
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

    /// App appearance does not recolor the PDF's paper or artwork.
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
        view.appearance = NSAppearance(named: appearance)
        view.document = document
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
@Suite(.serialized)
struct PDFFindTests {
    init() {
        // The system's find text is the user's: the tests keep their own.
        PDFFind.board = NSPasteboard.withUniqueName()
    }

    /// Three pages, each with "target" once.
    private func targets() throws -> PDFController {
        let controller = PDFController()
        controller.view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try document(["alpha target", "beta target", "gamma target"]))
        return controller
    }

    private func select(_ word: String, onPage index: Int, in controller: PDFController) throws {
        let page = try #require(controller.view.document?.page(at: index))
        let range = ((page.string ?? "") as NSString).range(of: word)
        controller.view.setCurrentSelection(try #require(page.selection(for: range)), animate: false)
    }

    /// Use Selection for Find makes the selection the system's find text and marks its
    /// matches, the selection's own the current one, without moving.
    @Test func useSelectionForFindStaysAtTheSelection() async throws {
        let controller = try targets()
        try select("target", onPage: 1, in: controller)
        #expect(controller.canUseSelectionForFind)
        controller.useSelectionForFind()
        try await waitUntil(timeout: .seconds(5)) { controller.query == "target" && controller.matches.count == 3 }
        #expect(controller.matchIndex == 1 && controller.finding && PDFFind.shared == "target")
    }

    /// Find Next with nothing searched yet searches for the system's find text, going on from
    /// the selection; with matches it steps through them.
    @Test func findNextGoesOnFromTheSelection() async throws {
        let controller = try targets()
        PDFFind.shared = "target"
        #expect(controller.canFindNext)
        try select("beta", onPage: 1, in: controller)
        controller.findNext(1)
        try await waitUntil(timeout: .seconds(5)) { controller.query == "target" && controller.matches.count == 3 }
        #expect(controller.matchIndex == 1)
        controller.findNext(1)
        #expect(controller.matchIndex == 2)
        controller.closeFind()
        try select("alpha", onPage: 0, in: controller)
        controller.findNext(-1)
        try await waitUntil(timeout: .seconds(5)) { controller.matches.count == 3 }
        // Nothing before the first page's: round to the last.
        #expect(controller.matchIndex == 2)
    }

    /// A new shared find term replaces an earlier PDF search; a just-typed PDF term wins over the older pasteboard.
    @Test(arguments: [1, -1]) func findNextUsesTheLatestSharedOrTypedText(_ step: Int) async throws {
        let controller = try targets()
        controller.findText = "alpha"
        controller.findTyped()
        try await waitUntil(timeout: .seconds(5)) { controller.query == "alpha" && controller.matches.count == 1 }
        PDFFind.shared = "target"
        controller.findNext(step)
        try await waitUntil(timeout: .seconds(5)) { controller.query == "target" && controller.matches.count == 3 }
        #expect(controller.findText == "target")

        controller.findText = "gamma" // Its typing debounce has not fired yet.
        controller.findNext(step)
        try await waitUntil(timeout: .seconds(5)) { controller.query == "gamma" && controller.matches.count == 1 }
        #expect(controller.findText == "gamma" && PDFFind.shared == "gamma")
    }

    /// Jump to Selection brings the PDF's selection into view, and is there only with one.
    @Test func jumpToSelectionShowsIt() throws {
        let controller = try targets()
        let view = controller.view
        let item = NSMenuItem(title: "Jump to Selection", action: #selector(NSResponder.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")
        #expect(!view.validate(item))
        try select("gamma", onPage: 2, in: controller)
        controller.go(toPage: 1)
        #expect(view.validate(item))
        view.centerSelectionInVisibleArea(nil)
        #expect(view.currentPage === view.document?.page(at: 2))
        // PDFKit's own items keep PDFKit's answer.
        #expect(view.validate(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")))
    }

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

    @Test func rebuildSearchesCurrentFindText() async throws {
        let controller = PDFController()
        controller.view.setFrameSize(NSSize(width: 600, height: 500))
        let first = try document(["old result"])
        let second = try document(["new result"])
        controller.show(first)
        controller.finding = true
        controller.findText = "old"
        controller.find("old")
        try await waitUntil(timeout: .seconds(5)) {
            controller.query == "old" && controller.matches.first?.pages.first?.document === first
        }

        // The field changed, but its debounce has not started a new search yet.
        controller.findText = "new"
        controller.show(second)
        try await waitUntil(timeout: .seconds(5)) {
            controller.query == "new" && controller.matches.first?.pages.first?.document === second
        } state: {
            "query \(controller.query), matches \(controller.matches.count)"
        }
        #expect(controller.matches.count == 1)
    }

    /// Find ignores case and accents, as typed without them.
    @Test func findIgnoresCaseAndAccents() async throws {
        let controller = PDFController()
        controller.view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try document(["Gödel and Erdős"]))
        controller.find("godel")
        try await waitUntil(timeout: .seconds(5)) { controller.query == "godel" && controller.matches.count == 1 }
        controller.find("ERDOS")
        try await waitUntil(timeout: .seconds(5)) { controller.query == "ERDOS" && controller.matches.count == 1 }
    }

    /// Typing back to the found text while a longer one is searched ends with the field's matches.
    @Test func typingBackKeepsTheFieldsMatches() async throws {
        let controller = PDFController()
        controller.view.setFrameSize(NSSize(width: 600, height: 500))
        controller.show(try document(["a ab a"]))
        controller.finding = true
        controller.findText = "a"
        controller.findTyped()
        try await waitUntil { controller.query == "a" && controller.matches.count == 3 }
        controller.findText = "ab"
        controller.findTyped()
        controller.findText = "a"
        controller.findTyped()
        try await waitUntil { controller.query == "a" && controller.matches.count == 3 }
        // The longer search, had it gone on, would have ended by now.
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.query == "a" && controller.matches.count == 3)
    }

    /// A double-click sends the word, and where in it the click fell.
    @Test func aClickSendsTheWordAndTheLetter() throws {
        let pdf = try document(["alpha beta"]), page = try #require(pdf.page(at: 0))
        let text = try #require(page.string) as NSString
        let letter = try #require(page.selection(for: text.range(of: "e"))).bounds(for: page)
        // A page holds its document weakly; it's the view's in the app.
        let word = try #require(withExtendedLifetime(pdf) { page.syncWord(at: CGPoint(x: letter.midX, y: letter.midY)) })
        #expect(word.text == "beta" && word.offset == 1)
    }

    /// PDFKit's word lookup crashes on a page whose document has gone; it has no word.
    @Test func aPageWithoutItsDocumentHasNoWord() throws {
        let page = try autoreleasepool { try #require(try document(["alpha beta"]).page(at: 0)) }
        #expect(page.document == nil)
        #expect(page.syncWord(at: CGPoint(x: 10, y: 10)) == nil)
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
            let hit = try #require(pdf.match(for: word, near: nativeOrder))
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
        let hit = try #require(pdf.match(for: word, near: [loc]))
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
            let hit = try #require(pdf.match(for: word, near: boxes))
            #expect(hit.rect == (try #require(page.selection(for: NSRange(occurrences[index + 3], in: rendered)))).bounds(for: page))
        }
    }

    @Test func forwardSearchKeepsTheNativeBoxWhenMacroContextIsAmbiguous() throws {
        let pdf = try document(["echo echo"]), page = try #require(pdf.page(at: 0))
        let rendered = try #require(page.string)
        let rect = try #require(page.selection(for: NSRange(location: 0, length: (rendered as NSString).length))).bounds(for: page)
        let loc = ForwardLoc(page: 1, h: rect.minX, v: page.bounds(for: .cropBox).maxY - rect.minY, width: rect.width, height: rect.height)
        let word = SyncTeXWord(text: "echo", offset: 0, context: "\\LaTeX echo", contextOffset: 7)
        #expect(pdf.match(for: word, near: [loc]) == nil)
    }

    /// PDFKit searches off the main thread and posts what it finds to the main queue.
    private func found(_ controller: PDFController, in document: PDFDocument) async throws {
        try await waitUntil(timeout: .seconds(5)) {
            controller.matches.first?.pages.first?.document === document
        }
    }

    /// The bar stays: its matches are the new PDF's, the current one is kept,
    /// and the pages don't move.
    @Test(arguments: [NSScroller.Style.overlay, .legacy], [CGFloat?.none, 1.75])
    func aRebuildFindsAgainInPlace(_ scrollerStyle: NSScroller.Style, _ scale: CGFloat?) async throws {
        let controller = PDFController()
        let view = controller.view
        view.setFrameSize(NSSize(width: 600, height: 500))
        try #require(view.subviews.compactMap { $0 as? NSScrollView }.first).scrollerStyle = scrollerStyle
        let first = try document(["needle", "filler", "needle", "needle"])
        controller.show(first)
        if let scale { controller.setScale(scale) }
        controller.finding = true
        controller.findText = "needle"
        controller.find(controller.findText)
        try await found(controller, in: first)
        controller.step(1)
        view.layoutDocumentView()
        let page = first.index(for: try #require(view.currentPage))
        try #require(page > 0)
        let place = try #require(view.documentView).visibleRect

        for _ in 0..<4 {
            let rebuilt = try document(["needle", "needle", "filler", "needle", "needle"])
            controller.show(rebuilt)
            view.layoutDocumentView()
            try await found(controller, in: rebuilt)

            #expect(controller.finding)
            #expect(controller.matches.count == 4)
            #expect(controller.matches.allSatisfy { $0.pages.first?.document === rebuilt })
            #expect(controller.matchIndex == 1)
            #expect(view.currentSelection?.pages.first === controller.matches[1].pages.first)
            #expect(rebuilt.index(for: try #require(view.currentPage)) == page)
            let current = try #require(view.documentView).visibleRect
            #expect(isClose(current.minX, place.minX) && isClose(current.minY, place.minY),
                    "viewport before rebuild \(place), after \(current)")
        }
    }
}
