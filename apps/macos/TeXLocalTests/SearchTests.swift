import AppKit
import Testing
@testable import TeXLocal

struct SearchTests {
    @Test(arguments: [false, true], [false, true])
    func anOlderReplyCannotReplaceNewerResultsOrTheirSelection(fails: Bool, changesQuery: Bool) async throws {
        let search = ProjectSearch()
        search.query = "needle"
        var reply: CheckedContinuation<[SearchGroup], any Error>?
        let old = Task { await search.run { _ in try await withCheckedThrowingContinuation { reply = $0 } } }
        try await waitUntil { reply != nil }
        if changesQuery { search.query = "other"; search.query = "needle" }
        let current = groups("new.tex")
        await search.run { _ in current }
        search.chosen = current[0].hits[0].id
        if fails { reply?.resume(throwing: AppFailure("Old failure")) } else { reply?.resume(returning: groups("old.tex")) }
        #expect(await old.value == false)
        #expect(search.groups == current && search.chosen == current[0].hits[0].id && search.failure == nil)
    }

    @Test(arguments: [false, true])
    func cancellationAndUsagesPreventAPendingSearchFromPublishing(showUsages: Bool) async throws {
        let search = ProjectSearch()
        search.query = "needle"
        var reply: CheckedContinuation<[SearchGroup], any Error>?
        let old = Task { await search.run { _ in try await withCheckedThrowingContinuation { reply = $0 } } }
        try await waitUntil { reply != nil }
        if showUsages { search.show(Usages(name: "needle", groups: groups("usages.tex"))) } else { old.cancel() }
        reply?.resume(returning: groups("old.tex"))
        #expect(await old.value == false)
        #expect(search.groups == (showUsages ? groups("usages.tex") : nil))
    }

    @Test func clearingAQueryInvalidatesItsPendingReply() async throws {
        let search = ProjectSearch()
        search.query = "needle"
        var reply: CheckedContinuation<[SearchGroup], any Error>?
        let old = Task { await search.run { _ in try await withCheckedThrowingContinuation { reply = $0 } } }
        try await waitUntil { reply != nil }
        search.query = ""
        await search.run { _ in Issue.record("An empty query must not reach the core"); return [] }
        reply?.resume(returning: groups("old.tex"))
        #expect(await old.value == false && search.groups == nil && search.chosen == nil)
    }

    private func groups(_ file: String) -> [SearchGroup] {
        [SearchGroup(file: file, hits: [SearchHit(file: file, line: 1, column: 0, length: 6, before: "", match: "needle", after: "")])]
    }
}

struct SearchIntegrationTests {
    @Test(arguments: [
        ("needle", "done", "b.tex", 0),
        ("needleneedle", "", "a.tex", 0),
        ("needle needle", "🔎", "a.tex", 3),
        ("needle", "needle!", "b.tex", 0),
        ("needle", "needle\n🔎needle", "b.tex", 0),
    ])
    func replacementContinuesAfterTheInsertedText(initial: String, replacement: String, file: String, column: Int) async throws {
        let info = try await newProject(template: .blank)
        for (path, text) in [("a.tex", initial), ("b.tex", "needle"), ("c.tex", "needle")] {
            try text.write(toFile: info.path + "/" + path, atomically: true, encoding: .utf8)
        }
        let defaults = TestDefaults(), window = defaults.window()
        let project = ProjectModel(id: info.id, window: window), views = WorkspaceViews(project: project)
        try await project.load()
        await project.open("a.tex", focus: false)
        project.search.query = "needle"
        project.search.replacement = replacement
        await project.search.run { try await project.session.call($0) }
        project.search.chosen = try #require(project.search.groups?.first?.hits.first?.id)
        await project.replaceChosen()
        #expect(project.search.chosen == "\(file):1:\(column)")
        #expect(views.editor.textView.string == replacement + initial.dropFirst(6))
        #expect(await project.close().value)
    }
}
