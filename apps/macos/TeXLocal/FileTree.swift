import Foundation

final class FileTree {
    private let store: SessionStore
    private var sorted: (of: [TreeNode], nodes: [TreeNode]) = ([], [])

    init(store: SessionStore) { self.store = store }

    var nodes: [TreeNode] {
        if sorted.of != store.tree { sorted = (store.tree, Self.ordered(store.tree)) }
        return sorted.nodes
    }

    func node(at path: String) -> TreeNode? {
        var level = store.tree
        while let next = level.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
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
