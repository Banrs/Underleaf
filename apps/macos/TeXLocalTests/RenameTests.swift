import Foundation
import Testing
@testable import TeXLocal

struct RemapPathTests {
    @Test func theOpenFileMovesWithItsFolder() {
        #expect(remapPath("ch/intro.tex", from: "ch/intro.tex", to: "ch/start.tex") == "ch/start.tex")
        #expect(remapPath("ch/intro.tex", from: "ch", to: "chapters") == "chapters/intro.tex")
        #expect(remapPath("ch/a/b.tex", from: "ch/a", to: "x") == "x/b.tex")
        // A sibling that shares the prefix is not inside the folder.
        #expect(remapPath("chapter.tex", from: "ch", to: "chapters") == "chapter.tex")
        #expect(remapPath("main.tex", from: "ch", to: "chapters") == "main.tex")
    }
}

struct TaskSlotTests {
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
}

struct InPlaceRenameTests {
    @Test func aRenameEndsOnceWithItsNewName() {
        let rename = InPlaceRename<String>()
        rename.begin("ch/intro.tex", name: "intro.tex")
        rename.name = "  start.tex "
        #expect(rename.end("ch/intro.tex", from: "intro.tex") == "start.tex")
        #expect(rename.id == nil)
        // Return, then the field losing focus as it goes: the second finds the rename over.
        #expect(rename.end("ch/intro.tex", from: "intro.tex") == nil)
    }

    @Test(arguments: ["   ", "intro.tex"])
    func anEmptyOrUnchangedNameRenamesNothing(name: String) {
        let rename = InPlaceRename<String>()
        rename.begin("intro.tex", name: "intro.tex")
        rename.name = name
        #expect(rename.end("intro.tex", from: "intro.tex") == nil)
        #expect(rename.id == nil)
    }

    @Test func anotherRowLeavesTheRenameOpen() {
        let rename = InPlaceRename<String>()
        rename.begin("a.tex", name: "a.tex")
        rename.name = "b.tex"
        #expect(rename.end("c.tex", from: "c.tex") == nil)
        #expect(rename.id == "a.tex")
    }
}
