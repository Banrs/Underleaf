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

enum Navigator: String, CaseIterable { case files, outline, search, issues }

@Observable
final class NavigatorModel {
    var shown: Navigator {
        didSet {
            if shown != oldValue { beforeFailedBuild = nil }
            var kept = defaults.dictionary(forKey: DefaultsKey.navigators) ?? [:]
            kept[project] = shown.rawValue
            defaults.set(kept, forKey: DefaultsKey.navigators)
        }
    }
    var fileSelection: String?
    var fileFilter = ""
    var outlineFilter = ""
    var searchFilter = ""
    var issueFilter = ""
    var showsOnlyRecentFiles = false
    var showsOnlyRecentIssues = false
    var hiddenIssueKinds: Set<IssueKind> = []
    /// The Only errors toggle, on while the filter's menu hides every kind but errors.
    var showsOnlyErrors: Bool {
        get { hiddenIssueKinds.isSuperset(of: IssueKind.warnings) }
        set { if newValue { hiddenIssueKinds.formUnion(IssueKind.warnings) } else { hiddenIssueKinds.subtract(IssueKind.warnings) } }
    }
    /// Files opened in this window, latest first, for the Recent files toggle.
    private(set) var recentFiles: [String] = []

    func opened(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 10 { recentFiles.removeLast() }
    }

    func renamed(_ remap: (String) -> String) { recentFiles = recentFiles.map(remap) }
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

    func filtered(_ groups: [SearchGroup]) -> [SearchGroup] {
        guard !searchFilter.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.file.localizedCaseInsensitiveContains(searchFilter) { return group }
            let hits = group.hits.filter { "\($0.before)\($0.match)\($0.after)".localizedCaseInsensitiveContains(searchFilter) }
            return hits.isEmpty ? nil : SearchGroup(file: group.file, hits: hits)
        }
    }

    func rows(of listed: [LogItem]) -> [(offset: Int, element: LogItem)] {
        listed.enumerated().filter { shows($0.element) && matches($0.element) }
    }

    /// Whether the toggles and the filter's menu leave an issue in the list.
    func shows(_ item: LogItem) -> Bool {
        !hiddenIssueKinds.contains(item.issueKind) && (!showsOnlyRecentIssues || item.file.map(recentFiles.contains) == true)
    }
}
