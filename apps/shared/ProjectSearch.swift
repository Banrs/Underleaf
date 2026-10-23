import Foundation
import Observation

@Observable
final class ProjectSearch {
    private let core = Core.shared

    var query = ""
    var replacement = ""
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Nil without a query and until its first search ends, so the pane doesn't read No Results while it runs.
    private(set) var groups: [SearchGroup]?
    private(set) var searched = ""
    private(set) var failure: String?
    /// Find Usages' answer, whose hits show under its heading until the query, its name, changes.
    private(set) var usages: Usages?

    var hitCount: Int { groups?.reduce(0) { $0 + $1.hits.count } ?? 0 }

    func show(_ found: Usages) {
        (usages, groups, failure, searched, query) = (found, found.groups, nil, found.name, found.name)
    }

    /// The session's, which searches the open document as the editor has it.
    func run(in session: UInt64?) async {
        let query = query
        guard query != usages?.name else { return }
        var found: [SearchGroup]?, why: String?
        if isSearching, let session {
            do {
                found = try await core.call("session_search", ["session": session, "query": query], as: [SearchGroup].self)
            } catch {
                (found, why) = ([], error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
        }
        (groups, failure, searched, usages) = (found, why, query, nil)
    }
}
