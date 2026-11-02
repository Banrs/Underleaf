import AppKit
import SwiftUI

/// Find's header, laid out as Xcode's Find navigator lays out its own (IDEFindNavigatorQueryParametersController, read from its
/// nib and code and measured in Xcode): a row 2 pt under the chooser with Xcode's breadcrumb and a borderless Aa toggle,
/// regular and gray off, bold and accent on; the query field under it and, in Replace, the replacement field, each keeping
/// its recents in its symbol's menu, with Replace and Replace All push buttons at its end; then the count of results,
/// centred in a 22 pt band. Fields and buttons are regular, 24 pt, with small button titles, as Xcode's are, and none is glass:
/// Xcode's sit in a scroll edge's bar, and only the filter bar floats over the list.
final class FindHeader: NSView, NSSearchFieldDelegate {
    private lazy var crumb = Breadcrumb { [weak self] item, choice in self?.choose(item, choice) }
    private let usages = NSTextField(labelWithString: "")
    private let matchCase = NSButton(title: "Aa", target: nil, action: nil)
    private let query = NavigatorField()
    private let replacement = NavigatorField()
    private let replace = NSButton(title: String(localized: "Replace"), target: nil, action: nil)
    private let replaceAll = NSButton(title: String(localized: "Replace All"), target: nil, action: nil)
    private let count = NSTextField(labelWithString: "")
    private let project: ProjectModel
    private var shown: Shown?
    private var watch: Task<Void, Never>?

    isolated deinit { watch?.cancel() }

    init(project: ProjectModel, field: FieldHandle) {
        self.project = project
        super.init(frame: .zero)
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        crumb.setAccessibilityLabel(String(localized: "Search Options"))

        usages.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        usages.lineBreakMode = .byTruncatingMiddle
        usages.setAccessibilityRole(.staticText)

        matchCase.setButtonType(.pushOnPushOff)
        matchCase.isBordered = false
        matchCase.toolTip = String(localized: "Match Case")
        matchCase.setAccessibilityLabel(String(localized: "Match Case"))
        (matchCase.target, matchCase.action) = (self, #selector(toggleCase))

        for field in [query, replacement] {
            field.controlSize = .regular
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.sendsSearchStringImmediately = true
            field.delegate = self
            (field.target, field.action) = (self, #selector(edited(_:)))
        }
        query.placeholderString = String(localized: "Search Project")
        query.setAccessibilityLabel(query.placeholderString)
        replacement.placeholderString = String(localized: "With")
        replacement.setAccessibilityLabel(String(localized: "Replace With"))
        query.keepRecents(as: "Find Queries")
        replacement.keepRecents(as: "Replacements")

        // Neither is the default button, since Replace All can't be undone file by file.
        for (button, action) in [(replace, #selector(replaceChosen)), (replaceAll, #selector(replaceEvery))] {
            button.bezelStyle = .push
            button.font = small
            (button.target, button.action) = (self, action)
        }
        replace.toolTip = String(localized: "Replace the selected search result")

        count.font = small
        count.textColor = .secondaryLabelColor
        count.alignment = .center
        for view in [crumb, usages, matchCase, query, replacement, replace, replaceAll, count] { addSubview(view) }
        field.field = query
        watch = track({ Shown(project) }) { [weak self] in self?.show($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private nonisolated struct Shown: Equatable, Sendable {
        let query: String, replacement: String, replacing: Bool, usages: String?, matchCase: Bool, wholeWords: Bool
        let hits: Int, files: Int, total: Int, chosen: Bool, filtered: Bool, visible: Bool

        @MainActor init(_ project: ProjectModel) {
            let search = project.search, groups = project.navigator.filtered(search.groups ?? [])
            (query, replacement, usages) = (search.query, search.replacement, search.usages?.name)
            (replacing, matchCase, wholeWords) = (search.replacing && usages == nil, search.asked.matchCase, search.asked.wholeWords)
            (hits, files, total) = (groups.reduce(0) { $0 + $1.hits.count }, groups.count, search.hitCount)
            (chosen, filtered, visible) = (search.chosen != nil, !project.navigator.searchFilter.isEmpty, project.navigator.shown == .search)
        }
    }

    /// Shows the model now, rather than when the watch next runs, so SwiftUI measures the rows it shows.
    func refresh() { show(Shown(project)) }

    private func show(_ shown: Shown) {
        guard shown != self.shown else { return }
        let resized = shown.replacing != self.shown?.replacing || (shown.hits > 0) != (self.shown.map { $0.hits > 0 } ?? false)
        self.shown = shown
        // The header stays built under the other navigators, so it gives up the keyboard as it hides.
        if !shown.visible, [query, replacement].contains(where: { $0.currentEditor() != nil }) { window?.makeFirstResponder(nil) }
        for (field, text) in [(query, shown.query), (replacement, shown.replacement)]
            where field.stringValue != text && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        crumb.items = [Breadcrumb.Item(choices: Self.modes, chosen: shown.replacing ? 1 : 0),
                       Breadcrumb.Item(choices: Self.criteria, chosen: shown.wholeWords ? 1 : 0)]
        usages.stringValue = shown.usages.map { String(localized: "Usages of \($0)") } ?? ""
        for view in [crumb, matchCase] { view.isHidden = shown.usages != nil }
        usages.isHidden = shown.usages == nil
        matchCase.state = shown.matchCase ? .on : .off
        matchCase.contentTintColor = shown.matchCase ? .controlAccentColor : .secondaryLabelColor
        matchCase.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: shown.matchCase ? .bold : .regular)
        for view in [replacement, replace, replaceAll] { view.isHidden = !shown.replacing }
        replace.isEnabled = shown.chosen
        // Replace All changes every match in the project, so it waits until the filter no longer hides any.
        replaceAll.isEnabled = shown.total > 0 && !shown.filtered
        replaceAll.toolTip = shown.filtered ? String(localized: "Clear the filter to replace every match")
            : String(localized: "Replace all search results")
        count.stringValue = String(AttributedString(localized: "^[\(shown.hits) result](inflect: true) in ^[\(shown.files) file](inflect: true)").characters)
        count.isHidden = shown.hits == 0
        if resized { invalidateIntrinsicContentSize() }
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        var height = Self.row + 2 + Self.field
        if shown?.replacing == true { height += 6 + Self.field + 6 + Self.button }
        return NSSize(width: NSView.noIntrinsicMetric, height: height + ((shown?.hits ?? 0) > 0 ? 5 + Self.band : 6))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let path = crumb.intrinsicContentSize
        // Where Xcode's sits: 2 pt in, and 2 pt above the field.
        crumb.frame = NSRect(x: 2, y: Self.row - path.height, width: path.width, height: path.height)
        usages.frame = NSRect(x: 8, y: (Self.row - 14) / 2, width: width - 16, height: 14)
        // Xcode's nib gives Aa a fixed 21 by 16 pt frame, 8 pt from the end and 2 pt under the breadcrumb's top, so its title
        // grows from its centre as it turns bold.
        matchCase.frame = NSRect(x: width - 8 - 21, y: crumb.frame.minY + 2, width: 21, height: 16)
        var y = Self.row + 2
        query.frame = NSRect(x: 6, y: y, width: width - 12, height: Self.field)
        y += Self.field
        if shown?.replacing == true {
            replacement.frame = NSRect(x: 6, y: y + 6, width: width - 12, height: Self.field)
            y += 6 + Self.field + 6
            let all = replaceAll.intrinsicContentSize.width, one = replace.intrinsicContentSize.width
            replaceAll.frame = NSRect(x: width - 6 - all, y: y, width: all, height: Self.button)
            replace.frame = NSRect(x: replaceAll.frame.minX - 7 - one, y: y, width: one, height: Self.button)
            y += Self.button
        }
        let label = count.intrinsicContentSize.height
        count.frame = NSRect(x: 6, y: y + 5 + (Self.band - label) / 2, width: width - 12, height: label)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === query, selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        let step = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1
        query.remember()
        if !project.search.step(step, in: project.navigator.filtered(project.search.groups ?? [])) { NSSound.beep() }
        return true
    }

    @objc private func edited(_ field: NSSearchField) {
        if field === query { project.search.query = field.stringValue } else { project.search.replacement = field.stringValue }
    }

    private func choose(_ item: Int, _ choice: Int) {
        if item == 0 { project.search.replacing = choice == 1 } else { project.search.asked.wholeWords = choice == 1 }
    }

    @objc private func toggleCase() { project.search.asked.matchCase.toggle() }

    @objc private func replaceChosen() {
        replacement.remember()
        Task { await project.replaceChosen() }
    }

    @objc private func replaceEvery() {
        replacement.remember()
        Task { await project.replaceAll() }
    }

    /// The rows' heights: the mode row, regular fields and buttons, and Xcode's band for the count.
    private static let row: CGFloat = 20, field: CGFloat = 24, button: CGFloat = 24, band: CGFloat = 22
    private static let modes = [String(localized: "Find"), String(localized: "Replace")]
    private static let criteria = [String(localized: "Containing"), String(localized: "Matching Word")]
}

private struct FindHeaderView: NSViewRepresentable {
    let project: ProjectModel
    let field: FieldHandle
    /// What sets the header's height, so SwiftUI measures it again as it changes.
    let replacing: Bool, counted: Bool

    func makeNSView(context: Context) -> FindHeader { FindHeader(project: project, field: field) }
    func updateNSView(_ view: FindHeader, context: Context) { view.refresh() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FindHeader, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }
}

/// Find's results as Xcode lists them: under a count, each file a row that folds, its results under it.
struct SearchResults: View {
    let project: ProjectModel
    let field: FieldHandle
    @State private var folded: Set<String> = []

    var body: some View {
        let groups = project.navigator.filtered(project.search.groups ?? [])
        list(groups)
            .listStyle(.sidebar)
            .accessibilityLabel("Search Results")
            .safeAreaBar(edge: .top, spacing: 0) {
                FindHeaderView(project: project, field: field, replacing: project.search.replacing, counted: !groups.isEmpty)
            }
            .overlay {
                if let failure = project.search.failure {
                    ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(failure))
                } else if project.search.groups?.isEmpty == true {
                    ContentUnavailableView.search(text: project.search.searched.query)
                }
            }
            .onChange(of: project.search.searched) { folded = [] }
            .task(id: project.search.asked) {
                if project.search.isSearching { try? await Task.sleep(for: .milliseconds(200)) }
                guard !Task.isCancelled else { return }
                await project.search.run(in: project.session)
                guard !Task.isCancelled, project.search.groups != nil, project.search.failure == nil else { return }
                let count = project.search.hitCount
                project.notices.announce(count == 0 ? String(localized: "Not found") : Self.matches(count), queued: true)
            }
    }

    private func list(_ groups: [SearchGroup]) -> some View {
        ScrollViewReader { proxy in
            List(selection: Bindable(project.search).chosen) {
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: Binding { !folded.contains(group.file) } set: {
                        if $0 { folded.remove(group.file) } else { folded.insert(group.file) }
                    }) {
                        ForEach(group.hits) { row($0) }
                    } label: {
                        file(group).selectionDisabled()
                    }
                }
            }
            .onChange(of: project.search.chosen) { _, id in
                if let hit = hit(id) {
                    folded.remove(hit.file)
                    proxy.scrollTo(hit.id)
                }
                open(id, focus: false)
            }
            .contextMenu(forSelectionType: SearchHit.ID.self) { _ in } primaryAction: { ids in open(ids.first, focus: true) }
        }
    }

    /// Xcode's file rows: the file's icon, its name a little heavier than the results, then its folder, dimmer.
    private func file(_ group: SearchGroup) -> some View {
        Label {
            Text("\(Text(group.file.fileName).fontWeight(.medium)) \(Text(group.file.parentFolder.replacing("/", with: " ▸ ")).foregroundStyle(.secondary))")
                .lineLimit(1)
        } icon: {
            Image(systemName: project.tree.node(at: group.file)?.symbol ?? "text.document")
        }
        .navigatorRow()
        .help(group.file)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.file), \(Self.matches(group.hits.count))")
    }

    /// Xcode's result rows: a line glyph, then the line, its match bold.
    private func row(_ hit: SearchHit) -> some View {
        Label {
            Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)").lineLimit(3)
        } icon: {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .navigatorRow()
        .accessibilityValue("Line \(hit.line)")
    }

    private func hit(_ id: SearchHit.ID?) -> SearchHit? { project.search.groups?.lazy.flatMap(\.hits).first { $0.id == id } }

    private func open(_ id: SearchHit.ID?, focus: Bool) {
        if let found = hit(id) {
            Task { await project.open(found.file, line: found.line, column: found.column, length: found.length, focus: focus, jump: true) }
        }
    }

    static func matches(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) match](inflect: true)").characters)
    }
}
