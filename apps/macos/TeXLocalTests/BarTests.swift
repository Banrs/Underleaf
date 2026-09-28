import SwiftUI
import Testing
import XCTest
@testable import TeXLocal

/// The accessory bars measured off screen, with no window shown.
@MainActor
struct PaneBarLayoutTests {
    private func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.paneBarControls()).fittingSize.height
    }

    @Test func aBarIsARegularControlAndItsInsets() {
        #expect(height(PaneBar { Button("Done") {} }) == regularControlHeight() + 2 * BarMetrics.inset)
    }

    /// A control group draws a little taller than a button, but still inside the bar.
    @Test func everyControlFitsTheBar() {
        let bar = height(PaneBar { Button("Done") {} })
        let steps = ControlGroup {
            Button("Previous Match", systemImage: "chevron.up") {}
            Button("Next Match", systemImage: "chevron.down") {}
        }.fixedSize()
        let copy = Button("Copy Log", systemImage: "document.on.document") {}
            .buttonStyle(.accessoryBar).labelStyle(.iconOnly)
        for control in [height(steps), height(copy), height(Button("Done") {})] {
            #expect(control <= bar - 2 * BarMetrics.spacing)
        }
    }
}

@MainActor
struct FindBarTests {
    /// One row is a pane bar's height; the replace row adds at least a control's.
    @Test func aFindBarIsABarsHeight() {
        let find = FindBar(query: .constant("the"), prompt: "Find in PDF", field: FieldHandle(), matches: FindMatches(),
                           searched: "the", step: { _ in }, close: {})
        let replace = FindBar(query: .constant("the"), prompt: "Find", field: FieldHandle(), matches: FindMatches(),
                              searched: "the", step: { _ in }, close: {}) {
            GridRow {
                TextField("Replace", text: .constant("")).textFieldStyle(.bordered)
                Button("Replace") {}
            }
        }
        let control = regularControlHeight()
        let one = NSHostingView(rootView: find.frame(width: 400)).fittingSize.height
        let two = NSHostingView(rootView: replace.frame(width: 400)).fittingSize.height
        #expect(one == control + 2 * BarMetrics.inset)
        #expect(two >= one + control)
    }
}

@MainActor
final class RenameTests: XCTestCase {
    func testTheOpenFileMovesWithItsFolder() {
        XCTAssertEqual(remapPath("ch/intro.tex", from: "ch/intro.tex", to: "ch/start.tex"), "ch/start.tex")
        XCTAssertEqual(remapPath("ch/intro.tex", from: "ch", to: "chapters"), "chapters/intro.tex")
        XCTAssertEqual(remapPath("ch/a/b.tex", from: "ch/a", to: "x"), "x/b.tex")
        // A sibling that shares the prefix is not inside the folder.
        XCTAssertEqual(remapPath("chapter.tex", from: "ch", to: "chapters"), "chapter.tex")
        XCTAssertEqual(remapPath("main.tex", from: "ch", to: "chapters"), "main.tex")
    }
}

/// The gallery's and the sidebar's rename in place.
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
