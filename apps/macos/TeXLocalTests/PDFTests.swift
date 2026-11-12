import AppKit
import PDFKit
import Testing
@testable import TeXLocal

@Suite(.serialized)
struct PDFTests {
    @Test(arguments: [(Zoom?.none, PdfPlace?.none), (.scale(1.5), nil), (.fitPage, PdfPlace(page: 3, x: 0, y: 400)),
                      (.fitWidth, PdfPlace(page: 9, x: 0, y: 792))])
    func aPDFOpensWhereItWasLeftElseAtItsStart(_ zoom: Zoom?, _ left: PdfPlace?) async throws {
        let url = try written(textPDF(count: 6))
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PDFController(), view = controller.view
        controller.restore = zoom.map { ($0, left) }
        #expect(controller.keptPlace == left)
        let window = try await onScreen(controller.view)
        defer { window.close() }
        await controller.load(url).value
        #expect(controller.pageCount == 6)
        let opened = try shown(view)
        if let left { #expect(opened == Place(page: min(left.page, 5), y: left.y)) } else { #expect(try atStart(view)) }
        if let zoom { #expect(controller.zoom == zoom && controller.restore == nil) }
        #expect(controller.keptPlace.map { Place(page: $0.page, y: $0.y) } == opened)
        for width in [420, 700] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600))
            #expect(try shown(view) == opened)
        }
        view.setFrameSize(.zero)
        #expect(controller.keptPlace.map { Place(page: $0.page, y: $0.y) } == opened)
        await controller.load(nil).value
        #expect(controller.pageCount == 0 && view.document == nil)
    }

    @Test(arguments: [Zoom.fitWidth, .scale(1.5), .fitPage])
    func aRebuildOrResizeKeepsThePlaceAndARebuildCoversItsPagesUntilPDFKitDrawsThem(_ zoom: Zoom) async throws {
        let (controller, view, window) = try await shownPDF()
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
        #expect(view.descendants(of: PageOverlay.self).contains { $0.covered })
        try await waitUntil { !view.descendants(of: PageOverlay.self).contains { $0.covered } }
        if zoom != .fitPage {
            for height in [480, 680] as [CGFloat] {
                window.setContentSize(NSSize(width: view.frame.width, height: height))
                let resized = try shown(view)
                #expect(resized == place, "At \(height) pt: \(place) became \(resized)")
            }
        }
        for width in [420, 700] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600))
            #expect(try shown(view) == place)
        }
        controller.show(try textPDF(count: 2))
        #expect(try shown(view).page == 1)
    }

    @Test func aClickGivesTheCharacterUnderItWithThePagesText() throws {
        let document = try textPDF(["alpha needle"])
        let page = try #require(document.page(at: 0)), text = try #require(page.string), word = (text as NSString).range(of: "needle")
        for offset in [0, 2, 5] {
            let box = try #require(page.selection(for: NSRange(location: word.location + offset, length: 1))).bounds(for: page)
            #expect(page.click(at: CGPoint(x: box.midX, y: box.midY)) == PageClick(text: text, at: word.location + offset))
        }
        let above = try #require(page.selection(for: NSRange(location: word.location + 2, length: 1))).bounds(for: page)
        #expect(page.click(at: CGPoint(x: above.midX, y: above.maxY + 0.5)) == PageClick(text: text, at: word.location))
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
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        try await showLive(["Page 1", "Page 2", "Page 3"], in: controller)
        let document = try #require(view.document)
        view.go(to: PDFDestination(page: try #require(document.page(at: 1)), at: CGPoint(x: 0, y: 400)))
        let place = try shown(view)
        view.flash(CGRect(x: 72, y: 600, width: 100, height: 12), on: try #require(document.page(at: 2)))
        for index in [1, 3] { controller.showLive(LivePage(page: index, pdf: try typedPage())) }
        await controller.feed.reading?.value
        #expect(view.document === document && document.pageCount == 3 && view.mark?.page === document.page(at: 2))
        #expect(document.page(at: 1)?.string?.contains("typed") == true)
        #expect(try shown(view) == place)
        controller.showLive(LivePage(page: 2, pdf: try typedPage()))
        await controller.feed.reading?.value
        #expect(view.mark == nil)
    }

    @Test func aLivePageKeepsItsLinks() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        try await showLive(["Page 1"], in: controller)
        let linked = try textPDF(["linked"])
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 12), forType: .link, withProperties: nil)
        let destination = try #require(URL(string: "https://example.com"))
        link.url = destination
        try #require(linked.page(at: 0)).addAnnotation(link)
        controller.showLive(LivePage(page: 0, pdf: try #require(linked.dataRepresentation())))
        await controller.feed.reading?.value
        let links = try #require(view.document?.page(at: 0)).annotations.filter { $0.type == "Link" }
        #expect(links.count == 1 && links.first?.url == destination)
    }

    @Test func aLiveDocumentChangesOnlyItsChangedPagesInPlaceAndFindReadsTheirText() async throws {
        let controller = PDFController(), view = controller.view, text = view.find.text
        let window = try await onScreen(controller.view)
        defer { window.close() }
        try await showLive(["needle", "filler", "needle", "filler"], in: controller)
        let document = try #require(view.document)
        try await waitUntil { text.pageStrings.count == 4 }
        let kept = [document.page(at: 0), document.page(at: 2)]
        try await showLive(["needle", "needle", "needle"], changed: [PageRange(first: 1, last: 1)], in: controller)
        #expect(view.document === document && document.pageCount == 3)
        #expect(document.page(at: 0) === kept[0] && document.page(at: 2) === kept[1])
        try await waitUntil { text.pageStrings.count == 3 && text.pageStrings.allSatisfy { $0.contains("needle") } }
        let many = Array(repeating: "filler", count: PDFController.changedInPlace + 2)
        try await showLive(many, changed: [PageRange(first: 0, last: many.count - 1)], in: controller)
        #expect(view.document !== document && view.document?.pageCount == many.count)
    }

    @Test func aLivePageWaitsForTheDocumentBeforeItAndClosingStopsTheFeed() async throws {
        let defaults = TestDefaults()
        let project = ProjectModel(id: "P", window: defaults.window())
        let views = WorkspaceViews(project: project)
        project.handle(.section(.live(LiveState(phase: .running, engine: .xelatex, halted: false, attention: false, failures: [], lines: [:]))))
        project.handle(.section(.shownPdf(ShownPdf(path: nil, version: 0, live: true))))
        let url = try written(textPDF(count: 2))
        defer { try? FileManager.default.removeItem(at: url) }
        project.handle(.liveDocument(LiveDocument(path: url.path(percentEncoded: false), changed: [])))
        project.handle(.livePage(LivePage(page: 1, pdf: try typedPage())))
        await views.pdf.feed.reading?.value
        let document = try #require(views.pdf.view.document)
        #expect(document.pageCount == 2 && document.page(at: 1)?.string?.contains("typed") == true)
        project.handle(.livePage(LivePage(page: 0, pdf: try typedPage())))
        #expect(await project.close().value)
        try await waitUntil { views.pdf.feed.reading == nil }
        project.handle(.livePage(LivePage(page: 0, pdf: try typedPage())))
        #expect(views.pdf.feed.reading == nil && views.pdf.feed.pages.isEmpty)
    }

    @Test func aQueuedDocumentKeepsTheFollowThatAnOlderReadCannotShow() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        let url = try written(textPDF(count: 4))
        defer { try? FileManager.default.removeItem(at: url) }
        let watch = NotificationCenter.default.addObserver(forName: .PDFViewDocumentChanged, object: view, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard controller.view.document?.pageCount == 2 else { return }
                controller.showLive(LiveDocument(path: url.path(percentEncoded: false), changed: [PageRange(first: 2, last: 3)]))
                controller.follow(ForwardLoc(page: 4, h: 72, v: 300, width: 100, height: 10, matches: []))
            }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        try await showLive(["Page 1", "Page 2"], in: controller)
        #expect(view.document?.pageCount == 4)
        #expect(try shown(view).page == 3 && controller.feed.follow == nil)
    }

    @Test func aReadStoppedWhileLoadingLeavesTheNextFeedItsFollow() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        controller.show(try textPDF(count: 2))
        let (old, new) = (try written(textPDF(count: 1)), try written(textPDF(count: 30)))
        defer { [old, new].forEach { try? FileManager.default.removeItem(at: $0) } }
        controller.showLive(LiveDocument(path: old.path(percentEncoded: false), changed: []))
        let stopped = try #require(controller.feed.reading)
        await Task.yield()
        controller.stopLive()
        controller.showLive(LiveDocument(path: new.path(percentEncoded: false), changed: []))
        controller.follow(ForwardLoc(page: 20, h: 72, v: 300, width: 100, height: 10, matches: []))
        await stopped.value
        await controller.feed.reading?.value
        #expect(view.document?.pageCount == 30 && controller.feed.follow == nil)
        #expect(try shown(view).page == 19)
    }

    @Test func aLiveDocumentReadsAgainThePagesItDropsAsAnUndoneEditLeavesThemUnchangedInIt() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        try await showLive(["one", "two"], in: controller)
        controller.showLive(LivePage(page: 1, pdf: try typedPage()))
        await controller.feed.reading?.value
        #expect(view.document?.page(at: 1)?.string?.contains("typed") == true)
        controller.showLive(LivePage(page: 1, pdf: try #require(try textPDF(["two"]).dataRepresentation())))
        try await showLive(["one", "two"], in: controller)
        #expect(view.document?.page(at: 1)?.string?.contains("two") == true)
    }

    @Test func coversAreDrawnForEveryPageInViewAtLowZoom() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        controller.show(try textPDF(count: 20))
        controller.setScale(0.1)
        view.layoutDocumentView()
        let document = try #require(view.document)
        let shown = try (0..<document.pageCount).filter { index in
            let page = try #require(document.page(at: index))
            return view.convert(page.bounds(for: SyncPDFView.box), from: page).intersects(view.shownRect)
        }
        #expect(shown.count > 3 && Set(view.coverPages.indices).isSuperset(of: shown))
    }

    @Test func aLivePageIsCoveredByItsDrawingUntilPDFKitDrawsIt() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        try await showLive(["one", "two"], in: controller)
        try await waitUntil { !view.descendants(of: PageOverlay.self).contains { $0.covered } }
        let live = try #require(await PDFController.loadPages([0: try typedPage()], covering: view.coverPages))
        #expect(live.covers[0] != nil)
        controller.replace(live)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.descendants(of: PageOverlay.self).contains { $0.covered })
    }

    @Test func findReadsEachPageAsAStringEndingInASearchBoundary() async throws {
        let controller = PDFController(), view = controller.view, text = view.find.text
        let window = try await onScreen(view)
        defer { window.close() }
        controller.show(try textPDF(["needle", "filler", "needle"]))
        try await waitUntil { text.pageStrings.count == 3 }
        let strings = text.pageStrings, lengths = strings.map { ($0 as NSString).length }
        #expect(strings.map { $0.contains("needle") } == [true, false, true] && text.stringLength() == lengths.reduce(0, +))
        for (page, index) in [(0, 0), (1, lengths[0]), (1, lengths[0] + lengths[1] - 1), (2, lengths[0] + lengths[1])] {
            var range = NSRange(), boundary: ObjCBool = false
            let start = lengths[..<page].reduce(0, +)
            #expect(text.string(at: index, effectiveRange: &range, endsWithSearchBoundary: &boundary) == strings[page])
            #expect(range == NSRange(location: start, length: lengths[page]) && boundary.boolValue)
        }
        #expect(!text.isEditable)
    }

    @Test func findStartsFromTheSelectionElseFromThePageShownAndSelectsWhatItFinds() async throws {
        let controller = PDFController(), view = controller.view, text = view.find.text
        let window = try await onScreen(view)
        defer { window.close() }
        controller.show(try textPDF(["needle", "filler", "needle", "needle"]))
        try await waitUntil { text.pageStrings.count == 4 }
        let document = try #require(view.document), lengths = text.pageStrings.map { ($0 as NSString).length }
        let second = try #require(document.page(at: 1))
        view.go(to: PDFDestination(page: second, at: CGPoint(x: 0, y: second.bounds(for: SyncPDFView.box).maxY)))
        let place = text.firstSelectedRange
        #expect(place.length == 0 && (lengths[0]..<lengths[0] + lengths[1]).contains(place.location))
        let third = lengths[0] + lengths[1]
        text.scrollRangeToVisible(NSRange(location: third, length: 6))
        #expect(view.currentSelection?.pages.first === document.page(at: 2) && view.currentSelection?.string == "needle")
        #expect(try text.firstSelectedRange == NSRange(location: third, length: 6) && shown(view).page == 2)
    }

    @Test func findWithNothingSelectedGoesOnFromTheTextShownWhenTheShownCornerIsInTheMargin() async throws {
        let board = NSPasteboard(name: .find), kept = board.string(forType: .string)
        defer { if let kept { board.clearContents(); board.setString(kept, forType: .string) } }
        board.clearContents()
        let controller = PDFController(), view = controller.view, find = view.find
        let window = try await onScreen(view)
        defer { window.close() }
        let filler = Array(repeating: "filler", count: 24).joined(separator: "\n")
        controller.show(try textPDF(["needle\n\(filler)\nneedle\n\(filler)", "filler"]))
        try await waitUntil { find.text.pageStrings.count == 2 }
        find.perform(.showFindInterface)
        let page = try #require(view.document?.page(at: 0)), string = find.text.pageStrings[0] as NSString
        let above = string.range(of: "needle"), below = string.range(of: "needle", options: .backwards)
        let middle = (page.characterBounds(at: above.location).minY + page.characterBounds(at: below.location).maxY) / 2
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: middle)))
        let top = try #require(view.placeBeneathToolbar)
        #expect(top.index == 0 && !(0..<string.length).contains(page.characterIndex(at: top.point)))
        let place = find.text.firstSelectedRange
        #expect(place.length == 0 && (NSMaxRange(above)...below.location).contains(place.location))
        let field = try #require(view.pageScrollView?.findBarView?.descendants(of: NSSearchField.self).first)
        try #require(field.currentEditor() as? NSTextView).insertText("needle", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { view.highlightedSelections?.count == 2 }
        let selection = try #require(view.currentSelection)
        #expect(selection.pages.first === page && selection.range(at: 0, on: page).location == below.location)
    }

    @Test func aRebuildWithFindOpenKeepsThePlace() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        controller.show(try textPDF(count: 6))
        view.find.perform(.showFindInterface)
        view.goToStart()
        #expect(try atStart(view))
        view.go(to: PDFDestination(page: try #require(view.document?.page(at: 3)), at: CGPoint(x: 0, y: 400)))
        let place = try shown(view)
        for _ in 0..<3 { controller.show(try textPDF(count: 6)) }
        #expect(try shown(view) == place)
    }

    @Test func findLightsItsMatchesTakesFindNextFromItsFieldAndDropsThemWhenALiveChangeAltersTheText() async throws {
        let board = NSPasteboard(name: .find), kept = board.string(forType: .string)
        defer { if let kept { board.clearContents(); board.setString(kept, forType: .string) } }
        board.clearContents()
        let controller = PDFController(), view = controller.view, find = view.find
        let window = try await onScreen(view)
        defer { window.close() }
        try await showLive(["needle", "filler", "needle"], in: controller)
        try await waitUntil { find.text.pageStrings.count == 3 }
        find.perform(.showFindInterface)
        let bar = try #require(view.pageScrollView?.findBarView)
        #expect(find.isOpen && bar.isDescendant(of: view))
        #expect(bar.convert(bar.bounds, to: nil).maxY <= window.contentLayoutRect.maxY + 0.5)
        let field = try #require(bar.descendants(of: NSSearchField.self).first)
        try #require(field.currentEditor() as? NSTextView).insertText("needle", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { view.highlightedSelections?.count == 2 }
        #expect(view.currentSelection?.pages.first === view.document?.page(at: 0))

        let next = NSMenuItem(title: "Find Next", action: #selector(PDFFind.performFindPanelAction(_:)), keyEquivalent: "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        let responders = sequence(first: try #require(window.firstResponder), next: \.nextResponder)
        let target = responders.lazy.compactMap { $0.responds(to: next.action) ? $0 : $0.supplementalTarget(forAction: next.action!, sender: next) as? NSObject }.first
        #expect(target === find && find.validateMenuItem(next))
        find.performFindPanelAction(next)
        #expect(view.currentSelection?.pages.first === view.document?.page(at: 2))

        controller.showLive(LivePage(page: 0, pdf: try #require(try textPDF(["needle"]).dataRepresentation())))
        await controller.feed.reading?.value
        let first = view.document?.page(at: 0)
        try await waitUntil { view.highlightedSelections?.count == 2 && view.highlightedSelections?.first?.pages.first === first }
        controller.showLive(LivePage(page: 1, pdf: try #require(try textPDF(["needle"]).dataRepresentation())))
        await controller.feed.reading?.value
        try await waitUntil { find.text.pageStrings[1].contains("needle") }
        #expect(view.highlightedSelections == nil && find.isOpen && bar.window === window)

        await controller.load(nil).value
        #expect(view.document == nil && !find.isOpen)
        #expect(find.text.pageStrings.isEmpty && view.highlightedSelections == nil)
    }

    @Test func followingTheCaretScrollsOnlyWhenItsPlaceIsOutOfView() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        controller.show(try textPDF(count: 6))
        let start = try shown(view)
        controller.follow(ForwardLoc(page: 1, h: 72, v: 100, width: 100, height: 10, matches: []))
        #expect(try shown(view) == start)
        let far = ForwardLoc(page: 5, h: 72, v: 300, width: 100, height: 10, matches: [])
        controller.follow(far)
        let page = try #require(view.document?.page(at: 4))
        let rect = view.convert(SyncTeXGeometry.highlightRect(far, pageBounds: page.bounds(for: SyncPDFView.box)), from: page)
        #expect(try shown(view) != start && view.shownRect.contains(rect))
        #expect(view.mark == nil && view.currentSelection == nil)
    }

    @Test func followingAPageNotShownYetWaitsForTheNextLiveUpdate() async throws {
        let (controller, view, window) = try await shownPDF()
        defer { window.close() }
        try await showLive(["Page 1", "Page 2"], in: controller)
        let start = try shown(view)
        controller.follow(ForwardLoc(page: 4, h: 72, v: 300, width: 100, height: 10, matches: []))
        #expect(try shown(view) == start)
        try await showLive((1...4).map { "Page \($0)" }, changed: [PageRange(first: 2, last: 3)], in: controller)
        #expect(try shown(view).page == 3 && controller.feed.follow == nil)
    }

    @Test(arguments: [false, true])
    func aSyncWithNoWordFallsBackToItsBoxUnlessItNeedsAWord(_ wordOnly: Bool) async throws {
        let (controller, view, window) = try await shownPDF()
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

    private func shownPDF() async throws -> (PDFController, SyncPDFView, NSWindow) {
        let controller = PDFController()
        return (controller, controller.view, try await onScreen(controller.view))
    }

    private func typedPage() throws -> Data { try #require(try textPDF(["typed"]).dataRepresentation()) }

    private func written(_ document: PDFDocument) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".pdf")
        try #require(document.dataRepresentation()).write(to: url)
        return url
    }

    private func showLive(_ pages: [String], changed: [PageRange] = [], in controller: PDFController) async throws {
        let url = try written(textPDF(pages))
        defer { try? FileManager.default.removeItem(at: url) }
        controller.showLive(LiveDocument(path: url.path(percentEncoded: false), changed: changed))
        await controller.feed.reading?.value
    }

    private func shown(_ view: SyncPDFView) throws -> Place {
        let place = try #require(view.shownPlace)
        return Place(page: place.index, y: place.point.y)
    }

    private func atStart(_ view: SyncPDFView) throws -> Bool {
        let place = try shown(view), top = try #require(view.document?.page(at: 0)).bounds(for: SyncPDFView.box).maxY
        return place.page == 0 && abs(place.y - top) < 1
    }

    private struct Place: Equatable {
        let page: Int
        let y: CGFloat

        static func == (a: Self, b: Self) -> Bool { a.page == b.page && abs(a.y - b.y) < 1 }
    }
}
