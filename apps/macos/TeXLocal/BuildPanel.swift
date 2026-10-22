import SwiftUI

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
        let items = project.panel.rows(of: project.result)
        if !items.isEmpty {
            IssueList(items: items, project: project)
        } else if !project.panel.showsWarnings, project.result?.listed.contains(where: { !$0.isError && project.panel.matches($0) }) == true {
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

    private func open(_ item: LogItem) { if let file = item.file { Task { await project.open(file, line: item.line) } } }
}

private struct IssueRow: View {
    let item: LogItem
    let chosen: Bool
    let project: ProjectModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            label
            if let file = item.missing { install(file) }
        }
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message).lineLimit(chosen ? nil : 3)
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
        .help(item.message)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.isError ? "Error" : "Warning"): \(item.message)")
        .accessibilityValue(location(line: ", line ") ?? "")
    }

    /// As Xcode's Fix: a small button at the row's end, its progress in its place.
    @ViewBuilder private func install(_ file: String) -> some View {
        Spacer()
        if project.installing == file {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Button("Install") { Task { await project.install(file) } }
                .controlSize(.small)
                .disabled(project.installing != nil)
                .help("Install the TeX Live package with \(file), then compile again")
        }
    }

    private func location(line: String) -> String? { item.file.map { file in item.line.map { "\(file)\(line)\($0)" } ?? file } }
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
