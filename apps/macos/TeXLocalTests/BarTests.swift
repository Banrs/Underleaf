import SwiftUI
import Testing
@testable import TeXLocal

@MainActor
struct SettingsLayoutTests {
    /// Font Size's stepper sits beside its field, not over the field's end.
    @Test func theStepperSitsBesideItsField() async throws {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(AppModel())))
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.close() }
        func all<T: NSView>(_ view: NSView) -> [T] { [view as? T].compactMap(\.self) + view.subviews.flatMap { all($0) as [T] } }
        let steppers: () -> [NSStepper] = { all(window.contentView!) }
        try await waitUntil { !steppers().isEmpty }
        let fields = (all(window.contentView!) as [NSTextField]).filter(\.isEditable)
        let stepper = try #require(steppers().first), field = try #require(fields.first)
        #expect(stepper.convert(stepper.bounds, to: nil).minX >= field.convert(field.bounds, to: nil).maxX)
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
    private struct Case {
        let id, name, draft, endingID, endingName: String
        let result, activeID: String?
    }

    @Test func renameEndsOnlyForItsRow() {
        let cases = [
            Case(id: "ch/intro.tex", name: "intro.tex", draft: "  start.tex ", endingID: "ch/intro.tex",
                 endingName: "intro.tex", result: "start.tex", activeID: nil),
            Case(id: "intro.tex", name: "intro.tex", draft: "   ", endingID: "intro.tex",
                 endingName: "intro.tex", result: nil, activeID: nil),
            Case(id: "intro.tex", name: "intro.tex", draft: "intro.tex", endingID: "intro.tex",
                 endingName: "intro.tex", result: nil, activeID: nil),
            Case(id: "a.tex", name: "a.tex", draft: "b.tex", endingID: "c.tex",
                 endingName: "c.tex", result: nil, activeID: "a.tex")
        ]
        for test in cases {
            let rename = InPlaceRename<String>()
            rename.begin(test.id, name: test.name)
            rename.name = test.draft
            #expect(rename.end(test.endingID, from: test.endingName) == test.result)
            #expect(rename.id == test.activeID)
            #expect(rename.end(test.endingID, from: test.endingName) == nil)
        }
    }
}
