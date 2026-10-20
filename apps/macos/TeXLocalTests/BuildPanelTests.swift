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
}
