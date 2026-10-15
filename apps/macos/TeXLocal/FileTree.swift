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

    init(id: String) {
        self.id = id
    }

    /// Down the folders on its way only: the open file's kind is asked for as views draw.
    func node(at path: String) -> TreeNode? {
        var level = nodes
        while let next = level.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            if next.path == path { return next }
            level = next.children ?? []
        }
        return nil
    }

    /// A read that started before the last one taken is dropped: a folder change's read ending after a new file's would take away the row its name is being typed in.
    func read() async throws {
        reads += 1
        let read = reads
        let files = try await core.call("file_tree", ["id": id], as: [TreeNode].self)
        guard read > taken else { return }
        taken = read
        // A change in a folder can leave its files as they were.
        if files != nodes, !closed, !Task.isCancelled {
            nodes = files
            onChange()
        }
    }

    /// A failed read keeps the tree as it was, and the folder's next change reads again.
    func reload() async {
        try? await read()
    }

    /// The tree as the session's watcher read it: a read started before is older.
    func show(_ files: [TreeNode]) {
        taken = reads
        if files != nodes, !closed {
            nodes = files
            onChange()
        }
    }

    func close() {
        closed = true
    }
}
