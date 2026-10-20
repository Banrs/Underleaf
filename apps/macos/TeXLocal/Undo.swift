import Foundation

extension UndoManager {
    /// An Undo or Redo that does asynchronous work: `reversal` registers its opposite as the work starts, as an undo manager
    /// expects, and work that fails takes away every action of `target`.
    func registerAsyncUndo<Target: AnyObject>(withTarget target: Target, actionName: String,
                                              reversal: @escaping @MainActor () -> Void,
                                              work: @escaping @MainActor () async -> Bool) {
        registerUndo(withTarget: target) { [weak self] _ in
            reversal()
            Task { if await !work() { self?.removeAllActions(withTarget: target) } }
        }
        setActionName(actionName)
    }
}

/// Through `FileManager`, which says where the Trash put the item. Undo puts it back and Redo trashes it again.
final class UndoableTrash {
    let original: URL
    let name: String
    private var trashed: URL?
    private weak var undoManager: UndoManager?
    private let trash: (UndoableTrash) async -> Bool
    private let changed: () async -> Void
    private let failed: (String, any Error) -> Void
    /// A step waits for the last, so an Undo can't find the item not yet in the Trash (#36).
    private var last: Task<Bool, Never>?

    init(original: URL, name: String, undoManager: UndoManager?,
         trash: @escaping (UndoableTrash) async -> Bool,
         changed: @escaping () async -> Void,
         failed: @escaping (String, any Error) -> Void) {
        (self.original, self.name, self.undoManager) = (original, name, undoManager)
        (self.trash, self.changed, self.failed) = (trash, changed, failed)
    }

    func recycle() throws {
        guard FileManager.default.fileExists(atPath: original.path(percentEncoded: false)) else { return }
        var result: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &result)
        trashed = result as URL?
    }

    func moveToTrash() async { if await trash(self) { registerPutBack() } }

    private func registerPutBack() { register(reversal: registerTrashAgain, step: putBack) }
    private func registerTrashAgain() { register(reversal: registerPutBack) { [self] in await trash(self) } }

    private func register(reversal: @escaping @MainActor () -> Void, step: @escaping @MainActor () async -> Bool) {
        undoManager?.registerAsyncUndo(withTarget: self, actionName: String(localized: "Move to Trash"), reversal: reversal) { [self] in
            let done = await enqueue(&last, step).value
            if done { await changed() }
            return done
        }
    }

    private func putBack() async -> Bool {
        guard let trashed else { return false }
        do {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: trashed, to: original)
        } catch {
            failed("Couldn’t Put “\(name)” Back", error)
            return false
        }
        self.trashed = nil
        return true
    }
}
