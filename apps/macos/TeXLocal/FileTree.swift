import Foundation
import Observation

/// A project's files as the core lists them: read as the project opens, and again as its
/// folder or the project's own file operations change them.
@Observable
final class FileTree {
    private let id: String
    private let core = Core.shared

    private(set) var nodes: [TreeNode] = []
    /// The tree has changed, to these: for what else follows the project's files.
    @ObservationIgnored var onChange: ([TreeNode]) -> Void = { _ in }
    @ObservationIgnored private var reloading: Task<Void, Never>?
    /// The tree's reads, numbered as they start: the latest started, and the latest taken.
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var taken = 0
    /// A read still under way when the project closes changes nothing.
    @ObservationIgnored private var closed = false

    init(id: String) {
        self.id = id
    }

    /// The tree's entry at a project path.
    func node(at path: String) -> TreeNode? { nodes.flattened.first { $0.path == path } }

    /// A read that started before the last one taken is dropped: a folder change's read ending
    /// after a new file's would take away the row its name is being typed in.
    func read() async throws {
        reads += 1
        let read = reads
        let files = try await core.call("file_tree", ["id": id], as: [TreeNode].self)
        guard read > taken else { return }
        taken = read
        // A save's temporary file can trigger an unchanged tree reload.
        if files != nodes, !closed, !Task.isCancelled {
            nodes = files
            onChange(files)
        }
    }

    /// A failed read keeps the tree as it was, and the folder's next change reads again.
    func reload() async {
        try? await read()
    }

    /// The reload for a change in the folder: a newer one replaces one that hasn't started.
    func reloadSoon() {
        reloading?.cancel()
        reloading = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func close() {
        closed = true
        reloading?.cancel()
    }
}
