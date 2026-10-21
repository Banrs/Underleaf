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

    /// Whether it shows the Live Preview Log, which the session sends only then.
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
        issueFilter.isEmpty || item.message.localizedCaseInsensitiveContains(issueFilter)
            || (item.file?.localizedCaseInsensitiveContains(issueFilter) ?? false)
    }

    /// Enumerated before filtering: duplicate messages keep distinct, stable row IDs.
    func rows(of result: CompileResult?) -> [(offset: Int, element: LogItem)] {
        (result?.listed ?? []).enumerated().filter { (showsWarnings || $0.element.isError) && matches($0.element) }
    }
}
