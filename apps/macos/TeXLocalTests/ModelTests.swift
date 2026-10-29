import Foundation
import SwiftUI
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
        let app = defaults.app()
        for layout in [WorkspaceLayout.source, .pdf, .split] {
            app.layout = layout
            #expect(defaults.app().layout == layout)
        }
    }

    @Test func togglingNeverHidesBothPanes() {
        let app = defaults.app()
        app.layout = .source
        app.toggleSource()
        #expect(app.layout == .pdf)
        app.togglePDF()
        #expect(app.layout == .source)
    }

    @Test func oldDefaultsHidingBothShowTheSource() {
        defaults.store.set(false, forKey: DefaultsKey.showSource)
        defaults.store.set(false, forKey: DefaultsKey.showPDF)
        #expect(defaults.app().layout == .source)
    }
}

struct SectionTests {
    private let defaults = TestDefaults()

    @Test func theProjectReadsItsSectionsAndAnnouncesAFailedSave() {
        let app = defaults.app()
        let project = ProjectModel(id: "P", app: app)
        let settings = ProjectSettings(mainFile: "main.tex", engine: .pdflatex, stopOnFirstError: false, shellEscape: false)
        let file = { (name: String) in TreeNode(name: name, path: name, kind: .tex, children: nil, main: name == "main.tex") }
        let sections: [SessionSection] = [
            .project(ProjectState(name: "Paper", root: "/tmp/Paper", settings: settings, problem: nil)),
            .tree([file("main.tex"), TreeNode(name: "figs", path: "figs", kind: nil, children: [], main: false), file("b.tex")]),
            .documents([DocumentState(path: "b.tex", error: nil, held: .changed)]),
        ]
        for section in sections { project.handle(.section(section)) }
        #expect(project.name == "Paper")
        #expect(project.settings?.mainFile == "main.tex")
        #expect(project.url("b.tex")?.path(percentEncoded: false) == "/tmp/Paper/b.tex")
        #expect(project.tree.nodes.map(\.name) == ["figs", "b.tex", "main.tex"])
        project.handle(.section(.tree([file("main.tex"), file("a.tex")])))
        #expect(project.tree.nodes.map(\.name) == ["a.tex", "main.tex"] && project.tree.node(at: "b.tex") == nil)
        #expect(project.saveFailure == "Another app changed “b.tex”.")
        project.handle(.section(.documents([DocumentState(path: "b.tex", error: Message(id: "disk_full", args: [:], text: "The disk is full."), held: nil)])))
        #expect(app.alert?.title == "“b.tex” Wasn’t Saved")
        #expect(project.saveFailure == "The disk is full.")
    }

    @Test func theBuildSectionFeedsTheListAndItsCountsAndThePDFSectionTheShownPDF() {
        let app = defaults.app()
        app.layout = .source
        let project = ProjectModel(id: "P", app: app)
        let item = { (kind: Severity, line: Int) in LogItem(kind: kind, file: "main.tex", line: line, message: Message(id: "tex", args: ["text": "Line \(line)"], text: "Line \(line)"), explain: nil, fix: nil) }
        let (error, warning, box) = (item(.error, 3), item(.warning, 5), item(.warning, 9))
        let result = CompileResult(ok: false, stopped: false, durationMs: 1200, pdf: nil, badBoxes: [box], log: "")
        let build = { (issues: [LogItem]) in
            project.handle(.section(.build(BuildState(compiling: false, auto: false, outdated: true, result: result,
                                                      issues: issues, lines: [:]))))
        }
        build([error, warning])
        #expect(project.listed == [error, warning, box])
        #expect((project.errorCount, project.warningCount, project.outdated) == (1, 1, true))
        project.chooseIssue(1, focus: false, open: false)
        build([error, warning])
        #expect(project.chosenIssue == 1)
        build([warning])
        #expect(project.chosenIssue == nil)
        let pdf = { (live: Bool) in project.handle(.section(.shownPdf(ShownPdf(path: "/tmp/P/main.pdf", version: 1, live: live)))) }
        pdf(false)
        #expect(project.buildPDF?.path(percentEncoded: false) == "/tmp/P/main.pdf" && !project.livePDF && !app.showPDF)
        pdf(true)
        #expect(project.livePDF && app.showPDF)
    }

    @Test func liveStateIsTheStoresAndAFailureNeedsAttentionUntilItsLogCloses() {
        let project = ProjectModel(id: "P", app: defaults.app())
        let live = project.texpresso
        let state = { (phase: LivePhase, failures: [Message], log: String?) in
            project.handle(.section(.live(LiveState(phase: phase, engine: .xelatex, halted: false, log: log, failures: failures, lines: [:]))))
        }
        state(.stopped, [], nil)
        #expect(live.phase == .stopped && !live.used && live.log.isEmpty && !live.needsAttention)
        state(.running, [], "Output written.")
        #expect(live.active && live.used && live.log == "Output written." && String(localized: live.title) == "Live Preview On")
        let failed = Message(id: "texpresso_failed", args: [:], text: "TeXpresso stopped.")
        state(.stopped, [failed], nil)
        project.handle(.liveAlert)
        #expect(live.needsAttention && live.log == "TeXpresso stopped." && project.panel.showsLiveLog)
        live.logClosed()
        #expect(!live.needsAttention && String(localized: live.title) == "Live Preview Stopped")
        state(.starting, [], nil)
        state(.stopped, [failed], nil)
        #expect(live.needsAttention)
    }
}

struct LaneTests {
    @Test func cancellingALaneCancelsWhatIsQueuedInIt() async {
        var lane: Task<Bool, Never>?
        let first = enqueue(&lane) {
            try? await Task.sleep(for: .seconds(5))
            return Task.isCancelled
        }
        let second = enqueue(&lane) { Task.isCancelled }
        lane?.cancel()
        let cancelled = (await first.value, await second.value)
        #expect(cancelled == (true, true))
    }
}

struct FieldTests {
    @Test func aNameFieldWarnsOfASpaceOnlyWhileTheNameHasOne() {
        let height = { (name: String) in
            NSHostingView(rootView: RenameField(text: .constant(name), spaceWarning: "Spaces can break \\input and \\include.",
                                                ended: {}, commit: {}, cancel: {})).fittingSize.height
        }
        #expect(height("my notes.tex") > height("notes.tex"))
    }
}

struct ViewsTests {
    private let defaults = TestDefaults()

    @Test func aProjectOnItsCoreTellsItsViewsWhatTheStoreShows() async throws {
        let info = try await newProject()
        let app = defaults.app()
        app.autoCompile = false
        let project = ProjectModel(id: info.id, app: app)
        let views = Views(project)
        try #"{ "ui": { "file": "main.tex", "line": 3 } }"#.write(toFile: info.path + "/.texlocal.json", atomically: true, encoding: .utf8)
        await project.load()
        #expect(views.ui != nil && project.initialLoadComplete)
        #expect(await project.createEntry(in: "", directory: false) == "untitled.tex")
        await project.renameEntry("untitled.tex", to: "notes.tex")
        #expect(views.shown == ["main.tex", "untitled.tex", "notes.tex"])
        #expect(views.revealed == ["main.tex:3", "untitled.tex"])
        #expect(views.moved == ["untitled.tex", "notes.tex"])
        #expect(await project.close().value)
    }

    private final class Views: ProjectViews {
        private let project: ProjectModel
        var ui: UiState?
        var shown: [String] = [], revealed: [String] = [], moved: [String] = []

        init(_ project: ProjectModel) {
            self.project = project
            project.views = self
        }

        let hasPDF = false, zoom = Zoom.fitWidth, shownVersion = 0, inspectorShown = false

        func heard(_ event: Event) {
            if case .section(.openFile(let file?)) = event, project.openPath == file.path { shown.append(file.path) }
        }

        func opened(_ ui: UiState) -> Task<Void, Never>? {
            self.ui = ui
            return nil
        }

        func reveal(_ path: String, line: Int?, column: Int?, length: Int?, atTop: Bool, focus: Bool) {
            revealed.append(path + (line.map { ":\($0)" } ?? ""))
        }
        func apply(_ edits: DocumentEdits, named name: String) -> Bool { false }
        func moved(from: String, to: String) { moved += [from, to] }
        func trashed(_ path: String) {}
        func beep() {}
        func perform(_ command: EditorCommand) {}
        func perform(_ command: MenuCommand) {}
        func validates(_ command: MenuCommand) -> Bool { false }
    }
}
