import Foundation
import Observation

@Observable
final class ProjectSearch {
    private let id: String
    private let core = Core.shared

    var query = ""
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Nil without a query and until the first search for one ends, so its results pane doesn't read No Results while it runs.
    private(set) var hits: [SearchHit]?
    private(set) var searched = ""
    private(set) var failure: String?
    private(set) var groups: [SearchGroup] = []

    init(id: String) {
        self.id = id
    }

    func run() async {
        let query = query
        var found: [SearchHit]?, why: String?
        if isSearching {
            do {
                found = try await core.call("search_project", ["id": id, "query": query], as: [SearchHit].self)
            } catch {
                (found, why) = ([], error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
        }
        (hits, failure, searched) = (found, why, query)
        groups = Dictionary(grouping: found ?? [], by: \.file).map { SearchGroup(file: $0.key, hits: $0.value) }.sorted { $0.file < $1.file }
    }
}
