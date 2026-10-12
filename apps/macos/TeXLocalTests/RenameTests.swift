import Foundation
import Testing
@testable import TeXLocal

/// Where a path is after its entry or a folder above it is renamed.
@MainActor
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

/// A file is what its extension says, in any case: what the editor edits, and the symbol beside its name.
@MainActor
struct FileKindTests {
    @Test func theExtensionSaysWhatAFileIs() {
        #expect(isTextFile("main.tex") && isTextFile("refs.BIB") && isTextFile("ch/data.csv"))
        #expect(!isTextFile("plot.png") && !isTextFile("paper.pdf") && !isTextFile("Makefile"))
        #expect(isLaTeXFile("ch/Intro.TeX") && !isLaTeXFile("refs.bib"))
        #expect(fileSymbol("main.tex", directory: false) == "text.document" && fileSymbol("refs.bib", directory: false) == "books.vertical")
        #expect(fileSymbol("plot.PNG", directory: false) == "photo" && fileSymbol("paper.pdf", directory: false) == "richtext.page")
        #expect(fileSymbol("notes.md", directory: false) == "document" && fileSymbol("Makefile", directory: false) == "document")
        #expect(fileSymbol("figures.pdf", directory: true) == "folder")
    }
}

/// Work put off in a slot: the last of its kind runs, once, after its delay.
@MainActor
struct RestartTests {
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

/// The projects screen's and the sidebar's rename in place.
@MainActor
struct InPlaceRenameTests {
    @Test func aRenameEndsOnceWithItsNewName() {
        let rename = InPlaceRename<String>()
        rename.begin("ch/intro.tex", name: "intro.tex")
        rename.name = "  start.tex "
        #expect(rename.end("ch/intro.tex", from: "intro.tex") == "start.tex")
        #expect(rename.id == nil)
        // Return, then the field losing focus as it goes: the second finds
        // the rename over.
        #expect(rename.end("ch/intro.tex", from: "intro.tex") == nil)
    }

    @Test func anEmptyOrUnchangedNameRenamesNothing() {
        let rename = InPlaceRename<String>()
        for name in ["   ", "intro.tex"] {
            rename.begin("intro.tex", name: "intro.tex")
            rename.name = name
            #expect(rename.end("intro.tex", from: "intro.tex") == nil)
            #expect(rename.id == nil)
        }
    }

    @Test func anotherRowLeavesTheRenameOpen() {
        let rename = InPlaceRename<String>()
        rename.begin("a.tex", name: "a.tex")
        rename.name = "b.tex"
        #expect(rename.end("c.tex", from: "c.tex") == nil)
        #expect(rename.id == "a.tex")
    }
}
