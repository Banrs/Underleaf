import Foundation

extension ProjectModel {
    func replaceAll() async {
        let asked = search.searched
        let replace = Replace(query: asked.query, replacement: search.replacement, matchCase: asked.matchCase, wholeWord: asked.wholeWords)
        guard let answer = await alerting("Couldn’t Replace “\(asked.query)”", {
            try await editProject(replace, named: String(localized: "Replace"))
        }) else { return }
        let count = (answer.edits?.edits.count ?? 0) + answer.written.reduce(0) { $0 + $1.count }
        let files = answer.written.count + (answer.edits == nil ? 0 : 1)
        notices.note(String(AttributedString(localized: "Replaced ^[\(count) match](inflect: true) in ^[\(files) file](inflect: true)")
            .characters))
        await search.run { try await session.call($0) }
    }

    var shownGroups: [SearchGroup] { navigator.filtered(search.groups ?? []) }

    func replaceChosen() async {
        let shown = shownGroups.flatMap(\.hits)
        guard let hit = shown.first(where: { $0.id == search.chosen }) else { return }
        let replacement = search.replacement
        guard views?.replace(hit, with: replacement) == true else {
            // The hit's text changed since the search, so it isn't replaced unseen.
            views?.beep()
            return
        }
        guard await search.run({ try await session.call($0) }) else { return }
        search.choose(after: hit, replacingWith: replacement, in: shownGroups)
    }

    func findUsages(in path: String, at offset: Int) async {
        guard let found = await alerting("Couldn’t Find Usages", {
            try await session.call(FindUsages(path: path, offset: offset))
        }) else { return }
        guard let found else {
            views?.beep()
            return
        }
        search.show(found)
        showNavigator(.search)
    }

    func quickHelp(in path: String, at offset: Int) async -> QuickHelp? {
        guard let answer = await alerting("Couldn’t Show Quick Help", {
            try await session.call(LookUp(path: path, offset: offset))
        }) else { return nil }
        if answer == nil { views?.beep() }
        return answer
    }

    func renameSymbol(_ symbol: SymbolName, to name: String) async throws {
        try await editProject(RenameSymbol(kind: symbol.kind, from: symbol.name, to: name), named: String(localized: "Rename"))
    }

    func addCitation(_ source: CitationSource) async throws {
        guard let url = URL(string: source.url) else {
            throw AppFailure.wentWrong
        }
        let citing = openPath
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(source.accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let fetched = String(data: data, encoding: .utf8) else {
            throw AppFailure(status == 404 ? String(localized: "No record of “\(source.id)” was found at \(url.host() ?? "").")
                             : String(localized: "\(url.host() ?? "") couldn’t be reached (HTTP \(status)). Try again later."))
        }
        let added = try await session.call(AddCitation(entry: fetched))
        let name = String(localized: "Add Citation")
        if let edits = added.edits { try await applying(edits, named: name) }
        // Only where it was asked for: the person may have moved to another file while it was fetched.
        if openPath == citing { views?.perform(.cite(added.key)) }
        notices.note(added.edits == nil ? String(localized: "Cited “\(added.key)” from “\(added.file)”")
                     : String(localized: "Added “\(added.key)” to “\(added.file)”"))
    }

    func saveVersion(named name: String) async throws {
        if let saved = try await session.call(SaveVersion(name: name)) { notices.note(String(localized: "Saved Version “\(saved.title)”")) }
    }

    func restoreVersion(_ snapshot: Snapshot, paths: [String]?) async throws {
        try await editProject(RestoreVersion(id: snapshot.id, paths: paths), named: String(localized: "Restore"))
    }

    @discardableResult
    private func editProject<R: SessionRequest>(_ request: R, named name: String) async throws -> ProjectEdits
        where R.Reply == ProjectEdits {
        let answer = try await session.call(request)
        try await applying(answer, named: name)
        return answer
    }

    private func applying(_ edits: ProjectEdits, named name: String) async throws {
        if apply(edits.edits, named: name) { return }
        if let snapshot = edits.snapshot, !edits.written.isEmpty {
            try await session.call(RestoreVersion(id: snapshot, paths: edits.written.map(\.file)))
        }
        throw Self.unchanged
    }

    private static let unchanged = AppFailure(String(localized: "The file shown changed meanwhile, so nothing was changed. Try again."))

    private func apply(_ edits: DocumentEdits?, named name: String) -> Bool {
        guard let edits else { return true }
        return views?.apply(edits, named: name) ?? false
    }

    func run(_ fix: Fix) async {
        fixing = fix
        defer { fixing = nil }
        guard await alerting("Couldn’t \(fix.title.text)", {
            guard let fixed = try await session.call(ApplyFix(id: fix.id)) else { return false }
            guard apply(fixed.edits, named: fix.title.text) else { throw Self.unchanged }
            return true
        }) == true else { return }
        await compile()
    }

    func insert(_ template: Template) {
        views?.perform(template.inline ? .inline(template: template.body, title: template.title)
                                       : .block(id: template.body, title: template.title))
    }
}
