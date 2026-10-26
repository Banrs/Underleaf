import AppKit
import Observation

@Observable
final class ProjectSearch {
    private let core = Core.shared

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
    private(set) var groups: [SearchGroup]?
    private(set) var searched = Asked()
    private(set) var failure: String?
    private(set) var usages: Usages?
    var chosen: SearchHit.ID?

    var hitCount: Int { groups?.reduce(0) { $0 + $1.hits.count } ?? 0 }

    func show(_ found: Usages) {
        (usages, groups, failure, chosen) = (found, found.groups, nil, nil)
        (searched.query, query) = (found.name, found.name)
    }

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

    func step(_ step: Int) {
        let hits = groups?.flatMap(\.hits).map(\.id) ?? []
        guard !hits.isEmpty else { return NSSound.beep() }
        let at = chosen.flatMap(hits.firstIndex) ?? (step > 0 ? -1 : 0)
        chosen = hits[(at + step + hits.count) % hits.count]
    }
}
