import SwiftUI

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
    func rows(of listed: [LogItem]) -> [(offset: Int, element: LogItem)] {
        listed.enumerated().filter { (showsWarnings || $0.element.isError) && matches($0.element) }
    }
}

struct BuildPanel: View {
    let project: ProjectModel

    var body: some View {
        Group {
            switch project.panel.tab {
            case .issues: issues
            case .log: log
            case .texpresso:
                if project.texpresso.log.isEmpty {
                    ContentUnavailableView(project.texpresso.title, systemImage: "bolt", description: Text(
                        project.texpresso.active ? "The PDF pane shows Live Preview." : "Its log shows here while it runs."))
                } else {
                    LogPane(text: project.texpresso.log, filter: project.panel.logFilter, title: "Live Preview Log")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.textSurface)
        // The bar's own line is the edge, where SwiftUI draws none (an AppKit scroll view).
        .scrollEdgeEffectHidden(true, for: .bottom)
        // 27.2: not a split item's accessory, which AppKit shows only once the pane has its height. In a safe-area bar a
        // search field is a toolbar's filled capsule.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                BuildPanelBar(project: project)
            }
        }
    }

    /// "No Issues" before any build too: the status bar says whether one has run.
    @ViewBuilder private var issues: some View {
        let items = project.panel.rows(of: project.listed)
        if !items.isEmpty {
            IssueList(items: items, project: project)
        } else if !project.panel.showsWarnings, project.listed.contains(where: { !$0.isError && project.panel.matches($0) }) {
            ContentUnavailableView {
                Label("Warnings Hidden", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Show Warnings") { project.panel.showsWarnings = true }
            }
        } else if !project.panel.issueFilter.isEmpty {
            ContentUnavailableView.search(text: project.panel.issueFilter)
        } else {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
        }
    }

    @ViewBuilder private var log: some View {
        if let text = project.result?.log, !text.isEmpty {
            LogPane(text: text, filter: project.panel.logFilter)
        } else {
            ContentUnavailableView("No Log", systemImage: "text.page", description: Text("Compile to see the log here."))
        }
    }
}

struct BuildPanelBar: View {
    let project: ProjectModel

    var body: some View {
        @Bindable var panel = project.panel
        HStack {
            Picker("Show", selection: $panel.tab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).selectionDisabled(tab == .texpresso && !project.texpresso.used)
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .labelsHidden()
            .fixedSize()
            .layoutPriority(1)
            Spacer(minLength: 0)
            if panel.tab == .issues {
                Toggle(isOn: $panel.showsWarnings) { Label("Warnings", systemImage: "exclamationmark.triangle") }
                .toggleStyle(.button)
                .help(panel.showsWarnings ? "Hide warnings" : "Show warnings")
                .disabled(project.warningCount == 0 && project.result?.badBoxes.isEmpty != false)
                filter($panel.issueFilter)
            } else {
                let text = panel.tab == .texpresso ? project.texpresso.log : project.result?.log ?? ""
                Button("Copy Log", systemImage: "document.on.document") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .help("Copy the whole log")
                .disabled(text.isEmpty)
                filter($panel.logFilter)
            }
        }
        .buttonStyle(.accessoryBar)
        .labelStyle(.iconOnly)
        .barRow(leading: 12, trailing: 17)
        .background(.textSurface)
    }

    /// Small, a search field is an outlined box, and SwiftUI's change of size drops its symbol (27.2).
    private func filter(_ text: Binding<String>) -> some View {
        SearchField(text: text, prompt: "Filter", symbol: "line.3.horizontal.decrease.circle")
            .controlSize(.regular)
            .frame(maxWidth: 180)
    }
}

private struct IssueList: View {
    let items: [(offset: Int, element: LogItem)]
    let project: ProjectModel

    var body: some View {
        let selection = Binding { project.chosenIssue } set: { project.chooseIssue($0, focus: false) }
        ScrollViewReader { proxy in
            List(items, id: \.offset, selection: selection) {
                IssueRow(item: $0.element, chosen: $0.offset == project.chosenIssue, project: project)
            }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Issues")
                .contextMenu(forSelectionType: Int.self) { rows in
                    if let item = rows.first.flatMap(item) {
                        if item.file != nil { Button(item.line == nil ? "Open File" : "Go to Line") { open(item) } }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.message, forType: .string)
                        }
                    }
                } primaryAction: { rows in if let item = rows.first.flatMap(item) { open(item) } }
                .copyable(project.chosenIssue.flatMap(item).map { [$0.message] } ?? [])
                // A hidden list scrolls by its rows' estimated heights, so again as it comes up.
                .onChange(of: project.chosenIssue) { _, place in if let place { proxy.scrollTo(place) } }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _ in
                    if let place = project.chosenIssue { proxy.scrollTo(place) }
                }
        }
    }

    private func item(_ id: Int) -> LogItem? { items.first { $0.offset == id }?.element }

    private func open(_ item: LogItem) { if let file = item.file { Task { await project.open(file, line: item.line, jump: true) } } }
}

private struct IssueRow: View {
    let item: LogItem
    let chosen: Bool
    let project: ProjectModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            label
            if let fix = item.fix { offer(fix) }
        }
    }

    /// The explanation under the message, as Xcode shows an issue's note.
    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message).lineLimit(chosen ? nil : 3)
                if let explain = item.explain { Text(explain).foregroundStyle(.secondary) }
                if let location = location(line: ":") {
                    Text(location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        .help([item.message, item.explain].compactMap(\.self).joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.isError ? "Error" : "Warning"): \(item.message)")
        .accessibilityValue([item.explain, location(line: ", line ")].compactMap(\.self).joined(separator: " "))
    }

    /// As Xcode's Fix: a small button at the row's end, its progress in its place.
    @ViewBuilder private func offer(_ fix: LogItem.Fix) -> some View {
        Spacer()
        if project.fixing == fix {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(fix.progress).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Button(fix.title) { Task { if await confirmed(fix) { await project.run(fix) } } }
                .controlSize(.small)
                .disabled(project.fixing != nil)
                .help(fix.help)
        }
    }

    /// AppKit's, as the window's other questions are: the fix's title on the default button (HIG, Alerts).
    private func confirmed(_ fix: LogItem.Fix) async -> Bool {
        guard let confirm = fix.confirm else { return true }
        let alert = NSAlert()
        alert.messageText = "\(fix.title)?"
        alert.informativeText = confirm
        alert.addButton(withTitle: fix.title)
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = project.editor.textView.window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private func location(line: String) -> String? { item.file.map { file in item.line.map { "\(file)\(line)\($0)" } ?? file } }
}

/// The bar's safe area reaches SwiftUI but not an AppKit scroll view, which takes it as an inset.
private struct LogPane: View {
    let text: String
    let filter: String
    var title = "Build Log"
    /// Found off the main actor, not on every redraw of a log that can be megabytes; the last ones stay until the next.
    @State private var filtered: (filter: String, lines: String)?

    var body: some View {
        let current = filtered?.filter == filter ? filtered?.lines : nil
        let previous = filtered.flatMap { $0.lines.isEmpty ? nil : $0.lines }
        let shown = filter.isEmpty ? text : current ?? previous ?? text
        Group {
            if shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                GeometryReader { geometry in
                    LogTextView(text: shown, title: title, bottomInset: geometry.safeAreaInsets.bottom)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .task(id: [text, filter]) {
            guard !filter.isEmpty else { return filtered = nil }
            if let lines = await Self.lines(of: text, with: filter), !Task.isCancelled { filtered = (filter, lines) }
        }
    }

    @concurrent private nonisolated static func lines(of text: String, with filter: String) async -> String? {
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if Task.isCancelled { return nil }
            if line.localizedCaseInsensitiveContains(filter) { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }
}

/// A SwiftUI Text lays out megabyte logs whole on every change.
struct LogTextView: NSViewRepresentable {
    let text: String
    var title = "Build Log"
    var bottomInset: CGFloat = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                          weight: .regular)
        return scroll
    }

    /// An unchanged log compares the same storage, without passes over a megabyte log.
    final class Coordinator { var shown: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.setAccessibilityLabel(title)
        if scroll.contentInsets.bottom != bottomInset {
            let atEnd = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets.bottom = bottomInset
            scroll.scrollerInsets.bottom = bottomInset
            if atEnd { view.scrollToEndOfDocument(nil) }
        }
        guard context.coordinator.shown != text else { return }
        updateText(in: scroll)
        context.coordinator.shown = text
    }

    func updateText(in scroll: NSScrollView) {
        let view = scroll.documentView as! NSTextView
        let shown = view.string
        guard shown != text else { return }
        let selections = view.selectedRanges.map(\.rangeValue)
        let origin = scroll.contentView.bounds.origin
        let followsTail = !scroll.isFindBarVisible && selections.allSatisfy { $0.length == 0 }
            && (shown.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1)
        // Appended without laying the whole log out again, unless a new build or the log's rollover replaced it.
        let previousLength = (shown as NSString).length, new = text as NSString
        if previousLength > 0, text.utf16.starts(with: shown.utf16) {
            view.textStorage?.replaceCharacters(in: .caret(previousLength), with: new.substring(from: previousLength))
        } else {
            view.string = text
        }
        view.didChangeText()
        let length = new.length
        view.selectedRanges = selections.map { range in
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        if followsTail {
            view.scrollToEndOfDocument(nil)
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
