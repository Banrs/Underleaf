import SwiftUI

/// What the build panel shows, by title: its bar's pop-up.
enum PanelTab: String, CaseIterable {
    case issues = "Issues", log = "Build Log", texpresso = "Live Preview Log"
}

/// The build panel's state for a project: whether it shows, what it shows, and its bar's settings.
@Observable
final class BuildPanelModel {
    /// TeXpresso's session, which follows its log while the panel shows it.
    private let texpresso: TeXpressoSession

    var shown = false {
        didSet {
            if !shown { openedByBuild = false }
            texpresso.showsLog = shown && tab == .texpresso
        }
    }
    /// A failed build opened the panel, so the next clean one closes it; one the person opened stays.
    @ObservationIgnored private var openedByBuild = false
    var tab: PanelTab = .issues {
        didSet { texpresso.showsLog = shown && tab == .texpresso }
    }
    /// The panel bar's filters over the issues and over the logs' lines, and whether warnings show.
    var issueFilter = ""
    var logFilter = ""
    var showsWarnings = true

    init(texpresso: TeXpressoSession) {
        self.texpresso = texpresso
    }

    /// The panel, open on `tab`. The issues include the core's fallback issue for a failed build.
    func show(_ tab: PanelTab) {
        self.tab = tab
        shown = true
    }

    /// A build the person asked for failed: the panel opens on its issues.
    func openForFailedBuild() {
        if !shown { openedByBuild = true }
        show(.issues)
    }

    /// A build the person asked for came out clean: the panel a failure opened closes, unless
    /// it was turned to a log since.
    func closeAfterCleanBuild() {
        if openedByBuild, tab == .issues { shown = false }
    }
}

/// The build panel below the editors and their status bar: the build's issues or its whole log,
/// ending at `BuildPanelBar` at the panel's foot, as Xcode's console at its bar, with a
/// line between. On the editors' surface, as Xcode's console is on its editor's.
/// No close button: the status bar's toggle and View › Hide Build Panel close it.
struct BuildPanel: View {
    let project: ProjectModel

    var body: some View {
        Group {
            switch project.panel.tab {
            case .issues: issues
            case .log: log
            case .texpresso:
                if project.texpresso.log.isEmpty {
                    ContentUnavailableView(project.texpresso.title, systemImage: "bolt",
                                           description: Text("The PDF pane shows Live Preview."))
                } else {
                    LogPane(text: project.texpresso.log, filter: project.panel.logFilter, title: "Live Preview Log")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.textSurface)
        // The bar's own line is the edge, the same over the list and over the logs, where SwiftUI
        // draws none (an AppKit scroll view).
        .scrollEdgeEffectHidden(true, for: .bottom)
        // In the panel's own content, not a split-item accessory, so the bar rides the panel's edge
        // as the panel opens: AppKit shows a bottom accessory only once the pane has its height
        // (27.2). A safe-area bar: in one a search field is the filled capsule it is in a toolbar,
        // as Xcode's console filter; in a plain stack it is a form's outlined field (27.2).
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                BuildPanelBar(project: project)
            }
        }
    }

    private func matches(_ item: LogItem) -> Bool {
        project.panel.issueFilter.isEmpty || item.message.localizedCaseInsensitiveContains(project.panel.issueFilter)
            || (item.file?.localizedCaseInsensitiveContains(project.panel.issueFilter) ?? false)
    }

    /// "No Issues" before any build too: the status bar says whether one has run.
    @ViewBuilder
    private var issues: some View {
        // Enumerate before filtering: duplicate messages keep distinct, stable row IDs.
        let items = project.issues.enumerated().filter { (project.panel.showsWarnings || $0.element.isError) && matches($0.element) }
        if !items.isEmpty {
            IssueList(items: items, project: project)
        } else if !project.panel.showsWarnings, project.result?.warnings.contains(where: matches) == true {
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

    @ViewBuilder
    private var log: some View {
        if let text = project.result?.log, !text.isEmpty {
            LogPane(text: text, filter: project.panel.logFilter)
        } else {
            ContentUnavailableView("No Log", systemImage: "text.page",
                                   description: Text("Compile to see the log here."))
        }
    }
}

/// The bar at the panel's foot, as Xcode's console bar: what the panel shows, chosen from a
/// pop-up as Xcode's console chooses its output, then that view's controls and filter. The panel's
/// content ends at the line over it (`BuildPanel`), and it paints the panel's surface. Its row is
/// the status bar's above it (`barRow`).
struct BuildPanelBar: View {
    let project: ProjectModel

    var body: some View {
        @Bindable var panel = project.panel
        HStack {
            Picker("Show", selection: $panel.tab) {
                // TeXpresso's is dim until it has been started in this window, when it has a log.
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).selectionDisabled(tab == .texpresso && !project.texpresso.used)
                }
            }
            .pickerStyle(.menu)
            // Borderless, as Xcode's console's output pop-up.
            .buttonStyle(.borderless)
            .labelsHidden()
            .fixedSize()
            .layoutPriority(1)
            Spacer(minLength: 0)
            // The view's button before its filter, as Xcode's console bar's toggles before its
            // filter: no icon on its own at the bar's end.
            if panel.tab == .issues {
                // Dim with no warnings to hide, and in its place all the same.
                Toggle(isOn: $panel.showsWarnings) {
                    Label("Warnings", systemImage: "exclamationmark.triangle")
                }
                .toggleStyle(.button)
                .help(panel.showsWarnings ? "Hide warnings" : "Show warnings")
                .disabled(project.warningCount == 0)
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
        .barRow(leading: BarMetrics.consoleLeading, trailing: BarMetrics.consoleTrailing)
        .background(.textSurface)
    }

    /// Xcode's console filter: the regular 24 pt field in a bar of small controls. At the small
    /// size a search field is an outlined box, and SwiftUI's change of size drops its symbol (27.2).
    private func filter(_ text: Binding<String>) -> some View {
        SearchField(text: text, prompt: "Filter", symbol: "line.3.horizontal.decrease.circle")
            .controlSize(.regular)
            .frame(maxWidth: 180)
    }
}

/// The errors and warnings. Choosing one shows its line and leaves the keyboard
/// in the list, as the outline does; a double-click or Return goes into the source.
/// Rows are places in the build's issues, and the chosen one the project's, as the menus move it too.
private struct IssueList: View {
    let items: [(offset: Int, element: LogItem)]
    let project: ProjectModel

    var body: some View {
        let selection = Binding { project.chosenIssue } set: { project.chooseIssue($0, focus: false) }
        ScrollViewReader { proxy in
            List(items, id: \.offset, selection: selection) { IssueRow(item: $0.element, chosen: $0.offset == project.chosenIssue) }
                .listStyle(.inset)
                // The panel's surface, the editors': a list's own is the window's, tinted by the wallpaper.
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Issues")
                .contextMenu(forSelectionType: Int.self) { rows in
                    if let item = rows.first.flatMap(item) {
                        if item.file != nil {
                            Button(item.line == nil ? "Open File" : "Go to Line") { open(item) }
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.message, forType: .string)
                        }
                    }
                } primaryAction: { rows in
                    if let item = rows.first.flatMap(item) { open(item) }
                }
                // Edit › Copy copies the selected issue.
                .copyable(project.chosenIssue.flatMap(item).map { [$0.message] } ?? [])
                // The menus' choice may be out of sight, and the panel closed: a hidden list
                // scrolls by its rows' estimated heights, so again as it comes up.
                .onChange(of: project.chosenIssue) { _, place in
                    if let place { proxy.scrollTo(place) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _ in
                    if let place = project.chosenIssue { proxy.scrollTo(place) }
                }
        }
    }

    private func item(_ id: Int) -> LogItem? {
        items.first { $0.offset == id }?.element
    }

    private func open(_ item: LogItem) {
        if let file = item.file { Task { await project.open(file, line: item.line) } }
    }
}

/// An error or warning: its message, and its location when the log names one.
private struct IssueRow: View {
    let item: LogItem
    /// The chosen row shows its whole message; the others' tooltips have theirs.
    var chosen = false

    var body: some View {
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
        // Spoken as words: "main.tex, line 12", not "main.tex colon 12".
        .accessibilityValue(location(line: ", line ") ?? "")
    }

    /// The file, and its line after `line`; nil when the log names none.
    private func location(line: String) -> String? {
        item.file.map { file in item.line.map { "\(file)\(line)\($0)" } ?? file }
    }
}

/// The log over the panel's bar: the text view is inset by the bar's height, so its last line and
/// its scroller end at the bar's top. The bar's safe area reaches SwiftUI but not an AppKit scroll
/// view, which takes the inset itself. With the bar's filter, only the lines with it in them, as
/// Xcode's console filters its output.
private struct LogPane: View {
    let text: String
    let filter: String
    var title = "Build Log"
    /// The filter's lines, found off the main actor when the log or the filter changes: not on
    /// every redraw of a log that can be megabytes. Nil until the first are in; until the next
    /// are, the last non-empty ones stay, and an empty result is no answer to another filter.
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
            filtered = filter.isEmpty ? nil : (filter, await Self.lines(of: text, with: filter))
        }
    }

    @concurrent private nonisolated static func lines(of text: String, with filter: String) async -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }
}

/// The build log in an NSTextView: a SwiftUI Text lays out megabyte logs whole on every change.
/// It opens at its end, where the error usually is.
struct LogTextView: NSViewRepresentable {
    let text: String
    var title = "Build Log"
    /// The bar over the text view's foot (`LogPane`).
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

    /// The text last shown: an update that leaves the log as it was (another view or the
    /// filter chosen) compares the same storage, without passes over a megabyte log.
    final class Coordinator {
        var shown: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        // A text view has no title of its own for VoiceOver.
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
        // Append without invalidating the entire log's layout. A new build or
        // bounded log rollover can replace it; keep reading position in either case.
        let previousLength = (shown as NSString).length, new = text as NSString
        if previousLength > 0, text.utf16.starts(with: shown.utf16) {
            view.textStorage?.replaceCharacters(in: NSRange(location: previousLength, length: 0),
                                                with: new.substring(from: previousLength))
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

#Preview("Issues") {
    List {
        IssueRow(item: LogItem(type: "error", file: "chapters/intro.tex", line: 42, message: "Undefined control sequence."))
        IssueRow(item: LogItem(type: "warning", file: "main.tex", line: nil, message: "Citation `knuth84' undefined."))
        IssueRow(item: LogItem(type: "warning", file: nil, line: nil, message: "There were undefined references."))
    }
    .listStyle(.inset)
    .frame(width: 480, height: 200)
}

#Preview("Build log") {
    LogTextView(text: "This is pdfTeX, Version 3.141592653\n(./main.tex\nLaTeX2e <2025-06-01>\n)\nOutput written on main.pdf (4 pages).")
        .frame(width: 480, height: 160)
}
