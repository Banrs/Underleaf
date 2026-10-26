import Foundation
import Observation

@Observable
final class FileTree {
    private let id: String
    private let core = Core.shared

    private(set) var nodes: [TreeNode] = []
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var taken = 0
    @ObservationIgnored private var closed = false

    init(id: String) { self.id = id }

    func node(at path: String) -> TreeNode? {
        var level = nodes
        while let next = level.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            if next.path == path { return next }
            level = next.children ?? []
        }
        return nil
    }

    func reload() async {
        reads += 1
        let read = reads
        guard let files = try? await core.call("file_tree", ["id": id], as: [TreeNode].self), read > taken else { return }
        taken = read
        if !Task.isCancelled { take(files) }
    }

    func show(_ files: [TreeNode]) {
        taken = reads
        take(files)
    }

    private func take(_ files: [TreeNode]) {
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
