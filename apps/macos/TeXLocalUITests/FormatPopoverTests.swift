import XCTest

final class FormatPopoverTests: XCTestCase {
    @MainActor
    func testFormattingControlsKeepTheirStateAndEditorSelection() throws {
        // UI automation runs on the CI desktop, never the developer's session.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNDERLEAF_UI_TESTS"] == "1")
        continueAfterFailure = false
        let files = FileManager.default
        let library = files.temporaryDirectory.appending(path: "TeXLocal-UI-\(UUID().uuidString)")
        let project = library.appending(path: "Aa")
        try files.createDirectory(at: project, withIntermediateDirectories: true)
        try "\\textit{word}".write(to: project.appending(path: "main.tex"), atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchEnvironment["TEXLOCAL_DATA"] = library.path
        app.launchArguments = ["-openProject", "Aa", "-autoCompile", "NO", "-sidebarVisible", "NO",
                               "-inspectorVisible", "NO", "-showPDF", "NO", "-ApplePersistenceIgnoreState", "YES"]
        defer {
            app.terminate()
            try? files.removeItem(at: library)
        }
        app.launch()
        let source = app.textViews["Source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertEqual(source.value as? String, "\\textit{word}")
        source.click()
        source.typeKey(.rightArrow, modifierFlags: .command)
        source.typeKey(.leftArrow, modifierFlags: [])
        for _ in 0..<4 { source.typeKey(.leftArrow, modifierFlags: .shift) }

        app.toolbars.buttons["Format"].click()
        let bold = app.checkBoxes["Bold"], italic = app.checkBoxes["Italic"], underline = app.checkBoxes["Underline"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        func check(_ text: String, _ states: [String]) {
            XCTAssertEqual(source.value as? String, text)
            for (control, state) in zip([bold, italic, underline], states) {
                XCTAssertTrue(control.exists, "The formatting popover must remain open")
                XCTAssertEqual(String(describing: control.value ?? ""), state)
            }
        }
        check("\\textit{word}", ["0", "1", "0"])
        bold.click()
        check("\\textit{\\textbf{word}}", ["1", "1", "0"])
        bold.click()
        check("\\textit{word}", ["0", "1", "0"])
        italic.click()
        check("word", ["0", "0", "0"])
        underline.click()
        check("\\underline{word}", ["0", "0", "1"])
        underline.click()
        check("word", ["0", "0", "0"])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bold.waitForNonExistence(timeout: 5))
    }
}
