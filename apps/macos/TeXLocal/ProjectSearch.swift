import AppKit
import Observation

@Observable
final class ProjectSearch {
    private let core = Core.shared

    /// The field's text and the options of its menu, Pages' Find options.
    nonisolated struct Asked: Hashable {
        var query = "", matchCase = false, wholeWords = false

        var arguments: [String: any Sendable] { ["query": query, "matchCase": matchCase, "wholeWord": wholeWords] }
    }

    var asked = Asked()
    var query: String {
        get { asked.query }
        set { asked.query = newValue }
    }
    var replacement = ""
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Nil without a query and until its first search ends, so the pane doesn't read No Results while it runs.
    private(set) var groups: [SearchGroup]?
    private(set) var searched = Asked()
    private(set) var failure: String?
    /// Find Usages' answer, whose hits show under its heading until the query, its name, changes.
    private(set) var usages: Usages?
    /// The hit shown, which Return in the field steps on from.
    var chosen: SearchHit.ID?

    var hitCount: Int { groups?.reduce(0) { $0 + $1.hits.count } ?? 0 }

    func show(_ found: Usages) {
        (usages, groups, failure, chosen) = (found, found.groups, nil, nil)
        (searched.query, query) = (found.name, found.name)
    }

    /// The session's, which searches the open document as the editor has it. A new search's hits can reuse one's ID:
    /// the first click on it opens it.
    func run(in session: UInt64?) async {
        let asked = asked
        guard asked.query != usages?.name else { return }
        var found: [SearchGroup]?, why: String?
        if isSearching, let session {
            do {
                found = try await core.call("session_search", asked.arguments.merging(["session": session]) { $1 },
                                            as: [SearchGroup].self)
            } catch {
                (found, why) = ([], error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
        }
        (groups, failure, searched, usages, chosen) = (found, why, asked, nil, nil)
    }

    /// The next hit, or with a negative `step` the one before, round from the end, as Return steps through the PDF's.
    func step(_ step: Int) {
        let hits = groups?.flatMap(\.hits).map(\.id) ?? []
        guard !hits.isEmpty else { return NSSound.beep() }
        let at = chosen.flatMap(hits.firstIndex) ?? (step > 0 ? -1 : 0)
        chosen = hits[(at + step + hits.count) % hits.count]
    }
}
