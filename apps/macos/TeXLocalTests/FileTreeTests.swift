import Testing
@testable import TeXLocal

/// In `ProjectFlowTests` for its library and its clean-up.
extension ProjectFlowTests {
    @Test func theTreeTellsOfAChangeOnly() async throws {
        let info = try await project().info, tree = FileTree(id: info.id)
        var changes = 0
        tree.onChange = { changes += 1 }
        await tree.reload()
        #expect(changes == 1 && tree.node(at: info.mainFile)?.isDirectory == false)
        await tree.reload()
        #expect(changes == 1)
        try info.write("x", to: "notes.tex")
        await tree.reload()
        #expect(changes == 2 && tree.node(at: "notes.tex") != nil)
        tree.close()
        try info.write("x", to: "more.tex")
        await tree.reload()
        #expect(changes == 2 && tree.node(at: "more.tex") == nil)
    }
}
