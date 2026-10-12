import Foundation
import Observation

/// Find in Project: the query in the sidebar's field, and what the latest search for it found.
@Observable
final class ProjectSearch {
    private let id: String
    private let core = Core.shared

    var query = ""
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The latest finished search's hits: nil until the first for a query ends,
    /// so its results pane doesn't read No Results while it runs.
    private(set) var hits: [SearchHit]?
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
        var found: [SearchHit]?, why: String?
        if isSearching {
            do {
                found = try await core.call("search_project", ["id": id, "query": query], as: [SearchHit].self)
            } catch {
                (found, why) = ([], error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
        }
        (hits, failure) = (found, why)
        groups = Dictionary(grouping: found ?? [], by: \.file).map { SearchGroup(file: $0.key, hits: $0.value) }.sorted { $0.file < $1.file }
    }
}
