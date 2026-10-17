import AppKit
import Testing
@testable import TeXLocal

/// Home's and the Dock menu's flows, in `ProjectFlowTests` for its library and its clean-up.
extension ProjectFlowTests {
    @Test func aRefusalOnHomeIsAnAlertThatNamesIt() async throws {
        let missing = files.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        await app.importProject(from: missing)
        #expect(app.alert?.title == "Couldn’t Open “\(missing.lastPathComponent)”" && app.project == nil && !app.isOpening)
        let recents = app.recentProjects
        let gone = ProjectInfo(id: "No Such Project \(UUID().uuidString.prefix(8))", name: "Gone", mtime: 0, mainFile: "main.tex")
        await app.rename(gone, to: "Elsewhere")
        #expect(app.alert?.title == "Couldn’t Rename “Gone”" && app.recentProjects == recents)
    }

    @Test func aNewProjectOpensItsSheetWithTheTemplateAndAFreeName() async throws {
        app.newProject(.report)
        // Once the core has named it.
        try await waitUntil { app.newProjectDraft != nil }
        #expect(app.newProjectDraft?.template == .report && app.newProjectDraft?.name.isEmpty == false)
        app.newProjectDraft = nil
    }

    @Test func theDockMenuOpensARecentProject() async throws {
        let first = try await project("first").info, second = try await project("second").info
        await app.refresh()
        var shown = 0
        let dock = DockMenu(app: app) { shown += 1 }
        app.recentProjects = []
        #expect(dock.menu.items.map(\.title) == ["New Project…"])
        app.recentProjects = [second.id, "Gone", first.id]
        let menu = dock.menu
        #expect(menu.items.map(\.title) == [second.name, first.name, "", "New Project…"])
        menu.performActionForItem(at: 3)
        // Once the core has named it.
        try await waitUntil { app.newProjectDraft != nil }
        #expect(shown == 1)
        app.newProjectDraft = nil
        menu.performActionForItem(at: 1)
        try await waitUntil(timeout: .seconds(5)) { app.project?.id == first.id && app.project?.initialLoadComplete == true }
        #expect(shown == 2 && app.recentProjects.first == first.id)
        #expect(NSApp.delegate?.responds(to: #selector((any NSApplicationDelegate).applicationDockMenu(_:))) == true)
        await app.close()
    }
}
