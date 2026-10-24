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

    /// Down the folders on its way only: views ask as they draw.
    func node(at path: String) -> TreeNode? {
        var level = nodes
        while let next = level.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            if next.path == path { return next }
            level = next.children ?? []
        }
        return nil
    }

    /// A read older than the last taken is dropped: it would take away a new file's row as its name is typed.
    func reload() async {
        reads += 1
        let read = reads
        guard let files = try? await core.call("file_tree", ["id": id], as: [TreeNode].self), read > taken else { return }
        taken = read
        if !Task.isCancelled { take(files) }
    }

    /// The session watcher's: a read started before is older.
    func show(_ files: [TreeNode]) {
        taken = reads
        take(files)
    }

    private func take(_ files: [TreeNode]) {
        guard files != nodes, !closed else { return }
        nodes = files
        onChange()
    }

    func close() { closed = true }
}
