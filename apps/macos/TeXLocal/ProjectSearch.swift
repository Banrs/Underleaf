import Foundation
import Observation

@Observable
final class ProjectSearch {
    private let id: String
    private let core = Core.shared

    var query = ""
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The hits by file. Nil without a query and until the first search for one ends, so its results pane doesn't read No
    /// Results while it runs.
    private(set) var groups: [SearchGroup]?
    private(set) var searched = ""
    private(set) var failure: String?

    var hitCount: Int { groups?.reduce(0) { $0 + $1.hits.count } ?? 0 }

    init(id: String) { self.id = id }

    func run() async {
        let query = query
        var found: [SearchGroup]?, why: String?
        if isSearching {
            do {
                found = try await core.call("search_project", ["id": id, "query": query], as: [SearchGroup].self)
            } catch {
                (found, why) = ([], error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
        }
        (groups, failure, searched) = (found, why, query)
    }
}
