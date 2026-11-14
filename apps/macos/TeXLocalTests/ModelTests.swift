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
    }

    @Test func eachProjectKeepsItsNavigatorAndAFailedBuildShowsIssuesUntilACleanOne() {
        let project = ProjectModel(id: "P", window: defaults.window())
        #expect(project.navigator.shown == .files)
        project.navigator.shown = .outline
        #expect(ProjectModel(id: "P", window: defaults.window()).navigator.shown == .outline)
        #expect(ProjectModel(id: "Q", window: defaults.window()).navigator.shown == .files)
        project.navigator.showForFailedBuild()
        project.navigator.shown = .issues
        project.navigator.returnAfterCleanBuild()
        #expect(project.navigator.shown == .outline)
        project.navigator.showForFailedBuild()
        project.navigator.shown = .search
        project.navigator.returnAfterCleanBuild()
        #expect(project.navigator.shown == .search)
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
    @Test func foldersZipsAndTeXFilesOpenButPackagesDoNotAndAMissingOneIsLeftToTheOpenToReport() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["plain", "b.rtfd"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        for name in ["a.tex", "a.zip", "a.txt"] { try Data().write(to: folder.appending(path: name)) }
        let opens = { (name: String) in AppModel.canOpen(folder.appending(path: name)) }
        #expect(opens("plain") && opens("a.tex") && opens("a.zip") && opens("gone.tex"))
        #expect(!opens("a.txt") && !opens("b.rtfd"))
    }
}

struct SectionTests {
    private let defaults = TestDefaults()

    @Test func theProjectReadsItsSectionsAndAnnouncesAFailedSave() {
        let window = defaults.window()
        let project = ProjectModel(id: "P", window: window)
        let settings = ProjectSettings(mainFile: "main.tex", engine: .pdflatex, stopOnFirstError: false, shellEscape: false)
        let sections: [SessionSection] = [
            .project(ProjectState(name: "Paper", root: "/tmp/Paper", settings: settings, problem: nil)),
            .tree([treeFile("main.tex", main: true), treeFolder("figs", []), treeFile("b.tex")]),
            .documents([DocumentState(path: "b.tex", error: nil, conflict: .changed, asking: false)]),
        ]
        for section in sections { project.handle(.section(section)) }
        #expect(project.name == "Paper")
        #expect(project.settings?.mainFile == "main.tex")
        #expect(project.url("b.tex")?.path(percentEncoded: false) == "/tmp/Paper/b.tex")
        #expect(project.files.map(\.name) == ["figs", "b.tex", "main.tex"])
        project.handle(.section(.tree([treeFile("main.tex", main: true), treeFile("a.tex")])))
        #expect(project.files.map(\.name) == ["a.tex", "main.tex"] && project.files.node(at: "b.tex") == nil)
        #expect(project.saveFailure == "Another app changed “b.tex”.")
        project.handle(.section(.documents([DocumentState(path: "b.tex", error: Message(id: .diskFull, args: [:], text: "The disk is full."),
                                                          conflict: nil, asking: false)])))
        #expect(window.alert?.title == "“b.tex” Wasn’t Saved")
        #expect(project.saveFailure == "The disk is full.")
    }

    @Test func theTrailGoesBackOnlyToFilesTheTreeStillHolds() {
        let project = ProjectModel(id: "P", window: defaults.window())
        let tree = { (files: [TreeNode]) in project.handle(.section(.tree([treeFolder("ch", files), treeFile("main.tex")]))) }
        tree([treeFile("ch/one.tex")])
        project.handle(.section(.openFile(OpenFile(path: "main.tex", kind: .tex, text: true))))
        project.trail.jumped(from: Place(path: "ch/one.tex", line: 3))
        #expect(project.canRetrace(back: true) && !project.canRetrace(back: false))
        project.trail.jumped(from: Place(path: "main.tex", line: 1))
        tree([])
        #expect(!project.canRetrace(back: true))
    }

    @Test func theBuildSectionFeedsTheListAndItsCountsItsLogSectionTheLogAndThePDFSectionTheShownPDF() {
        let window = defaults.window()
        window.layout = .source
        let project = ProjectModel(id: "P", window: window)
        let (error, warning, box) = (logItem(.error, "Line 3", line: 3, args: ["text": "Line 3"]),
                                     logItem(.warning, "Line 5", line: 5, args: ["text": "Line 5"]),
                                     logItem(.warning, "Line 9", line: 9, args: ["text": "Line 9"]))
        let result = CompileResult(ok: false, stopped: false, durationMs: 1200, pdf: nil, badBoxes: [box])
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
        #expect(project.chosenIssue == nil && project.buildLog.isEmpty)
        project.handle(.section(.buildLog("Output written on main.pdf")))
        #expect(project.buildLog == "Output written on main.pdf" && project.result == result)
        let pdf = { (live: Bool) in project.handle(.section(.shownPdf(ShownPdf(path: "/tmp/P/main.pdf", version: 1, live: live)))) }
        pdf(false)
        #expect(project.buildPDF?.path(percentEncoded: false) == "/tmp/P/main.pdf" && !project.livePDF && !window.showPDF)
        pdf(true)
        #expect(project.livePDF && window.showPDF)
    }

    @Test func liveStateIsTheStoresAndAFailureNeedsAttentionWhileTheSessionSaysSo() {
        let project = ProjectModel(id: "P", window: defaults.window())
        let state = { (phase: LivePhase, failures: [Message], attention: Bool, log: String?) in
            let state = LiveState(phase: phase, engine: .xelatex, halted: false, attention: attention, failures: failures, lines: [:])
            project.handle(.section(.live(state)))
            project.handle(.section(.liveLog(log ?? "")))
        }
        state(.stopped, [], false, nil)
        #expect(project.livePhase == .stopped && !project.livePreviewUsed && project.liveLog.isEmpty && !project.liveNeedsAttention)
        state(.running, [], false, "Output written.")
        #expect(project.liveActive && project.livePreviewUsed && project.liveLog == "Output written."
                && String(localized: project.liveTitle) == "Live Preview On")
        let failed = Message(id: .texpressoExited, args: [:], text: "TeXpresso stopped.")
        state(.stopped, [failed], true, nil)
        project.handle(.liveAlert)
        #expect(project.liveNeedsAttention && project.liveLog == "TeXpresso stopped." && project.panel.showsLiveLog)
        state(.stopped, [failed], false, nil)
        #expect(!project.liveNeedsAttention && String(localized: project.liveTitle) == "Live Preview Stopped")
    }

    @Test func eachDiskConflictTheSessionAsksAboutIsAskedUntilItIsAnswered() {
        let project = ProjectModel(id: "P", window: defaults.window())
        let documents = { (asking: [String]) in
            project.handle(.section(.documents(["a.tex", "b.tex"].map {
                DocumentState(path: $0, error: nil, conflict: $0 == "a.tex" ? .gone : .changed, asking: asking.contains($0))
            })))
        }
        documents(["a.tex", "b.tex"])
        #expect(project.conflicts.map(\.path) == ["a.tex", "b.tex"] && project.conflicts[0].conflict == .gone)
        project.answer("b.tex", .cancel)
        #expect(project.conflicts.map(\.path) == ["a.tex"])
        documents(["a.tex", "b.tex"])
        #expect(project.conflicts.map(\.path) == ["a.tex"])
        documents(["a.tex"])
        documents(["a.tex", "b.tex"])
        #expect(project.conflicts.map(\.path) == ["a.tex", "b.tex"])
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

    @Test func aNameFieldSelectsTheBaseNameAndTakesFastTypingInOrder() async throws {
        let rename = InPlaceRename<String>()
        let window = KeyOnlyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
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

    @Test func aDialogFieldShowsATypedSpaceAtOnce() async throws {
        let defaults = TestDefaults(), model = defaults.window()
        let window = KeyOnlyWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NewProjectSheet(draft: NewProjectDraft(template: .blank, name: "water"))
            .environment(model.app).environment(model))
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { window.firstResponder is NSTextView }
        let editor = try #require(window.firstResponder as? NSTextView)
        let field = try #require(editor.delegate as? NSTextField)
        let caret = { editor.firstRect(forCharacterRange: NSRange(location: $0, length: 0), actualRange: nil).minX }
        editor.insertText(" ", replacementRange: NSRange(location: 5, length: 0))
        try await waitUntil {
            let bounds = window.convertToScreen(field.convert(field.bounds, to: nil))
            let afterSpace = editor.firstRect(forCharacterRange: .caret(6), actualRange: nil)
            return bounds.contains(NSPoint(x: afterSpace.minX, y: afterSpace.midY))
        }
        #expect(editor.string == "water ")
        #expect(caret(6) > caret(5))
    }
}

private final class KeyOnlyWindow: NSWindow {
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

    @Test func eachProjectOpensInAWindowOfItsOwnOnceEvenWhenOpenedTwiceAtOnceAndHomeNeverHoldsOne() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let app = defaults.app()
        let home = app.showHome()
        async let opened: Void = home.open(first.id)
        async let again: Void = home.open(first.id)
        _ = await (opened, again)
        let window = try #require(app.window(showing: first.id))
        #expect(app.windows.count == 2 && window.project?.initialLoadComplete == true && home.project == nil)
        await window.open(second.id)
        let other = try #require(app.window(showing: second.id))
        #expect(other !== window && window.project?.id == first.id && app.windows.count == 3 && app.recentProjects == [second.id, first.id])
        await other.open(first.id)
        #expect(app.windows.count == 3 && other.project?.id == second.id)
        #expect(!app.canChange(first) && !app.canChange(second))
        #expect(await window.close() && other.project?.isOpen == true)
        #expect(app.canChange(first) && !app.canChange(second))
        #expect(await other.close())
    }

    @Test func aProjectStillOpensWhenTheWindowThatAskedHasClosedMeanwhile() async throws {
        let info = try await newProject()
        let app = defaults.app()
        let home = app.showHome()
        home.windowClosed()
        await home.open(info.id)
        let window = try #require(app.window(showing: info.id))
        #expect(window.project?.isOpen == true && app.windows.count == 1)
        #expect(await window.close())
    }

    @Test func theMenusActOnTheMainWindowAndOpenRecentOnTheLastOneUsedOrOnHomeWhenNoneIsOpen() {
        let app = defaults.app()
        let home = app.front
        #expect(app.main == nil && app.home === home && app.windows.count == 1)
        let (window, other) = (app.openWindow("A"), app.openWindow("B"))
        #expect(app.front === home)
        other.isMain = true
        #expect(app.main === other && app.front === other)
        (other.isMain, window.isMain) = (false, true)
        #expect(app.main === window && app.windows.first === window)
        window.isMain = false
        #expect(app.main == nil && app.front === window)
        window.windowClosed()
        #expect(app.front === other)
    }

    @Test func eachProjectReopensInTheLayoutItWasLeftInAndANewOneInTheLastLayoutUsed() {
        let app = defaults.app()
        func shown(_ id: String, _ layout: WorkspaceLayout? = nil) -> WorkspaceLayout {
            let controller = MainWindowController(app: app, project: id)
            defer { controller.window?.close() }
            if let layout { controller.model.layout = layout }
            return controller.model.layout
        }
        _ = shown("A", .pdf)
        _ = shown("B", .source)
        #expect(shown("A") == .pdf && shown("B") == .source && shown("C") == .source)
    }

    @Test func theMenusKeepActingOnTheProjectWindowWhileAPanelSuchAsTheSymbolLibraryIsKey() throws {
        let app = defaults.app()
        let controller = MainWindowController(app: app, project: "P")
        let window = try #require(controller.window)
        defer { window.close() }
        let post = { NotificationCenter.default.post(name: $0, object: window) }
        post(NSWindow.didBecomeMainNotification)
        post(NSWindow.didBecomeKeyNotification)
        post(NSWindow.didResignKeyNotification)
        #expect(app.main === controller.model)
        post(NSWindow.didResignMainNotification)
        #expect(app.main == nil)
    }

    @Test func aStoppedProjectClosesAtOnceWithNothingUnsavedAndOtherwiseOnlyOnceItsEditsAreLetGo() async throws {
        let window = defaults.window()
        let saved = ProjectModel(id: "P", window: window)
        window.project = saved
        saved.handle(.section(.lifecycle(.stopped(Stopped(unsaved: [])))))
        #expect(await window.end() && saved.closed && window.alert == nil)

        let lost = ProjectModel(id: "Q", window: window)
        window.project = lost
        lost.handle(.section(.lifecycle(.stopped(Stopped(unsaved: ["main.tex"])))))
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
        let home = app.showHome()
        await home.open(info.id)
        await home.delete(info)
        #expect(FileManager.default.fileExists(atPath: info.path) && home.alert != nil)
        #expect(await app.window(showing: info.id)?.close() == true)
    }

    @Test func quitLeavesEveryProjectOpenWhileOneHasADocumentItCantSave() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let app = defaults.app()
        let home = app.showHome()
        await home.open(first.id)
        await home.open(second.id)
        let (window, held) = (try #require(app.window(showing: first.id)), try #require(app.window(showing: second.id)?.project))
        let document = try #require(SourceDocument(session: held.session, path: "main.tex"))
        _ = document.edit(NSRange(location: 0, length: 0), with: "% mine\n", changing: nil, mirroring: false)
        try "theirs\n".write(toFile: second.path + "/main.tex", atomically: true, encoding: .utf8)
        try await waitUntil { !held.conflicts.isEmpty }
        #expect(await !app.quit())
        #expect(window.project?.isOpen == true && held.isOpen && held.conflicts.map(\.path) == ["main.tex"])
        held.answer("main.tex", .revert)
        #expect(await app.quit())
        #expect(window.project?.closed == true && held.closed)
    }

    @Test func aCancelledQuitForgetsCloseWithoutSavingSoSaveStillFailsAndClosingAsksAgain() async throws {
        let (first, second) = (try await newProject(), try await newProject())
        let app = defaults.app()
        let home = app.showHome()
        await home.open(first.id)
        await home.open(second.id)
        let (window, other) = (try #require(app.window(showing: first.id)), try #require(app.window(showing: second.id)))
        let (project, held) = (try #require(window.project), try #require(other.project))
        let typed = try [(first, project), (second, held)].map { info, project in
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: info.path + "/main.tex")
            let document = try #require(SourceDocument(session: project.session, path: "main.tex"))
            _ = document.edit(NSRange(location: 0, length: 0), with: "% mine\n", changing: nil, mirroring: false)
            return document
        }
        let quitting = Task { await app.quit() }
        try await waitUntil { project.askingToDiscard != nil }
        project.answerDiscard(true)
        try await waitUntil { held.askingToDiscard != nil }
        held.answerDiscard(false)
        #expect(await !quitting.value && project.isOpen && held.isOpen)

        _ = typed[0].edit(NSRange(location: 0, length: 0), with: "% again\n", changing: nil, mirroring: false)
        #expect(await !project.save() && window.alert?.title == "“main.tex” Wasn’t Saved")
        let closing = Task { await window.close() }
        try await waitUntil { project.askingToDiscard != nil }
        project.answerDiscard(false)
        #expect(await !closing.value && project.isOpen && typed[0].text.hasPrefix("% again\n% mine\n"))
        for info in [first, second] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: info.path + "/main.tex")
        }
        #expect(await window.close())
        #expect(await other.close())
    }
}

struct ViewsTests {
    private let defaults = TestDefaults()

    @Test func aProjectOnItsCoreTellsItsViewsWhatTheStoreShows() async throws {
        let info = try await newProject()
        let window = defaults.window()
        let project = ProjectModel(id: info.id, window: window)
        let views = Views(project)
        let device = Core.stateFolder.appending(path: ".ui", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        try #"{ "ui": { "file": "main.tex", "line": 3 } }"#.write(to: device.appending(path: "\(info.id).json"), atomically: true, encoding: .utf8)
        try await project.load()
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

    @Test func aFolderOpenedOrAHeadingFoldedWhileARenameOrItsUndoIsPendingStaysThatWayAndIsSaved() async throws {
        let info = try await newProject()
        let window = defaults.window(), host = UndoHost()
        window.controller = host
        let undo = try #require(host.undoManager)
        undo.groupsByEvent = false
        let reopened = { () async throws -> (Set<String>, Set<String>) in
            let project = ProjectModel(id: info.id, window: window)
            try await project.load()
            defer { _ = project.close() }
            return (project.expandedFolders, project.foldedHeadings)
        }
        let project = ProjectModel(id: info.id, window: window)
        try await project.load()
        let folder = try #require(await project.createEntry(in: "", directory: true))
        project.expandedFolders = [folder]
        project.foldedHeadings = ["\(folder)/a.tex\tIntro"]
        undo.beginUndoGrouping()
        let rename = Task.immediate { await project.renameEntry(folder, to: "moved") }
        project.expandedFolders.insert("other")
        project.foldedHeadings.insert("main.tex\tIntro")
        await rename.value
        undo.endUndoGrouping()
        #expect(project.expandedFolders == ["moved", "other"])
        #expect(project.foldedHeadings == ["moved/a.tex\tIntro", "main.tex\tIntro"])

        undo.undo()
        project.expandedFolders.insert("more")
        project.foldedHeadings.insert("main.tex\tMethod")
        try await waitUntil { project.files.node(at: folder) != nil && project.expandedFolders.contains(folder) }
        let expanded: Set = [folder, "other", "more"]
        let folded: Set = ["\(folder)/a.tex\tIntro", "main.tex\tIntro", "main.tex\tMethod"]
        #expect(project.expandedFolders == expanded && project.foldedHeadings == folded)
        #expect(await project.close().value)
        let saved = try await reopened()
        #expect(saved.0 == expanded && saved.1 == folded)
    }

    @Test func deletingAnEntryMovesItToTheTrashWithItsUndoOnTheWindow() async throws {
        let info = try await newProject()
        let window = defaults.window(), host = UndoHost()
        window.controller = host
        let project = ProjectModel(id: info.id, window: window)
        try await project.load()
        let path = try #require(await project.createEntry(in: "", directory: false))
        let shown = { FileManager.default.fileExists(atPath: info.path + "/" + path) && project.files.node(at: path) != nil }
        let undo = try #require(host.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        await project.deleteEntry(path)
        undo.endUndoGrouping()
        #expect(!shown() && undo.undoActionName == "Move to Trash" && window.alert == nil)
        undo.undo()
        try await waitUntil { shown() }
        undo.redo()
        try await waitUntil { !shown() }
        undo.undo()
        try await waitUntil { shown() }
        #expect(window.alert == nil)
        #expect(await project.close().value)
    }

    @Test func aRestoreOrAFixTheEditorRefusesSaysSoAndTheFixDoesntCompile() async throws {
        let info = try await newProject()
        let window = defaults.window()
        let project = ProjectModel(id: info.id, window: window)
        let views = Views(project)
        try await project.load()
        let chapter = info.path + "/ch.tex"
        try "first\n".write(toFile: chapter, atomically: true, encoding: .utf8)
        let snapshot = try #require(try await project.session.call(SaveVersion(name: "First")))
        try "second\n".write(toFile: chapter, atomically: true, encoding: .utf8)
        let document = try #require(SourceDocument(session: project.session, path: "main.tex"))
        _ = document.edit(NSRange(location: 0, length: 0), with: "% mine\n", changing: nil, mirroring: false)
        let error = await #expect(throws: AppFailure.self) { try await project.restoreVersion(snapshot, paths: nil) }
        #expect(error?.localizedDescription == "The file shown changed meanwhile, so nothing was changed. Try again.")
        #expect(try String(contentsOfFile: chapter, encoding: .utf8) == "second\n")
        let text = Message(id: .addPackageTitle, args: [:], text: "Add the Package")
        let library = window.app.core.library
        try await waitUntil { library.tex != nil }
        let found = try #require(library.tex)
        var available = found
        available.available = true
        library.apply(.tex(available))
        await project.run(Fix(id: "package:texlocal", title: text, help: text, confirm: nil))
        library.apply(.tex(found))
        #expect(window.alert?.message == "The file shown changed meanwhile, so nothing was changed. Try again.")
        #expect(views.refused == ["main.tex", "main.tex"])
        #expect(!project.compiling && project.result == nil)
        #expect(await project.close().value)
    }

    @Test func rollbackRestoresAFileOpenedBeforeCompensation() async throws {
        for refusing in [false, true] {
            let info = try await newProject()
            let window = defaults.window()
            let project = ProjectModel(id: info.id, window: window)
            let workspace = WorkspaceViews(project: project), views = Views(project)
            project.session.heard = { project.handle($0); workspace.heard($0) }
            try await project.load()
            let chapter = info.path + "/ch.tex", text = workspace.editor.textView
            try "first\n".write(toFile: chapter, atomically: true, encoding: .utf8)
            let snapshot = try #require(try await project.session.call(SaveVersion(name: "First")))
            try "second\n".write(toFile: chapter, atomically: true, encoding: .utf8)
            text.insertText("% mine\n", replacementRange: .caret(0))
            views.onApply = { edits, name in
                if edits.path == "main.tex" {
                    project.session.send(Open(path: "ch.tex"))
                    return false
                }
                if refusing { text.insertText("% newer\n", replacementRange: .caret(0)) }
                return workspace.apply(edits, named: name)
            }
            let error = await #expect(throws: AppFailure.self) { try await project.restoreVersion(snapshot, paths: nil) }
            let expected = refusing ? "% newer\nfirst\n" : "second\n"
            #expect(project.openPath == "ch.tex" && workspace.editor.path == "ch.tex")
            #expect(text.string == expected && text.document.text == expected)
            #expect(await project.save())
            #expect(try String(contentsOfFile: chapter, encoding: .utf8) == expected)
            if refusing {
                let recovery = try #require(try await project.session.call(ListVersions()).last { $0.reason == .restore })
                #expect(error?.localizedDescription.contains("ch.tex") == true)
                #expect(error?.localizedDescription.contains(recovery.id) == true)
                #expect(error?.localizedDescription.contains("changes remain") == true)
            } else {
                #expect(error?.localizedDescription == "The file shown changed meanwhile, so nothing was changed. Try again.")
                #expect(text.undo.undoActionName == "Restore")
            }
            #expect(await project.close().value)
        }
    }

    @Test func aCleanBuildOfTheShownTeXSyncsThePDFAndAFailedCompileAsksForAttention() async throws {
        let window = defaults.window()
        window.app.syncAfterCompile = true
        let project = ProjectModel(id: "P", window: window)
        let views = Views(project)
        let build = { (ok: Bool, outdated: Bool) in
            let result = CompileResult(ok: ok, stopped: false, durationMs: 0, pdf: nil, badBoxes: [])
            project.handle(.section(.build(BuildState(compiling: false, auto: false, outdated: outdated, result: result, issues: [], lines: [:]))))
        }
        build(true, false)
        #expect(!project.syncsAfterBuild)
        project.handle(.section(.openFile(OpenFile(path: "main.tex", kind: .tex, text: true))))
        #expect(project.syncsAfterBuild)
        project.handle(.buildFinished(BuildFinished(auto: false, announce: false)))
        try await waitUntil { project.syncTask != nil }
        await project.syncTask?.value
        build(true, true)
        #expect(!project.syncsAfterBuild)
        build(true, false)
        window.layout = .source
        #expect(!project.syncsAfterBuild)
        window.layout = .split
        window.app.syncAfterCompile = false
        #expect(!project.syncsAfterBuild)
        build(false, false)
        project.handle(.buildFinished(BuildFinished(auto: true, announce: true)))
        #expect(views.attention == 0)
        project.handle(.buildFinished(BuildFinished(auto: false, announce: false)))
        #expect(views.attention == 1 && project.navigator.shown == .issues)
    }

    @Test func aDoubleClickSyncsOnlyToAPaneThatShows() async {
        let window = defaults.window()
        let project = ProjectModel(id: "P", window: window)
        let views = Views(project)
        project.handle(.section(.openFile(OpenFile(path: "main.tex", kind: .tex, text: true))))
        #expect(!project.canSyncForward())
        views.hasPDF = true
        window.layout = .source
        #expect(project.canSyncForward() && !project.canSyncForward(quietly: true))
        window.layout = .split
        #expect(project.canSyncForward(quietly: true))
        window.layout = .pdf
        await project.inverseSync(page: 0, x: 0, y: 0, quietly: true)
        #expect(project.syncTask == nil)
        await project.inverseSync(page: 0, x: 0, y: 0)
        #expect(project.syncTask != nil)
    }

    @Test func quietSyncDoesNotReopenAPaneHiddenWhileItsReplyIsPending() async throws {
        let info = try await newProject()
        let root = URL(filePath: info.path), build = root.appending(path: "build")
        try "First paragraph.\n".write(to: root.appending(path: "main.tex"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try blankPDF(count: 1).write(to: build.appending(path: "main.pdf"))
        try """
        SyncTeX Version:1
        Input:1:main.tex
        Output:pdf
        Magnification:1000
        Unit:1
        X Offset:0
        Y Offset:0
        Content:
        {1
        [1,1:4736286,46220574:26673152,41484288,0
        (1,1:8799518,8865054:22609920,455111,0
        g1,1:11475574,8865054
        )
        ]
        }1
        Postamble:

        """.write(to: build.appending(path: "main.synctex"), atomically: true, encoding: .utf8)
        let window = defaults.window(), host = UndoHost()
        window.controller = host
        let project = ProjectModel(id: info.id, window: window)
        let views = Views(project)
        try await project.load()
        views.hasPDF = true
        let loc = try await project.session.call(SynctexForward(file: "main.tex", line: 1))
        let x = try #require(loc.h) + 1, y = try #require(loc.v) - #require(loc.height) / 2
        for forward in [true, false] {
            for quietly in [true, false] {
                window.layout = .split
                views.revealed = []
                host.pdfActions = []
                project.syncTask = nil
                let syncing = Task.immediate {
                    if forward { await project.forwardSync(quietly: quietly) }
                    else { await project.inverseSync(page: 1, x: x, y: y, click: PageClick(text: "First paragraph.", at: 1), quietly: quietly) }
                }
                try #require(project.syncTask != nil)
                window.layout = forward ? .source : .pdf
                await syncing.value
                #expect((forward ? window.showPDF : window.showSource) == !quietly)
                #expect(host.pdfActions.count == (forward && !quietly ? 1 : 0))
                #expect(views.revealed == (!forward && !quietly ? ["main.tex:1"] : []))
                #expect(window.alert == nil)
            }
        }
        #expect(await project.close().value)
    }

    @Test func theLivePDFShowsWhileLivePreviewRunsUntilTheProjectCloses() async {
        let project = ProjectModel(id: "P", window: defaults.window())
        let live = { (phase: LivePhase) in
            project.handle(.section(.live(LiveState(phase: phase, engine: .pdflatex, halted: false, attention: false, failures: [], lines: [:]))))
        }
        live(.running)
        #expect(!project.showsLive)
        project.handle(.section(.shownPdf(ShownPdf(path: nil, version: 1, live: true))))
        #expect(project.showsLive)
        live(.stopped)
        #expect(!project.showsLive)
        live(.running)
        #expect(await project.close().value && !project.showsLive)
    }

    @Test func clickingAnIssueInTheTextChoosesItOrShowsTheLivePreviewLog() {
        let project = ProjectModel(id: "P", window: defaults.window())
        let message = Message(id: .tex, args: [:], text: "Undefined control sequence.")
        let lines = { (line: Int, index: Int?) in
            ["main.tex": [IssueLine(line: line, error: true, message: message, short: message, compact: nil, tokens: [], others: [], index: index)]]
        }
        project.handle(.section(.build(BuildState(compiling: false, auto: false, outdated: false, result: nil, issues: [], lines: lines(3, 1)))))
        project.handle(.section(.live(LiveState(phase: .running, engine: .pdflatex, halted: false, attention: false, failures: [], lines: lines(5, nil)))))
        project.issueClicked(atLine: 5, in: "main.tex")
        #expect(project.panel.showsLiveLog && project.chosenIssue == nil)
        project.issueClicked(atLine: 3, in: "main.tex")
        #expect(project.navigator.shown == .issues && project.chosenIssue == 1)
        project.panel.shown = false
        project.navigator.shown = .files
        project.issueClicked(atLine: 3, in: "other.tex")
        #expect(!project.panel.shown && project.navigator.shown == .files)
    }

    @Test func aDroppedFigureIsIncludedOrCopiedInAndAProjectFileOpens() {
        let project = ProjectModel(id: "P", window: defaults.window())
        let settings = ProjectSettings(mainFile: "main.tex", engine: .pdflatex, stopOnFirstError: false, shellEscape: false)
        project.handle(.section(.project(ProjectState(name: "Paper", root: "/tmp/Paper", settings: settings, problem: nil))))
        project.handle(.section(.tree([treeFile("main.tex", .tex), treeFile("plot.png", .image), treeFile("refs.bib", .bib)])))
        project.handle(.section(.openFile(OpenFile(path: "main.tex", kind: .tex, text: true))))
        let drop = { (path: String) in project.dropAction(for: URL(filePath: path)) }
        #expect(drop("/tmp/Paper/plot.png") == .insert("\\includegraphics{plot.png}") && drop("/tmp/Paper/refs.bib") == .open("refs.bib"))
        #expect(drop("/tmp/Paper/gone.png") == nil && drop("/Users/me/shot.png") == .copy && drop("/Users/me/notes.txt") == nil)
        project.handle(.section(.openFile(OpenFile(path: "refs.bib", kind: .bib, text: true))))
        #expect(drop("/tmp/Paper/plot.png") == .open("plot.png") && drop("/Users/me/shot.png") == nil)
    }

    private final class Views: ProjectViews {
        private let project: ProjectModel
        var ui: UiState?
        var shown: [String] = [], revealed: [String] = [], moved: [String] = [], refused: [String] = []
        var hasPDF = false, attention = 0
        var onApply: ((DocumentEdits, String) -> Bool)?

        init(_ project: ProjectModel) {
            self.project = project
            project.views = self
        }

        let zoom = Zoom.fitWidth, pdfPlace: PdfPlace? = nil, shownPDF: AnyObject? = nil, inspectorShown = false, pdfLoading: Task<Void, Never>? = nil

        func heard(_ event: Event) {
            if case .section(.openFile(let file?)) = event, project.openPath == file.path { shown.append(file.path) }
            if case .renamed(let renamed) = event { moved += [renamed.from, renamed.to] }
        }

        func opened(_ ui: UiState) { self.ui = ui }

        func reveal(_ path: String, line: Int?, column: Int?, length: Int?, atTop: Bool, focus: Bool) {
            revealed.append(path + (line.map { ":\($0)" } ?? ""))
        }
        func apply(_ edits: DocumentEdits, named name: String) -> Bool {
            if let onApply { return onApply(edits, name) }
            refused.append(edits.path)
            return false
        }
        func replace(_ hit: SearchHit, with text: String) -> Bool { false }
        func trashed(_ path: String) {}
        func beep() {}
        func requestAttention() { attention += 1 }
        func perform(_ command: EditorCommand) {}
        func perform(_ command: MenuCommand) {}
        func validates(_ command: MenuCommand) -> Bool { false }
    }

    private final class UndoHost: AppWindow {
        let undoManager: UndoManager? = UndoManager()
        var pdfActions: [PDFAction] = []
        func performPDF(_ action: PDFAction) { pdfActions.append(action) }
        func revealSidebar() {}
        func focusSearch() {}
        func show() {}
        func close() {}
    }
}

struct FilterKindTests {
    private let defaults = TestDefaults()

    @Test func aKindTheMenuHidesLeavesTheIssueListAndComesBackWhenShownAgain() {
        let navigator = ProjectModel(id: "P", window: defaults.window()).navigator
        let (error, reference) = (logItem(.error, "Missing $ inserted.", args: ["text": "Missing $ inserted."]),
                                  logItem(.warning, "There were undefined references.", args: ["text": "There were undefined references."],
                                          topic: .undefinedReference))
        navigator.hiddenIssueKinds = [.undefinedReference]
        #expect(navigator.rows(of: [error, reference]).map(\.element) == [error])
        navigator.hiddenIssueKinds = []
        navigator.showsOnlyErrors = true
        #expect(navigator.rows(of: [error, reference]).map(\.element) == [error])
        #expect(navigator.hiddenIssueKinds == IssueKind.warnings)
        navigator.hiddenIssueKinds.insert(.error)
        #expect(navigator.rows(of: [error, reference]).isEmpty)
        navigator.showsOnlyErrors = false
        #expect(navigator.hiddenIssueKinds == [.error])
        navigator.hiddenIssueKinds = []
        #expect(navigator.rows(of: [error, reference]).map(\.element) == [error, reference])
    }
}
