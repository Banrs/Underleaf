import Foundation
import Observation

enum PanelTab: String, CaseIterable { case issues = "Issues", log = "Build Log", texpresso = "Live Preview Log" }

@Observable
final class BuildPanelModel {
    var shown = false { didSet { if !shown { openedByBuild = false } } }
    @ObservationIgnored private var openedByBuild = false
    var tab: PanelTab = .issues
    var issueFilter = ""
    var logFilter = ""
    var showsWarnings = true

    var showsLiveLog: Bool { shown && tab == .texpresso }

    func show(_ tab: PanelTab) {
        self.tab = tab
        shown = true
    }

    func openForFailedBuild() {
        if !shown { openedByBuild = true }
        show(.issues)
    }

    func closeAfterCleanBuild() { if openedByBuild, tab == .issues { shown = false } }

    func matches(_ item: LogItem) -> Bool {
        issueFilter.isEmpty || item.message.text.localizedCaseInsensitiveContains(issueFilter)
            || (item.file?.localizedCaseInsensitiveContains(issueFilter) ?? false)
    }

    func rows(of listed: [LogItem]) -> [(offset: Int, element: LogItem)] {
        listed.enumerated().filter { (showsWarnings || $0.element.isError) && matches($0.element) }
    }
}
