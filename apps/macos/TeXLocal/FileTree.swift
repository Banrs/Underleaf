import Foundation
import Observation

@Observable
final class FileTree {
    private(set) var nodes: [TreeNode] = []
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var closed = false

    func node(at path: String) -> TreeNode? {
        var level = nodes
        while let next = level.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            if next.path == path { return next }
            level = next.children ?? []
        }
        return nil
    }

    func show(_ files: [TreeNode]) {
        let files = Self.ordered(files)
        guard files != nodes, !closed else { return }
        nodes = files
        onChange()
    }

    private static func ordered(_ nodes: [TreeNode]) -> [TreeNode] {
        nodes.map { node in
            var node = node
            node.children = node.children.map(ordered)
            return node
        }
        .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func close() { closed = true }
}
