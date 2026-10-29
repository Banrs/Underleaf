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

struct SectionTests {
    private let defaults = TestDefaults()

    @Test func theProjectReadsItsSectionsAndAnnouncesAFailedSave() {
        let app = AppModel(defaults: defaults.store)
        let project = ProjectModel(id: "P", app: app)
        let settings = ProjectSettings(mainFile: "main.tex", engine: .pdflatex, stopOnFirstError: false, shellEscape: false)
        let file = { (name: String) in TreeNode(name: name, path: name, kind: .tex, children: nil, main: name == "main.tex") }
        let sections: [SessionSection] = [
            .project(ProjectState(name: "Paper", root: "/tmp/Paper", settings: settings)),
            .tree([file("main.tex"), TreeNode(name: "figs", path: "figs", kind: nil, children: [], main: false), file("b.tex")]),
            .documents([DocumentState(path: "b.tex", error: nil, held: .changed)]),
        ]
        for section in sections { project.handle(.event(.section(section))) }
        #expect(project.name == "Paper")
        #expect(project.settings?.mainFile == "main.tex")
        #expect(project.url("b.tex")?.path(percentEncoded: false) == "/tmp/Paper/b.tex")
        #expect(project.tree.nodes.map(\.name) == ["figs", "b.tex", "main.tex"])
        #expect(project.saveFailure == "Another app changed “b.tex”.")
        project.handle(.event(.section(.documents([DocumentState(path: "b.tex", error: "The disk is full.", held: nil)]))))
        #expect(app.alert?.title == "“b.tex” Wasn’t Saved")
        #expect(project.saveFailure == "The disk is full.")
    }

    @Test func theBuildSectionFeedsTheListAndItsCountsAndThePDFSectionTheShownPDF() {
        let app = AppModel(defaults: defaults.store)
        app.layout = .source
        let project = ProjectModel(id: "P", app: app)
        let item = { (kind: Severity, line: Int) in LogItem(kind: kind, file: "main.tex", line: line, message: "Line \(line)", explain: nil, fix: nil) }
        let (error, warning, box) = (item(.error, 3), item(.warning, 5), item(.warning, 9))
        let result = CompileResult(ok: false, stopped: false, durationMs: 1200, pdf: nil, badBoxes: [box], log: "")
        let build = { (issues: [LogItem]) in
            project.handle(.event(.section(.build(BuildState(compiling: false, auto: false, outdated: true, result: result,
                                                                  issues: issues, lines: [:])))))
        }
        build([error, warning])
        #expect(project.listed == [error, warning, box])
        #expect((project.errorCount, project.warningCount, project.outdated) == (1, 1, true))
        project.chooseIssue(1, focus: false, open: false)
        build([error, warning])
        #expect(project.chosenIssue == 1)
        build([warning])
        #expect(project.chosenIssue == nil)
        let pdf = { (live: Bool) in project.handle(.event(.section(.shownPdf(ShownPdf(path: "/tmp/P/main.pdf", version: 1, live: live))))) }
        pdf(false)
        #expect(project.buildPDF?.path(percentEncoded: false) == "/tmp/P/main.pdf" && !project.livePDF && !app.showPDF)
        pdf(true)
        #expect(project.livePDF && app.showPDF)
    }
}
