import Foundation
import Observation

@Observable
final class FileTree {
    @ObservationIgnored private let store: SessionStore
    private(set) var nodes: [TreeNode] = []

    init(store: SessionStore) { self.store = store }

    func arrived() { nodes = Self.ordered(store.tree) }

    func node(at path: String) -> TreeNode? {
        var level = store.tree
        while let next = level.first(where: { path.isWithin($0.path) }) {
            if next.path == path { return next }
            level = next.children ?? []
        }
        return nil
    }

    private static func ordered(_ nodes: [TreeNode]) -> [TreeNode] {
        nodes.map { node in
            var node = node
            node.children = node.children.map(ordered)
            return node
        }
        .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
