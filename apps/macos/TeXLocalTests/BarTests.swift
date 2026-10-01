import SwiftUI
import Testing
@testable import TeXLocal

@MainActor
struct FindBarTests {
    /// One row is a pane bar's height; the replace row adds at least a control's.
    @Test func aFindBarIsABarsHeight() {
        let find = FindBar(query: .constant("the"), prompt: "Find in PDF", field: FieldHandle(), matches: FindMatches(),
                           searched: "the", step: { _ in }, close: {}) {}
        let replace = FindBar(query: .constant("the"), prompt: "Find", field: FieldHandle(), matches: FindMatches(),
                              searched: "the", step: { _ in }, close: {}) {
            GridRow {
                TextField("Replace", text: .constant("")).textFieldStyle(.bordered)
                Button("Replace") {}
            }
        }
        let control = NSHostingView(rootView: Button("Done") {}.controlSize(.regular)).fittingSize.height
        let one = NSHostingView(rootView: find.frame(width: 400)).fittingSize.height
        let two = NSHostingView(rootView: replace.frame(width: 400)).fittingSize.height
        #expect(one == control + 2 * BarMetrics.inset)
        #expect(two >= one + control)
    }
}

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
