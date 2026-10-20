import Foundation
import Testing
@testable import TeXLocal

struct ConcurrencyTests {
    /// The latest of a kind carries on; what it replaced is cancelled and does nothing.
    @Test(.timeLimit(.minutes(1)))
    func theLatestOfItsKindCarriesOn() async {
        var slot: Task<Int, Never>?
        let first = restart(&slot) { Task.isCancelled ? 0 : 1 }
        let second = restart(&slot) { Task.isCancelled ? 0 : 2 }
        #expect(first.isCancelled && !second.isCancelled && slot == second)
        #expect(await first.value == 0)
        #expect(await second.value == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func theLastOfItsKindRunsAlone() async {
        var slot: Task<Void, Never>?, ran: [Int] = []
        restart(&slot, after: .milliseconds(50)) { ran.append(1) }
        let first = slot
        restart(&slot, after: .milliseconds(50)) { ran.append(2) }
        #expect(first?.isCancelled == true && ran.isEmpty)
        await first?.value
        await slot?.value
        #expect(ran == [2])
    }

    /// The Redo is there as the Undo starts; work that fails takes every action of its target away.
    @Test func anAsyncUndoRegistersItsRedoAndAFailureClearsTheStack() async throws {
        final class Target {}
        let target = Target(), undo = UndoManager()
        undo.groupsByEvent = false
        var reversed = 0
        await undo.grouping { undo.registerAsyncUndo(withTarget: target, actionName: "Thing", reversal: { reversed += 1 }, work: { false }) }
        #expect(undo.canUndo && undo.undoActionName == "Thing")
        undo.undo()
        #expect(reversed == 1)
        try await waitUntil { !undo.canUndo && !undo.canRedo }
    }
}
