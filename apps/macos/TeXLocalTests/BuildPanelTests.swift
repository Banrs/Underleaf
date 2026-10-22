import Foundation
import Testing
@testable import TeXLocal

struct BuildPanelTests {
    @Test func aCleanBuildClosesOnlyThePanelAFailureOpened() {
        let panel = BuildPanelModel()
        panel.openForFailedBuild()
        #expect(panel.shown && panel.tab == .issues)
        panel.tab = .log
        panel.closeAfterCleanBuild()
        #expect(panel.shown)
        panel.tab = .issues
        panel.closeAfterCleanBuild()
        #expect(!panel.shown)
        panel.show(.log)
        panel.openForFailedBuild()
        panel.closeAfterCleanBuild()
        #expect(panel.shown && panel.tab == .issues)
        panel.shown = false
        panel.openForFailedBuild()
        panel.shown = false
        panel.show(.texpresso)
        #expect(panel.showsLiveLog)
        panel.tab = .issues
        panel.closeAfterCleanBuild()
        #expect(panel.shown)
    }

    @Test func badBoxesFollowTheWarningsAndHideWithThem() throws {
        func items(_ type: String, _ message: String) -> String { "[{\"type\": \"\(type)\", \"file\": null, \"line\": null, \"message\": \"\(message)\"}]" }
        let json = """
            {"ok": true, "stopped": false, "pdf": null, "pdfChanged": false, "durationMs": 0, "log": "",
             "errors": \(items("error", "Undefined")), "warnings": \(items("warning", "Citation")), "badBoxes": \(items("warning", "Overfull"))}
            """
        let result = try JSONDecoder().decode(CompileResult.self, from: Data(json.utf8))
        let panel = BuildPanelModel()
        #expect(panel.rows(of: result).map(\.element.message) == ["Undefined", "Citation", "Overfull"])
        panel.showsWarnings = false
        #expect(panel.rows(of: result).map(\.element.message) == ["Undefined"])
    }

    /// The core refuses a name with a leading dash before it looks for tlmgr, so nothing is installed.
    @Test func aRefusedFixIsAnAlertAndEndsItsProgress() async throws {
        let defaults = TestDefaults()
        let app = AppModel(defaults: defaults.store)
        let project = ProjectModel(id: "BuildPanelTests", app: app)
        let json = #"{"title": "Install", "help": "", "command": "install_package", "args": {"file": "-foo.sty"}}"#
        await project.run(try JSONDecoder().decode(LogItem.Fix.self, from: Data(json.utf8)))
        #expect(app.alert?.title == "Couldn’t Install" && project.fixing == nil)
    }

    @Test func aFixInProgressIsItsTitlesVerbGoingOn() throws {
        func progress(_ title: String) throws -> String {
            let json = #"{"title": "\#(title)", "help": "", "command": "", "args": {}}"#
            return try JSONDecoder().decode(LogItem.Fix.self, from: Data(json.utf8)).progress
        }
        #expect(try progress("Install") == "Installing…")
        #expect(try progress("Use XeLaTeX") == "Using XeLaTeX…")
    }
}
