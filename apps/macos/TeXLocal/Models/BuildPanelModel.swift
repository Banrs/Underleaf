import Foundation
import Observation

enum PanelTab: CaseIterable {
    case log, texpresso

    var title: String { self == .log ? String(localized: "Build Log") : String(localized: "Live Preview Log") }
}

@Observable
final class BuildPanelModel {
    var shown = false
    var tab: PanelTab = .log
    var logFilter = ""
    var hiddenLogKinds: Set<LogKind> = []

    var showsLiveLog: Bool { shown && tab == .texpresso }

    func show(_ tab: PanelTab) {
        self.tab = tab
        shown = true
    }
}
