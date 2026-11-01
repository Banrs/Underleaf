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

    var showsLiveLog: Bool { shown && tab == .texpresso }

    func show(_ tab: PanelTab) {
        self.tab = tab
        shown = true
    }
}

enum Navigator: String, CaseIterable { case files, outline, search, issues }

@Observable
final class NavigatorModel {
    var shown: Navigator {
        didSet {
            beforeFailedBuild = nil
            var kept = defaults.dictionary(forKey: DefaultsKey.navigators) ?? [:]
            kept[project] = shown.rawValue
            defaults.set(kept, forKey: DefaultsKey.navigators)
        }
    }
    var fileFilter = ""
    var outlineFilter = ""
    var searchFilter = ""
    var issueFilter = ""
    var showsWarnings = true
    @ObservationIgnored private var beforeFailedBuild: Navigator?
    @ObservationIgnored private let project: String
    @ObservationIgnored private let defaults: UserDefaults

    init(project: String, defaults: UserDefaults) {
        (self.project, self.defaults) = (project, defaults)
        shown = (defaults.dictionary(forKey: DefaultsKey.navigators)?[project] as? String).flatMap(Navigator.init) ?? .files
    }

    func showForFailedBuild() {
        guard shown != .issues else { return }
        let was = shown
        shown = .issues
        beforeFailedBuild = was
    }

    func returnAfterCleanBuild() { if let was = beforeFailedBuild { shown = was } }

    func matches(_ item: LogItem) -> Bool {
        issueFilter.isEmpty || item.message.text.localizedCaseInsensitiveContains(issueFilter)
            || (item.file?.localizedCaseInsensitiveContains(issueFilter) ?? false)
    }

    /// Find's results narrowed to the files, or the matched lines, containing the filter.
    func filtered(_ groups: [SearchGroup]) -> [SearchGroup] {
        guard !searchFilter.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.file.localizedCaseInsensitiveContains(searchFilter) { return group }
            let hits = group.hits.filter { "\($0.before)\($0.match)\($0.after)".localizedCaseInsensitiveContains(searchFilter) }
            return hits.isEmpty ? nil : SearchGroup(file: group.file, hits: hits)
        }
    }

    func rows(of listed: [LogItem]) -> [(offset: Int, element: LogItem)] {
        listed.enumerated().filter { (showsWarnings || $0.element.isError) && matches($0.element) }
    }
}
