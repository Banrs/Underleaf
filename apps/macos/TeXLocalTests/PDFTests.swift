import Foundation
import PDFKit
import Testing
@testable import TeXLocal

struct SyncTeXGeometryTests {
    let offset = CGRect(x: 10, y: 20, width: 612, height: 792)

    @Test func theInversePointRoundTripsThroughAnOffsetBox() {
        let synctex = SyncTeXGeometry.synctexPoint(CGPoint(x: 82, y: 712), pageBounds: offset)
        #expect(synctex == CGPoint(x: 72, y: 100))
        let loc = ForwardLoc(page: 1, h: synctex.x, v: synctex.y, width: 0, height: 0)
        let rect = SyncTeXGeometry.highlightRect(loc, pageBounds: offset)
        #expect(CGPoint(x: rect.minX + 2, y: rect.minY + 2) == CGPoint(x: 82, y: 712))
    }
}

struct FindTests {
    @Test func theMatchCountLabel() {
        #expect(PDFFind.count(3, of: 12, limited: false, for: "loop") == "3 of 12")
        #expect(PDFFind.count(2, of: 1000, limited: true, for: "a") == "2 of 1,000+")
        #expect(PDFFind.count(2290, of: 2290, limited: false, for: "a") == "2,290 of 2,290")
        #expect(PDFFind.count(1, of: 0, limited: false, for: "loop") == "Not found")
        #expect(PDFFind.count(1, of: 0, limited: false, for: "").isEmpty)
    }
}

struct PDFFitTests {
    @Test(arguments: zip([CGFloat(0), 37], [0, 90]))
    func fitPageKeepsTheWholePageInView(_ bottomInset: CGFloat, _ rotation: Int) throws {
        let controller = sizedController(), view = controller.view
        view.additionalSafeAreaInsets.bottom = bottomInset
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
            #expect(controller.zoom == .fitPage)
        }
    }

    /// A pinch's steps are the scroll view's magnification, which posts no PDFViewScaleChanged until a pinch ends.
    @Test func theScaleFollowsEveryZoom() throws {
        let controller = showing(try pages(3)), view = controller.view
        /// Off a fit, the zoom is the scale.
        func follows(_ fit: PDFController.Zoom?, _ step: String) {
            let zoom = fit ?? .scale(Double(view.scaleFactor))
            #expect(controller.scale == view.scaleFactor && controller.zoom == zoom, "\(step)")
        }
        follows(.fitWidth, "opened")
        view.setFrameSize(NSSize(width: 800, height: 500))
        view.layoutDocumentView()
        follows(.fitWidth, "resized")
        controller.zoom(in: true)
        follows(nil, "zoomed in")
        controller.fitPage()
        follows(.fitPage, "fit page")
        controller.setScale(1.5)
        follows(nil, "set")
        controller.fitWidth()
        follows(.fitWidth, "fit width")
        let scrollView = try #require(view.documentView?.enclosingScrollView)
        scrollView.magnification = 2
        follows(nil, "pinched")
        #expect(controller.scale == 2)
        // Back at the width while autoScales is still on, as through a pinch: fitted again.
        scrollView.magnification = view.scaleFactorForSizeToFit
        follows(.fitWidth, "pinched back")
    }

    @Test func theMenusAndTheSavedPageReadTheProjectsPDF() throws {
        let app = AppModel()
        let project = ProjectModel(id: "PDFFitTests", app: app)
        project.shown = .build(URL(filePath: "/dev/null"))
        let view = project.pdf.view
        project.pdf.restorePage = 3
        project.pdf.show(try pages(3))
        #expect(project.saved.pdfPage == 3)
        // The PDF can finish loading before SwiftUI gives the owned view its first size.
        view.setFrameSize(NSSize(width: 600, height: 500))
        view.layoutDocumentView()
        #expect(project.pdf.pageCount == 3 && project.saved.pdfPage == 3)
        project.pdf.setScale(view.maxScaleFactor)
        #expect(!app.isEnabled(.viewZoomIn, on: project) && app.isEnabled(.viewZoomOut, on: project))
        project.tree.show(.sources)
        project.openPath = "references.bib"
        #expect(!app.isEnabled(.syncForward, on: project))
        project.openPath = "main.tex"
        #expect(app.isEnabled(.syncForward, on: project))
        project.pdf.go(toPage: 2)
        #expect(project.saved.pdfPage == 2)
    }

    @Test func goToPageKeepsToTheDocument() throws {
        let controller = sizedController()
        controller.go(toPage: 2)
        #expect(controller.page == 0)
        controller.show(try pages(3))
        controller.view.layoutDocumentView()
        controller.go(toPage: 9)
        #expect(controller.page == 3)
        controller.go(toPage: 0)
        #expect(controller.page == 1)
    }

    @Test(arguments: [PDFController.Zoom.fitPage, .scale(1.5), .fitWidth])
    func theSavedZoomComesBack(zoom: PDFController.Zoom) throws {
        let project = ProjectModel(id: "PDFFitTests", app: AppModel())
        project.shown = .build(URL(filePath: "/dev/null"))
        project.pdf.restoreZoom = zoom
        project.pdf.show(try pages(3))
        // Kept until the view has a size to fit in.
        #expect(project.saved.pdfZoom == zoom)
        project.pdf.view.setFrameSize(NSSize(width: 600, height: 500))
        project.pdf.view.layoutDocumentView()
        #expect(project.pdf.restoreZoom == nil && project.saved.pdfZoom == zoom)
        if case .scale(let scale) = zoom { #expect(abs(project.pdf.view.scaleFactor - scale) < 0.001) }
        let old = Data(#"{"project":"p","line":1,"buildPanel":false,"pdfPage":2}"#.utf8)
        #expect(try JSONDecoder().decode(SavedWorkspace.self, from: old).pdfZoom == nil)
    }

    /// The mark is beside the page, not an annotation, which Print and VoiceOver would see.
    @Test func theForwardSearchMarkIsOneAndNoAnnotation() throws {
        let document = try pages(2)
        let controller = showing(document)
        controller.reveal(ForwardLoc(page: 1, h: 72, v: 150, width: 180, height: 10))
        #expect(document.page(at: 0)?.annotations.isEmpty == true)
        controller.reveal(ForwardLoc(page: 2, h: 72, v: 300, width: 180, height: 10))
        #expect(controller.view.mark != nil)
        controller.show(try pages(2))
        #expect(controller.view.mark == nil)
    }

    /// Blank US Letter pages.
    private func pages(_ count: Int) throws -> PDFDocument { try textPDF(Array(repeating: "", count: count)) }
}

@Suite(.serialized)
struct PDFFindTests {
    init() {
        // The system's find text is the user's: the tests keep their own.
        PDFFind.board = NSPasteboard.withUniqueName()
    }

    private func targets() throws -> PDFController {
        showing(try textPDF(["alpha target", "beta target", "gamma target"]))
    }

    private func select(_ word: String, onPage index: Int, in controller: PDFController) throws {
        let page = try #require(controller.view.document?.page(at: index))
        let range = ((page.string ?? "") as NSString).range(of: word)
        controller.view.setCurrentSelection(page.selection(for: range), animate: false)
    }

    @Test func useSelectionForFindStaysAtTheSelection() async throws {
        let controller = try targets()
        try select("target", onPage: 1, in: controller)
        #expect(controller.find.canUseSelection)
        controller.find.useSelection()
        try await waitUntil(timeout: .seconds(5)) { controller.find.query == "target" && controller.find.matches.count == 3 }
        #expect(controller.find.matchIndex == 1 && controller.find.isOpen && PDFFind.shared == "target")
    }

    @Test func jumpToSelectionShowsTheSelection() throws {
        let controller = try targets(), view = controller.view
        view.layoutDocumentView()
        try select("gamma", onPage: 2, in: controller)
        let selection = try #require(view.currentSelection), page = try #require(selection.pages.first)
        func shows() -> Bool { view.bounds.intersects(view.convert(selection.bounds(for: page), from: page)) }
        #expect(!shows())
        view.jumpToSelection()
        #expect(shows() && view.currentPage === page)
    }

    @Test func findNextGoesOnFromTheSelection() async throws {
        let controller = try targets()
        PDFFind.shared = "target"
        #expect(controller.find.canNext)
        try select("beta", onPage: 1, in: controller)
        controller.find.next(1)
        try await waitUntil(timeout: .seconds(5)) { controller.find.query == "target" && controller.find.matches.count == 3 }
        #expect(controller.find.matchIndex == 1)
        controller.find.next(1)
        #expect(controller.find.matchIndex == 2)
        controller.find.close()
        try select("alpha", onPage: 0, in: controller)
        controller.find.next(-1)
        try await waitUntil(timeout: .seconds(5)) { controller.find.matches.count == 3 }
        #expect(controller.find.matchIndex == 2)
    }

    /// The field's text as its typing delay ends.
    private func type(_ text: String, in controller: PDFController) {
        controller.find.text = text
        controller.find.typed()
    }

    @Test(arguments: zip(["alpha", "nothing"], [1, -1]))
    func findNextUsesTheLatestSharedOrTypedText(_ earlier: String, _ step: Int) async throws {
        let controller = try targets()
        type(earlier, in: controller)
        try await waitUntil(timeout: .seconds(5)) { controller.find.query == earlier && controller.find.matches.count == (earlier == "alpha" ? 1 : 0) }
        PDFFind.shared = "target"
        controller.find.next(step)
        try await waitUntil(timeout: .seconds(5)) { controller.find.query == "target" && controller.find.matches.count == 3 }
        #expect(controller.find.text == "target")

        type("gamma", in: controller)
        try #require(controller.view.document?.isFinding == true)
        PDFFind.shared = "target" // Another pane changes it while gamma is still being searched.
        controller.find.next(step)
        #expect(controller.find.text == "target")
        try await waitUntil(timeout: .seconds(5)) { controller.view.document?.isFinding == false }
        #expect(controller.find.query == "target" && controller.find.matches.count == 3)

        controller.find.text = "gamma" // Its typing debounce has not fired yet.
        controller.find.next(step)
        try await waitUntil(timeout: .seconds(5)) { controller.find.query == "gamma" && controller.find.matches.count == 1 }
        #expect(controller.find.text == "gamma" && PDFFind.shared == "gamma")
    }

    @Test func rebuildSearchesCurrentFindText() async throws {
        let controller = showing(try textPDF(["old result"]))
        openFind("old", in: controller)
        try await waitUntil(timeout: .seconds(5)) {
            controller.find.query == "old" && controller.find.matches.first?.pages.first?.string?.contains("old") == true
        }

        // The field changed, but its debounce has not started a new search yet.
        controller.find.text = "new"
        controller.show(try textPDF(["new result"]))
        try await waitUntil(timeout: .seconds(5)) {
            controller.find.query == "new" && controller.find.matches.first?.pages.first?.string?.contains("new") == true
        } state: {
            "query \(controller.find.query), matches \(controller.find.matches.count)"
        }
        #expect(controller.find.matches.count == 1)
    }

    @Test func typingBackKeepsTheFieldsMatches() async throws {
        let controller = showing(try textPDF(["a ab a"]))
        controller.find.isOpen = true
        type("a", in: controller)
        try await waitUntil { controller.find.query == "a" && controller.find.matches.count == 3 }
        type("ab", in: controller)
        type("a", in: controller)
        try await waitUntil { controller.find.query == "a" && controller.find.matches.count == 3 }
        // The longer search, had it gone on, would have ended by now.
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.find.query == "a" && controller.find.matches.count == 3)
    }

    @Test func aClickSendsThePagesTextAndTheLetter() throws {
        let pdf = try textPDF(["alpha beta"]), page = try #require(pdf.page(at: 0))
        let text = try #require(page.string) as NSString
        let letter = try #require(page.selection(for: text.range(of: "e"))).bounds(for: page)
        // A page holds its document weakly; it's the view's in the app.
        let click = try #require(withExtendedLifetime(pdf) { page.click(at: CGPoint(x: letter.midX, y: letter.midY)) })
        #expect(click == PageClick(text: text as String, at: text.range(of: "e").location))
    }

    /// PDFKit's word lookup crashes on a page whose document has gone; it has no word.
    @Test func aPageWithoutItsDocumentHasNoWord() throws {
        let page = try autoreleasepool { try #require(try textPDF(["alpha beta"]).page(at: 0)) }
        #expect(page.document == nil && page.click(at: CGPoint(x: 10, y: 10)) == nil)
    }

    /// The core finds the source's word in the text round SyncTeX's box, and the PDF selects it.
    @Test func forwardSearchSelectsTheWordTheCoreFinds() async throws {
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        let line = "An echo repeats. An echo repeats."
        let info = try await newProject()
        defer { try? FileManager.default.removeItem(at: info.folder) }
        try info.write(line, to: info.mainFile)
        let pdf = try textPDF([line], width: 180), page = try #require(pdf.page(at: 0))
        let rendered = try #require(page.string)
        let box = try #require(page.selection(for: NSRange(location: 0, length: (rendered as NSString).length))).bounds(for: page)
        let controller = showing(pdf)
        let column = (line as NSString).range(of: "echo", options: .backwards).location
        controller.reveal(ForwardLoc(page: 1, h: box.minX, v: page.bounds(for: .cropBox).maxY - box.minY, width: box.width, height: box.height),
                          from: SyncSource(id: info.id, file: info.mainFile, line: 1, column: column))
        let second = NSRange(try #require(rendered.ranges(of: "echo").last), in: rendered)
        // PDFKit's selection of a word that ends a row takes the row's break along.
        try await waitUntil {
            let selection = controller.view.currentSelection
            return selection?.range(at: 0, on: page).location == second.location
                && selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "echo"
        } state: { "selection \(String(describing: controller.view.currentSelection?.range(at: 0, on: page)))" }
    }

    /// PDFKit searches off the main thread and posts what it finds to the main queue: found once each match is on a page showing.
    private func found(_ controller: PDFController) async throws {
        try await waitUntil(timeout: .seconds(5)) {
            guard let document = controller.view.document, !controller.find.matches.isEmpty else { return false }
            return controller.find.matches.allSatisfy { match in
                (0..<document.pageCount).contains { document.page(at: $0) === match.pages.first }
            }
        }
    }

    @Test(arguments: zip([NSScroller.Style.overlay, .legacy], [CGFloat?.none, 1.75]))
    func aRebuildFindsAgainInPlace(_ scrollerStyle: NSScroller.Style, _ scale: CGFloat?) async throws {
        let controller = sizedController(), view = controller.view
        try #require(view.subviews.compactMap { $0 as? NSScrollView }.first).scrollerStyle = scrollerStyle
        controller.show(try textPDF(["needle", "filler", "needle", "needle"]))
        if let scale { controller.setScale(scale) }
        openFind("needle", in: controller)
        try await found(controller)
        controller.find.advance(by: 1)
        view.layoutDocumentView()
        let shown = try #require(view.document)
        let page = shown.index(for: try #require(view.currentPage))
        try #require(page > 0)
        let place = try #require(view.documentView).visibleRect

        for _ in 0..<4 {
            controller.show(try textPDF(["needle", "needle", "filler", "needle", "needle"]))
            view.layoutDocumentView()
            try await found(controller)
            #expect(controller.find.isOpen && controller.find.matches.count == 4 && controller.find.matchIndex == 1)
            #expect(view.currentSelection?.pages.first === controller.find.matches[1].pages.first)
            #expect(view.document === shown)
            #expect(shown.index(for: try #require(view.currentPage)) == page)
            let current = try #require(view.documentView).visibleRect
            #expect(isClose(current.minX, place.minX) && isClose(current.minY, place.minY),
                    "viewport before rebuild \(place), after \(current)")
        }
    }
}
