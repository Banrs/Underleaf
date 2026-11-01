import AppKit
import PDFKit
import Testing
@testable import TeXLocal

@Suite(.serialized)
struct PDFTests {
    @Test(arguments: [Zoom?.none, .scale(1.5), .fitPage])
    func aPDFOpensAtItsStart(_ zoom: Zoom?) async throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString + ".pdf")
        try #require(try textPDF(count: 6).dataRepresentation()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController(), view = controller.view
        controller.restoreZoom = zoom
        let window = onScreen(controller)
        defer { window.close() }
        await controller.load(url).value
        #expect(controller.pageCount == 6)
        #expect(try atStart(view))
        if let zoom { #expect(controller.zoom == zoom && controller.restoreZoom == nil) }
        for width in [420, 700] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600))
            #expect(try atStart(view))
        }
        await controller.load(nil).value
        #expect(controller.pageCount == 0 && view.document == nil)
    }

    @Test(arguments: [Zoom.fitWidth, .scale(1.5), .fitPage])
    func aRebuildOrResizeKeepsThePlaceAndARebuildCoversItsPagesUntilPDFKitDrawsThem(_ zoom: Zoom) async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        controller.show(try textPDF(count: 6))
        controller.apply(zoom)
        view.go(to: PDFDestination(page: try #require(view.document?.page(at: 3)), at: CGPoint(x: 0, y: 400)))
        let (scale, place) = (view.scaleFactor, try shown(view))
        #expect(place.page == 3 && abs(place.y - 400) < 1)
        let rebuilt = try textPDF(count: 6)
        controller.show(rebuilt, covers: SyncPDFView.covers(view.coverPages, of: rebuilt))
        #expect(view.document === rebuilt && view.scaleFactor == scale && controller.zoom == zoom && view.autoScales == (zoom == .fitWidth))
        #expect(try shown(view) == place)
        #expect(overlays(in: view).contains { $0.covered })
        try await waitUntil(timeout: .seconds(2)) { !overlays(in: view).contains { $0.covered } }
        for width in [420, 700] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600))
            #expect(try shown(view) == place)
        }
        controller.show(try textPDF(count: 2))
        #expect(try shown(view).page == 1)
    }

    @Test func aZoomChosenWhileThePaneIsHiddenIsTheOneKept() {
        let controller = PDFController()
        controller.setScale(2)
        #expect(controller.zoom == .scale(2) && controller.keptZoom == .scale(2))
    }

    @Test func thePaperIsDarkWhenChosenOrMatchingADarkAppearance() {
        let view = SyncPDFView()
        for (paper, appearance, dark) in [(PDFPaper.white, NSAppearance.Name.darkAqua, false), (.dark, .aqua, true), (.auto, .aqua, false), (.auto, .darkAqua, true)] {
            view.appearance = NSAppearance(named: appearance)
            view.paper = paper
            #expect(view.darkPaper == dark, "\(paper) in \(appearance.rawValue)")
        }
    }

    @Test func aLivePageReplacesItsPageInPlaceAndASyncMarkOnlyOnThatPageGoes() async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        try await showLive(["Page 1", "Page 2", "Page 3"], in: controller)
        let document = try #require(view.document)
        view.go(to: PDFDestination(page: try #require(document.page(at: 1)), at: CGPoint(x: 0, y: 400)))
        let place = try shown(view)
        view.flash(CGRect(x: 72, y: 600, width: 100, height: 12), on: try #require(document.page(at: 2)))
        for index in [1, 3] { controller.showLive(LivePage(page: index, pdf: try typedPage())) }
        await controller.liveReading?.value
        #expect(view.document === document && document.pageCount == 3 && view.mark?.page === document.page(at: 2))
        #expect(document.page(at: 1)?.string?.contains("typed") == true)
        #expect(try shown(view) == place)
        controller.showLive(LivePage(page: 2, pdf: try typedPage()))
        await controller.liveReading?.value
        #expect(view.mark == nil)
    }

    @Test func aLivePageHidesItsLinksBordersAsABuiltDocumentDoes() async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        try await showLive(["Page 1"], in: controller)
        let linked = try textPDF(["linked"])
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 12), forType: .link, withProperties: nil)
        link.border = PDFBorder()
        link.border?.lineWidth = 1
        try #require(linked.page(at: 0)).addAnnotation(link)
        controller.showLive(LivePage(page: 0, pdf: try #require(linked.dataRepresentation())))
        await controller.liveReading?.value
        let links = try #require(view.document?.page(at: 0)).annotations.filter { $0.type == "Link" }
        #expect(!links.isEmpty && links.allSatisfy { $0.border?.lineWidth == 0 })
    }

    @Test func aLiveDocumentChangesOnlyItsChangedPagesInPlaceAndFindsAgainOnThemAlone() async throws {
        let controller = PDFController(), view = controller.view, find = controller.find
        let window = onScreen(controller)
        defer { window.close() }
        try await showLive(["needle", "filler", "needle", "filler"], in: controller)
        let document = try #require(view.document)
        find.isOpen = true
        find.text = "needle"
        find.search("needle")
        try await found(controller)
        #expect(find.matches.count == 2)
        try await showLive(["needle", "needle", "needle"], changed: [PageRange(first: 1, last: 1)], in: controller)
        #expect(view.document === document && document.pageCount == 3 && !find.isRunning)
        #expect(find.matches.count == 3 && find.matches.map { $0.pages.first.map(document.index) } == [0, 1, 2])
        let many = Array(repeating: "filler", count: PDFController.changedInPlace + 2)
        try await showLive(many, changed: [PageRange(first: 0, last: many.count - 1)], in: controller)
        #expect(view.document !== document && view.document?.pageCount == many.count)
    }

    @Test func aLivePageWaitsForTheDocumentBeforeItAndClosingStopsTheFeed() async throws {
        let defaults = TestDefaults()
        let project = ProjectModel(id: "P", window: defaults.window())
        let views = WorkspaceViews(project: project)
        project.handle(.section(.live(LiveState(phase: .running, engine: .xelatex, halted: false, failures: [], lines: [:]))))
        project.handle(.section(.shownPdf(ShownPdf(path: nil, version: 0, live: true))))
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString + ".pdf")
        try #require(try textPDF(count: 2).dataRepresentation()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        project.handle(.liveDocument(LiveDocument(path: url.path(percentEncoded: false), changed: [])))
        project.handle(.livePage(LivePage(page: 1, pdf: try typedPage())))
        await views.pdf.liveReading?.value
        let document = try #require(views.pdf.view.document)
        #expect(document.pageCount == 2 && document.page(at: 1)?.string?.contains("typed") == true)
        project.handle(.livePage(LivePage(page: 0, pdf: try typedPage())))
        #expect(await project.close().value)
        try await waitUntil { views.pdf.liveReading == nil }
        project.handle(.livePage(LivePage(page: 0, pdf: try typedPage())))
        #expect(views.pdf.liveReading == nil && views.pdf.feed.pages.isEmpty)
    }

    @Test func aRebuildFindsAgainInPlace() async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        controller.show(try textPDF(["needle", "filler", "needle", "needle"]))
        controller.find.isOpen = true
        controller.find.text = "needle"
        controller.find.search("needle")
        try await found(controller)
        controller.find.advance(by: 1)
        let place = try shown(view)
        controller.show(try textPDF(["needle", "needle", "filler", "needle", "needle"]))
        try await found(controller)
        #expect(controller.find.matches.count == 4 && controller.find.matchIndex == 1)
        #expect(view.currentSelection?.pages.first === controller.find.matches[1].pages.first)
        #expect(try shown(view) == place)
    }

    @Test func findNextAndPreviousStartFromTheShownPage() async throws {
        let board = PDFFind.board
        PDFFind.board = .withUniqueName()
        defer { PDFFind.board.releaseGlobally(); PDFFind.board = board }
        let controller = PDFController(), view = controller.view, find = controller.find
        let window = onScreen(controller)
        defer { window.close() }
        controller.show(try textPDF(["needle", "filler", "needle", "needle"]))
        let second = try #require(view.document?.page(at: 1))
        let top = PDFDestination(page: second, at: CGPoint(x: 0, y: second.bounds(for: view.displayBox).maxY))
        view.go(to: top)
        find.text = "needle"
        find.next(-1)
        try await found(controller)
        #expect(find.matchIndex == 0)
        find.close()
        #expect(view.currentSelection == nil)
        view.go(to: top)
        find.next(1)
        try await found(controller)
        #expect(find.matchIndex == 1 && view.currentSelection?.pages.first === view.document?.page(at: 2))
        find.advance(by: 2)
        #expect(find.matchIndex == 0)
        view.setCurrentSelection(view.document?.findString("filler").first, animate: false)
        find.close()
        #expect(view.currentSelection?.string == "filler")
    }

    @Test func followingTheCaretScrollsOnlyWhenItsPlaceIsOutOfView() throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        controller.show(try textPDF(count: 6))
        let start = try shown(view)
        controller.follow(ForwardLoc(page: 1, h: 72, v: 100, width: 100, height: 10, matches: []))
        #expect(try shown(view) == start)
        let far = ForwardLoc(page: 5, h: 72, v: 300, width: 100, height: 10, matches: [])
        controller.follow(far)
        let page = try #require(view.document?.page(at: 4))
        let rect = view.convert(SyncTeXGeometry.highlightRect(far, pageBounds: page.bounds(for: view.displayBox)), from: page)
        #expect(try shown(view) != start && view.shownRect.contains(rect))
        #expect(view.mark == nil && view.currentSelection == nil)
    }

    @Test(arguments: [false, true])
    func aSyncWithNoWordFallsBackToItsBoxUnlessItNeedsAWord(_ wordOnly: Bool) async throws {
        let controller = PDFController(), view = controller.view
        let window = onScreen(controller)
        defer { window.close() }
        controller.show(try textPDF(count: 6))
        let start = try shown(view)
        let far = ForwardLoc(page: 5, h: 72, v: 300, width: 100, height: 10, matches: [])
        let source = SyncSource(session: SessionClient(core: .shared), file: "main.tex", line: 1, column: 0, wordOnly: wordOnly)
        controller.reveal(far, from: source)
        await controller.revealing?.value
        if wordOnly {
            #expect(try shown(view) == start && view.mark == nil)
        } else {
            let mark = try #require(view.mark)
            #expect(mark.page === view.document?.page(at: 4) && view.shownRect.contains(view.convert(mark.rect, from: mark.page)))
        }
    }

    private func textPDF(_ pages: [String]) throws -> PDFDocument {
        let document = PDFDocument()
        for text in pages {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            view.string = text
            let page = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
            document.insert(page, at: document.pageCount)
        }
        return document
    }

    private func textPDF(count: Int) throws -> PDFDocument { try textPDF((1...count).map { "Page \($0)" }) }

    private func typedPage() throws -> Data { try #require(try textPDF(["typed"]).dataRepresentation()) }

    private func showLive(_ pages: [String], changed: [PageRange] = [], in controller: PDFController) async throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString + ".pdf")
        try #require(try textPDF(pages).dataRepresentation()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        controller.showLive(LiveDocument(path: url.path(percentEncoded: false), changed: changed))
        await controller.liveReading?.value
    }

    private func onScreen(_ controller: PDFController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar()
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        controller.view.frame = window.contentView?.bounds ?? .zero
        controller.view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(controller.view)
        window.orderFront(nil)
        return window
    }

    private func shown(_ view: SyncPDFView) throws -> Place {
        let place = try #require(view.shownPlace)
        return Place(page: place.index, y: place.point.y)
    }

    private func atStart(_ view: SyncPDFView) throws -> Bool {
        let place = try shown(view), top = try #require(view.document?.page(at: 0)).bounds(for: view.displayBox).maxY
        return place.page == 0 && abs(place.y - top) < 1
    }

    private func overlays(in view: NSView) -> [PageOverlay] {
        view.subviews.flatMap { ($0 as? PageOverlay).map { [$0] } ?? overlays(in: $0) }
    }

    private func found(_ controller: PDFController) async throws {
        try await waitUntil(timeout: .seconds(5)) {
            guard let document = controller.view.document, !controller.find.matches.isEmpty else { return false }
            return controller.find.matches.allSatisfy { $0.pages.first?.document === document }
        }
    }

    private struct Place: Equatable {
        let page: Int
        let y: CGFloat

        static func == (a: Self, b: Self) -> Bool { a.page == b.page && abs(a.y - b.y) < 1 }
    }
}
