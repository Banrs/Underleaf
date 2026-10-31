import Foundation

private var undoLane: Task<Void, Never>?

extension UndoManager {
    func registerAsyncUndo<Target: AnyObject>(withTarget target: Target, actionName: String,
                                              reversal: @escaping @MainActor () -> Void,
                                              work: @escaping @MainActor () async -> Bool) {
        registerUndo(withTarget: target) { [weak self] _ in
            reversal()
            _ = enqueue(&undoLane) { if await !work() { self?.removeAllActions(withTarget: target) } }
        }
        setActionName(actionName)
    }
}

final class UndoableTrash {
    private var trashed: String?
    private weak var undoManager: UndoManager?
    private let trash: () async -> String?
    private let putBack: (String) async -> Bool

    init(undoManager: UndoManager?, trash: @escaping () async -> String?, putBack: @escaping (String) async -> Bool) {
        (self.undoManager, self.trash, self.putBack) = (undoManager, trash, putBack)
    }

    func moveToTrash() async { if await recycle() { registerPutBack() } }

    private func recycle() async -> Bool {
        trashed = await trash()
        return trashed != nil
    }

    private func restore() async -> Bool {
        guard let trashed, await putBack(trashed) else { return false }
        self.trashed = nil
        return true
    }

    private func registerPutBack() { register(reversal: registerTrashAgain, step: restore) }
    private func registerTrashAgain() { register(reversal: registerPutBack, step: recycle) }

    private func register(reversal: @escaping @MainActor () -> Void, step: @escaping @MainActor () async -> Bool) {
        undoManager?.registerAsyncUndo(withTarget: self, actionName: String(localized: "Move to Trash"), reversal: reversal, work: step)
    }
}
