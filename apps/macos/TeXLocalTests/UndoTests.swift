import Foundation
import Testing
@testable import TeXLocal

@Suite(.timeLimit(.minutes(1)))
struct UndoableTrashTests {
    @Test func undoPutsATrashedItemBackAndRedoTrashesItAgain() async throws {
        let files = FileManager.default
        let url = files.temporaryDirectory.appending(path: "undo-\(UUID().uuidString.prefix(8)).tex")
        try "text".write(to: url, atomically: false, encoding: .utf8)
        let undo = UndoManager()
        undo.groupsByEvent = false
        var listed = 0
        // Not kept here: the undo manager's entries keep it, as in the app.
        var item: UndoableTrash? = UndoableTrash(original: url, name: url.lastPathComponent, undoManager: undo,
                                 trash: { item in (try? item.recycle()) != nil },
                                 changed: { listed += 1 }, failed: { title, _ in Issue.record("\(title)") })
        undo.beginUndoGrouping()
        await item?.moveToTrash()
        undo.endUndoGrouping()
        item = nil
        #expect(!files.fileExists(atPath: url.path) && undo.undoActionName == "Move to Trash")

        undo.undo()
        try await waitUntil { files.fileExists(atPath: url.path) && listed == 1 }
        #expect(try String(contentsOf: url, encoding: .utf8) == "text" && undo.canRedo && listed == 1)

        undo.redo()
        try await waitUntil { !files.fileExists(atPath: url.path) && listed == 2 }
        #expect(undo.canUndo)

        undo.undo()
        try await waitUntil { files.fileExists(atPath: url.path) }
        try files.removeItem(at: url)
    }

    /// An Undo asked while a Redo is still on its way to the Trash waits for it, rather than finding nothing to put back (#36).
    @Test func anUndoDuringARedoWaitsForIt() async throws {
        let files = FileManager.default
        let url = files.temporaryDirectory.appending(path: "undo-\(UUID().uuidString.prefix(8)).tex")
        try "text".write(to: url, atomically: false, encoding: .utf8)
        let undo = UndoManager()
        undo.groupsByEvent = false
        var listed = 0
        // Slow, as the project's lane can be behind a save.
        let item = UndoableTrash(original: url, name: url.lastPathComponent, undoManager: undo,
                                 trash: { item in try? await Task.sleep(for: .milliseconds(200)); return (try? item.recycle()) != nil },
                                 changed: { listed += 1 }, failed: { title, _ in Issue.record("\(title)") })
        undo.beginUndoGrouping()
        await item.moveToTrash()
        undo.endUndoGrouping()
        undo.undo()
        try await waitUntil { files.fileExists(atPath: url.path) && listed == 1 }

        undo.redo()
        undo.undo()
        try await waitUntil { listed == 3 }
        #expect(files.fileExists(atPath: url.path) && undo.canRedo && !undo.canUndo)
        try files.removeItem(at: url)
    }
}
