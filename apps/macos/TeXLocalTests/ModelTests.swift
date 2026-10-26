import Foundation
import Testing
@testable import TeXLocal

struct TrailTests {
    private let everywhere: (Place) -> Bool = { _ in true }

    @Test func backReturnsToWhereAJumpLeft() {
        var trail = Trail()
        trail.jumped(from: Place(path: "a.tex", line: 3))
        let back = trail.step(back: true, from: Place(path: "b.tex", line: 9), exists: everywhere)
        #expect(back == Place(path: "a.tex", line: 3))
        let forward = trail.step(back: false, from: Place(path: "a.tex", line: 3), exists: everywhere)
        #expect(forward == Place(path: "b.tex", line: 9))
    }

    @Test func aNewJumpClearsForward() {
        var trail = Trail()
        trail.jumped(from: Place(path: "a.tex", line: 1))
        _ = trail.step(back: true, from: Place(path: "b.tex", line: 1), exists: everywhere)
        trail.jumped(from: Place(path: "a.tex", line: 1))
        #expect(trail.forward.isEmpty)
    }

    @Test func placesInMissingFilesAreSkipped() {
        var trail = Trail()
        trail.jumped(from: Place(path: "kept.tex", line: 1))
        trail.jumped(from: Place(path: "gone.tex", line: 1))
        let back = trail.step(back: true, from: Place(path: "here.tex", line: 1)) { $0.path != "gone.tex" }
        #expect(back == Place(path: "kept.tex", line: 1))
        #expect(trail.back.isEmpty)
    }

    @Test func theSamePlaceIsKeptOnceAndFiftyAtMost() {
        var trail = Trail()
        trail.jumped(from: Place(path: "a.tex", line: 1))
        trail.jumped(from: Place(path: "a.tex", line: 1))
        #expect(trail.back.count == 1)
        for line in 0..<60 { trail.jumped(from: Place(path: "a.tex", line: line)) }
        #expect(trail.back.count == 50)
        #expect(trail.back.last == Place(path: "a.tex", line: 59))
    }

    @Test func aRenameMovesThePlaces() {
        var trail = Trail()
        trail.jumped(from: Place(path: "ch/one.tex", line: 2))
        trail.jumped(from: Place(path: "chapter.tex", line: 4))
        trail.moved("ch", to: "parts")
        #expect(trail.back.map(\.path) == ["parts/one.tex", "chapter.tex"])
    }
}

struct PathTests {
    @Test func aRemapMovesTheEntryAndWhatIsInIt() {
        #expect(remapPath("ch", from: "ch", to: "parts") == "parts")
        #expect(remapPath("ch/one.tex", from: "ch", to: "parts") == "parts/one.tex")
        #expect(remapPath("chapter.tex", from: "ch", to: "parts") == "chapter.tex")
    }

    @Test func aDroppedFigureIsIncludedOnlyWhereTeXReadsIt() {
        #expect(ProjectModel.includeGraphics("figs/plot.png", kind: "image") == "\\includegraphics{figs/plot.png}")
        #expect(ProjectModel.includeGraphics("Shot.JPG", kind: "image") == "\\includegraphics{Shot.JPG}")
        #expect(ProjectModel.includeGraphics("a.pdf", kind: "pdf") == "\\includegraphics{a.pdf}")
        #expect(ProjectModel.includeGraphics("a b_{c}.png", kind: "image") == "\\includegraphics{a b_{c}.png}")
        #expect(ProjectModel.includeGraphics("logo.svg", kind: "image") == nil)
        #expect(ProjectModel.includeGraphics("a.pdf", kind: "pdf", into: "bib") == nil)
        #expect(ProjectModel.includeGraphics("ch1.tex", kind: "tex") == nil)
        for path in ["50%.png", "a#1.png", "a\\b.png", "a}{.png", "a{.png"] {
            #expect(ProjectModel.includeGraphics(path, kind: "image") == nil, "\(path)")
        }
    }
}

struct LayoutTests {
    private let defaults = TestDefaults()

    @Test func theLayoutIsKeptInTheDefaults() {
        let app = AppModel(defaults: defaults.store)
        for layout in [WorkspaceLayout.source, .pdf, .split] {
            app.layout = layout
            #expect(AppModel(defaults: defaults.store).layout == layout)
        }
    }

    @Test func togglingNeverHidesBothPanes() {
        let app = AppModel(defaults: defaults.store)
        app.layout = .source
        app.toggleSource()
        #expect(app.layout == .pdf)
        app.togglePDF()
        #expect(app.layout == .source)
    }

    @Test func oldDefaultsHidingBothShowTheSource() {
        defaults.store.set(false, forKey: DefaultsKey.showSource)
        defaults.store.set(false, forKey: DefaultsKey.showPDF)
        #expect(AppModel(defaults: defaults.store).layout == .source)
    }
}
