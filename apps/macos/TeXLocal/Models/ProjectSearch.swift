import Foundation
import Observation

@Observable
final class ProjectSearch {
    nonisolated struct Asked: Hashable {
        var query = "", matchCase = false, wholeWords = false
    }

    var asked = Asked() { didSet { if asked != oldValue { generation += 1 } } }
    var query: String {
        get { asked.query }
        set { asked.query = newValue }
    }
    var replacement = ""
    var replacing = false
    var showsReplace: Bool { replacing && usages == nil }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private(set) var groups: [SearchGroup]?
    private(set) var searched = Asked()
    private(set) var failure: String?
    private(set) var usages: Usages?
    var chosen: SearchHit.ID?
    @ObservationIgnored private var generation = 0

    var hitCount: Int { groups?.reduce(0) { $0 + $1.hits.count } ?? 0 }

    func show(_ found: Usages) {
        generation += 1
        (usages, groups, failure, chosen) = (found, found.groups, nil, nil)
        (searched.query, query) = (found.name, found.name)
    }

    @discardableResult
    func run(_ search: (Search) async throws -> [SearchGroup]) async -> Bool {
        let asked = asked
        guard !Task.isCancelled, asked.query != usages?.name else { return false }
        generation += 1
        let started = generation
        var found: [SearchGroup]?, why: String?
        if isSearching {
            do {
                found = try await search(Search(query: asked.query, matchCase: asked.matchCase, wholeWord: asked.wholeWords))
            } catch {
                (found, why) = ([], error.localizedDescription)
            }
        }
        guard generation == started, !Task.isCancelled else { return false }
        (groups, failure, searched, usages, chosen) = (found, why, asked, nil, nil)
        return true
    }

    func choose(after hit: SearchHit, replacingWith text: String, in shown: [SearchGroup]) {
        let lines = text.components(separatedBy: "\n")
        let line = hit.line + lines.count - 1
        let column = (lines.count == 1 ? hit.column : 0) + (lines.last?.utf16.count ?? 0)
        let hits = shown.flatMap(\.hits)
        chosen = (hits.first { ($0.file, $0.line, $0.column) >= (hit.file, line, column) } ?? hits.last)?.id
    }

    func step(_ step: Int, in shown: [SearchGroup]) -> Bool {
        let hits = shown.flatMap(\.hits).map(\.id)
        guard !hits.isEmpty else { return false }
        let at = chosen.flatMap(hits.firstIndex) ?? (step > 0 ? -1 : 0)
        chosen = hits[(at + step + hits.count) % hits.count]
        return true
    }
}
