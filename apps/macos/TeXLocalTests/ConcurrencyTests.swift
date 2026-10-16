import Foundation
import Testing
@testable import TeXLocal

struct ConcurrencyTests {
    /// The latest of a kind carries on; what it replaced is cancelled and does nothing.
    @Test func restartCancelsWhatRanBefore() async {
        var slot: Task<Int, Never>?
        let first = restart(&slot) {
            try? await Task.sleep(for: .seconds(5))
            return Task.isCancelled ? 1 : 0
        }
        let second = restart(&slot) { 2 }
        let (cancelled, kept) = await (first.value, second.value)
        #expect(cancelled == 1 && kept == 2)
    }

    /// One asked while the last still works waits for it, and the last is not cancelled.
    @Test func enqueueRunsInTheOrderAsked() async {
        var slot: Task<Void, Never>?
        var order: [Int] = []
        let slow = enqueue(&slot) {
            try? await Task.sleep(for: .milliseconds(100))
            order.append(1)
        }
        let quick = enqueue(&slot) { order.append(2) }
        await quick.value
        #expect(order == [1, 2] && !slow.isCancelled)
    }

    /// The Redo is there as the Undo starts; work that fails takes every action of its target away.
    @Test func anAsyncUndoRegistersItsRedoAndAFailureClearsTheStack() async throws {
        final class Target {}
        let target = Target()
        let undo = UndoManager()
        undo.groupsByEvent = false
        var reversed = 0
        undo.beginUndoGrouping()
        undo.registerAsyncUndo(withTarget: target, actionName: "Thing", reversal: { reversed += 1 }, work: { false })
        undo.endUndoGrouping()
        #expect(undo.canUndo && undo.undoActionName == "Thing")
        undo.undo()
        #expect(reversed == 1)
        try await waitUntil { !undo.canUndo && !undo.canRedo }
    }
}
