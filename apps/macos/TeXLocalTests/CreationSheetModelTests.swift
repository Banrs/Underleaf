import Foundation
import Testing
@testable import TeXLocal

/// Failed creation must return to the sheet rather than consume its request or
/// send an alert to the parent window. A corrected name can then be submitted.
@MainActor
final class CreationSheetModelTests {
    private static let keys = [DefaultsKey.autoCompile, DefaultsKey.recentProjects]
    private let kept: [Any?]
    private var folders: [URL] = []
    private let app: AppModel

    init() throws {
        _ = try #require(ProcessInfo.processInfo.environment["TEXLOCAL_DATA"])
        kept = Self.keys.map { UserDefaults.standard.object(forKey: $0) }
        app = AppModel()
        app.autoCompile = false
    }

    isolated deinit {
        app.project?.close()
        for (key, value) in zip(Self.keys, kept) { UserDefaults.standard.set(value, forKey: key) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    @Test func duplicateNamesCanBeCorrectedAndRetried() async throws {
        let taken = "Creation Test \(UUID().uuidString.prefix(8))"
        folders.append(Core.libraryFolder.appending(path: taken))
        try await app.create(name: taken, template: "blank")
        let original = try #require(app.project)

        await #expect(throws: CoreError.self) { try await app.create(name: taken, template: "article") }
        #expect(app.project === original)
        #expect(app.alert?.title == nil)

        let corrected = "Creation Retry \(UUID().uuidString.prefix(8))"
        folders.append(Core.libraryFolder.appending(path: corrected))
        try await app.create(name: corrected, template: "blank")
        let project = try #require(app.project)
        #expect(project.id == corrected)
        #expect(app.projects.contains { $0.id == corrected })

        try await project.createEntry("parts", directory: true)
        try await project.createEntry("parts/chapter.tex", directory: false)
        await #expect(throws: CoreError.self) { try await project.createEntry("parts/chapter.tex", directory: false) }
        #expect(project.openPath == "parts/chapter.tex")
        #expect(app.alert?.title == nil)

        try await project.createEntry("parts/corrected.tex", directory: false)
        #expect(project.openPath == "parts/corrected.tex")
        #expect(project.tree.flattened.contains { $0.path == "parts/corrected.tex" })
        #expect(app.alert?.title == nil)
    }
}
