import Foundation
import Observation

/// Find in Project: the query in the sidebar's field, and what the latest search for it found.
@Observable
final class ProjectSearch {
    private let id: String
    private let core = Core.shared

    var query = ""
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The latest finished search's hits: nil without a query and until the first search for
    /// one ends, so its results pane doesn't read No Results while it runs. A later query's
    /// search leaves them until it ends.
    private(set) var hits: [SearchHit]?
    /// The query `hits` are for, which the one being typed may have moved on from.
    private(set) var searched = ""
    /// Why the latest search found nothing, when it couldn't be run.
    private(set) var failure: String?
    /// `hits` by file, in the order of the files' names.
    private(set) var groups: [SearchGroup] = []

    init(id: String) {
        self.id = id
    }

    /// Hits for the current query, unless the calling task is cancelled by a newer one; without a
    /// query, none yet.
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
