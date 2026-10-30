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

    @Test func eachWindowKeepsItsLayoutAndANewOneStartsFromTheLastChosen() {
        let app = defaults.app()
        let (window, other) = (WindowModel(app: app), WindowModel(app: app))
        for layout in [WorkspaceLayout.source, .pdf, .split] {
            window.layout = layout
            #expect(defaults.window().layout == layout && other.layout == .split)
        }
        window.layout = .source
        window.requestPDF(.find)
        #expect(defaults.window().layout == .split)
        window.outlineCollapsed = true
        #expect(defaults.window().outlineCollapsed && !other.outlineCollapsed)
    }

    @Test func togglingNeverHidesBothPanes() {
        let window = defaults.window()
        window.layout = .source
        window.toggleSource()
        #expect(window.layout == .pdf)
        window.togglePDF()
        #expect(window.layout == .source)
    }

    @Test func oldDefaultsHidingBothShowTheSource() {
        defaults.store.set(false, forKey: DefaultsKey.showSource)
        defaults.store.set(false, forKey: DefaultsKey.showPDF)
        #expect(defaults.window().layout == .source)
    }
}

struct OpenableTests {
    @Test func foldersZipsAndTeXFilesOpenButPackagesDoNot() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["plain", "b.rtfd"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        for name in ["a.tex", "a.zip", "a.txt"] { try Data().write(to: folder.appending(path: name)) }
        let opens = { (name: String) in AppModel.canOpen(folder.appending(path: name)) }
        #expect(opens("plain") && opens("a.tex") && opens("a.zip"))
        #expect(!opens("a.txt") && !opens("b.rtfd"))
    }
}

struct SectionTests {
    private let defaults = TestDefaults()

    @Test func theProjectReadsItsSectionsAndAnnouncesAFailedSave() {
        let window = defaults.window()
        let project = ProjectModel(id: "P", window: window)
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
        #expect(window.alert?.title == "“b.tex” Wasn’t Saved")
        #expect(project.saveFailure == "The disk is full.")
    }

    @Test func theBuildSectionFeedsTheListAndItsCountsAndThePDFSectionTheShownPDF() {
        let window = defaults.window()
        window.layout = .source
        let project = ProjectModel(id: "P", window: window)
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
        #expect(project.buildPDF?.path(percentEncoded: false) == "/tmp/P/main.pdf" && !project.livePDF && !window.showPDF)
        pdf(true)
        #expect(project.livePDF && window.showPDF)
    }

    @Test func liveStateIsTheStoresAndAFailureNeedsAttentionUntilItsLogCloses() {
        let project = ProjectModel(id: "P", window: defaults.window())
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

    @Test func diskConflictsQueueSoEachIsAskedOnce() {
        let project = ProjectModel(id: "P", window: defaults.window())
        project.handle(.conflict(Conflict(path: "a.tex", kind: .changed)))
        project.handle(.conflict(Conflict(path: "b.tex", kind: .changed)))
        #expect(project.conflicts.map(\.path) == ["a.tex", "b.tex"])
        project.handle(.conflict(Conflict(path: "a.tex", kind: .gone)))
        #expect(project.conflicts == [Conflict(path: "b.tex", kind: .changed), Conflict(path: "a.tex", kind: .gone)])
        project.answer("b.tex", .cancel)
        #expect(project.conflicts.map(\.path) == ["a.tex"])
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

    @Test func movingToTheTrashUndoesAndRedoes() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "a.tex")
        try Data("a".utf8).write(to: file)
        let exists = { FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        var changes = 0
        let item = UndoableTrash(original: file, name: "a.tex", undoManager: undo, trash: { (try? $0.recycle()) != nil },
                                 changed: { changes += 1 }, failed: { _, _ in })
        undo.beginUndoGrouping()
        await item.moveToTrash()
        undo.endUndoGrouping()
        #expect(!exists() && undo.undoActionName == "Move to Trash")
        undo.undo()
        try await waitUntil { exists() && changes == 1 }
        undo.redo()
        try await waitUntil { !exists() && changes == 2 }
        undo.undo()
        try await waitUntil { exists() && changes == 3 }
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

    @Test func aNameFieldSelectsTheBaseNameAndTakesFastTypingInOrder() async throws {
        let rename = InPlaceRename<String>()
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Renaming(rename: rename))
        window.makeKeyAndOrderFront(nil)
        rename.begin("a.tex", name: "untitled.tex")
        try await waitUntil { (window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 8) }
        for key in "renamed".map(String.init) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!,
                                atStart: false)
            }
        }
        try await waitUntil { rename.name == "renamed.tex" }
    }
}

private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private struct Renaming: View {
    let rename: InPlaceRename<String>

    var body: some View {
        if rename.id != nil {
            RenameField(text: Bindable(rename).name, isFile: true, ended: {}, commit: {}, cancel: {})
        }
    }
}

struct SwitchTests {
    private let defaults = TestDefaults()

    @Test func anOpenFromHomeSupersedesOneNotYetUnderWay() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let window = defaults.window()
        window.app.autoCompile = false
        let superseded = Task { await window.open(first.id) }
        let latest = Task { await window.open(second.id) }
        _ = (await superseded.value, await latest.value)
        #expect(window.project?.id == second.id && window.project?.initialLoadComplete == true)
        #expect(window.app.recentProjects == [second.id] && window.app.windows.count == 1)
        #expect(await window.close())
        #expect(window.project == nil)
    }

    @Test func aProjectOpensInOneWindowAndAnotherInAWindowOfItsOwn() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let app = defaults.app()
        app.autoCompile = false
        let window = WindowModel(app: app)
        await window.open(first.id)
        await window.open(second.id)
        let other = try #require(app.window(showing: second.id))
        #expect(other !== window && window.project?.id == first.id && app.windows.count == 2)
        await other.open(first.id)
        #expect(app.windows.count == 2 && other.project?.id == second.id)
        #expect(!app.canChange(first) && !app.canChange(second))
        #expect(await window.close() && other.project?.isOpen == true)
        #expect(app.canChange(first) && !app.canChange(second))
        #expect(await other.close())
    }

    @Test func theMenusActOnTheKeyWindowAndOpenRecentOnTheLastOneUsed() {
        let app = defaults.app()
        let (window, other) = (WindowModel(app: app), WindowModel(app: app))
        #expect(app.main == nil && app.front === window)
        other.isKey = true
        #expect(app.main === other && app.front === other)
        (other.isKey, window.isKey) = (false, true)
        #expect(app.main === window && app.windows.first === window)
        window.isKey = false
        #expect(app.main == nil && app.front === window)
        window.windowClosed()
        #expect(app.front === other)
    }

    @Test func aStoppedProjectClosesAtOnceWithNothingUnsavedAndOtherwiseOnlyOnceItsEditsAreLetGo() async throws {
        let window = defaults.window()
        let saved = ProjectModel(id: "P", window: window)
        window.project = saved
        #expect(await window.end() && saved.closed && window.alert == nil)

        let lost = ProjectModel(id: "Q", window: window)
        window.project = lost
        let stopped = Message(id: "stopped_unsaved", args: [:], text: "Copy them out.")
        lost.handle(.section(.documents([DocumentState(path: "main.tex", error: stopped, held: nil)])))
        let kept = Task { await window.end() }
        try await waitUntil { lost.askingToDiscard == ["main.tex"] }
        lost.answerDiscard(false)
        #expect(await !kept.value && lost.isOpen && lost.askingToDiscard == nil)
        let quitting = Task { await window.app.quit() }
        try await waitUntil { lost.askingToDiscard != nil }
        lost.answerDiscard(true)
        #expect(await quitting.value && lost.closed)
    }

    @Test func aProjectOpenInAnotherWindowIsntMovedToTheTrash() async throws {
        let info = try await newProject()
        let app = defaults.app()
        app.autoCompile = false
        let (home, other) = (WindowModel(app: app), WindowModel(app: app))
        await other.open(info.id)
        await home.delete(info)
        #expect(FileManager.default.fileExists(atPath: info.path) && home.alert != nil)
        #expect(await other.close())
    }

    @Test func quitLeavesEveryProjectOpenWhileOneHasADocumentItCantSave() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let app = defaults.app()
        app.autoCompile = false
        let (window, other) = (WindowModel(app: app), WindowModel(app: app))
        await window.open(first.id)
        await other.open(second.id)
        let held = try #require(other.project)
        let document = try #require(SourceDocument(session: held.session, path: "main.tex"))
        _ = document.edit(NSRange(location: 0, length: 0), with: "% mine\n", changing: nil, mirroring: false)
        try await Task.sleep(for: .milliseconds(300))
        try "theirs\n".write(toFile: second.path + "/main.tex", atomically: true, encoding: .utf8)
        try await waitUntil { !held.conflicts.isEmpty }
        #expect(await !app.quit())
        #expect(window.project?.isOpen == true && held.isOpen && held.conflicts.map(\.path) == ["main.tex"])
        held.answer("main.tex", .revert)
        #expect(await app.quit())
        #expect(window.project?.closed == true && held.closed)
    }
}

struct ViewsTests {
    private let defaults = TestDefaults()

    @Test func aProjectOnItsCoreTellsItsViewsWhatTheStoreShows() async throws {
        let info = try await newProject()
        let window = defaults.window()
        window.app.autoCompile = false
        let project = ProjectModel(id: info.id, window: window)
        let views = Views(project)
        try #"{ "ui": { "file": "main.tex", "line": 3 } }"#.write(toFile: info.path + "/.texlocal.json", atomically: true, encoding: .utf8)
        await project.load()
        #expect(views.ui != nil && project.initialLoadComplete)
        #expect(await project.createEntry(in: "", directory: false) == "untitled.tex")
        #expect(await project.createEntry(in: "", directory: true) == "untitled-folder")
        await project.renameEntry("untitled.tex", to: "notes.tex")
        #expect(views.shown == ["main.tex", "untitled.tex", "notes.tex"])
        #expect(views.revealed == ["main.tex:3", "untitled.tex"])
        #expect(views.moved == ["untitled.tex", "notes.tex"])
        #expect(await project.close().value)
        #expect(await project.createEntry(in: "", directory: false) == nil)
        #expect(await project.save())
        project.engine = .xelatex
        await project.compile()
        #expect(window.alert == nil && views.shown.count == 3)
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
            if case .renamed(let renamed) = event { moved += [renamed.from, renamed.to] }
        }

        func opened(_ ui: UiState) -> Task<Void, Never>? {
            self.ui = ui
            return nil
        }

        func reveal(_ path: String, line: Int?, column: Int?, length: Int?, atTop: Bool, focus: Bool) {
            revealed.append(path + (line.map { ":\($0)" } ?? ""))
        }
        func apply(_ edits: DocumentEdits, named name: String) -> Bool { false }
        func trashed(_ path: String) {}
        func beep() {}
        func perform(_ command: EditorCommand) {}
        func perform(_ command: MenuCommand) {}
        func validates(_ command: MenuCommand) -> Bool { false }
    }
}
