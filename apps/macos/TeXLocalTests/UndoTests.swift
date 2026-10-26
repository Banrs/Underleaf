import Foundation
import Testing
@testable import TeXLocal

@Suite(.timeLimit(.minutes(1)))
struct UndoableTrashTests {
    @Test func undoPutsATrashedItemBackAndWaitsForARedo() async throws {
        let files = FileManager.default
        let url = files.temporaryDirectory.appending(path: "undo-\(UUID().uuidString.prefix(8)).tex")
        try "text".write(to: url, atomically: false, encoding: .utf8)
        let undo = UndoManager()
        undo.groupsByEvent = false
        var listed = 0
        var item: UndoableTrash? = UndoableTrash(original: url, name: url.lastPathComponent, undoManager: undo,
                                 trash: { item in await Task.yield(); return (try? item.recycle()) != nil },
                                 changed: { listed += 1 }, failed: { title, _ in Issue.record("\(title)") })
        undo.beginUndoGrouping()
        await item?.moveToTrash()
        undo.endUndoGrouping()
        item = nil
        #expect(!files.fileExists(atPath: url.path) && undo.undoActionName == "Move to Trash")

        undo.undo()
        try await waitUntil { files.fileExists(atPath: url.path) && listed == 1 }
        #expect(try String(contentsOf: url, encoding: .utf8) == "text" && undo.canRedo)

        undo.redo()
        undo.undo()
        try await waitUntil { listed == 3 }
        #expect(files.fileExists(atPath: url.path) && undo.canRedo && !undo.canUndo)
        try files.removeItem(at: url)
    }
}
