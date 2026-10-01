import SwiftUI

/// The build panel's tabs, by title.
enum PanelTab: String, CaseIterable {
    case issues = "Issues", log = "Build Log"
}

/// The build panel below the editors: the build's issues, or its whole log.
/// No close button: the status bar's toggle and View › Hide Build Panel close it.
struct BuildPanel: View {
    @Bindable var project: ProjectModel
    @State private var filter = ""
    @State private var showWarnings = true

    var body: some View {
        VStack(spacing: 0) {
            HStack { header }
                // One height in both tabs: Copy Log's bezel is 2 pt taller than Warnings'.
                .frame(height: 24)
                .padding(.vertical, BarMetrics.inset)
                .paneBarControls()
                .buttonStyle(.accessoryBar)
                .labelStyle(.iconOnly)
            Group {
                switch project.panelTab {
                case .issues: issues
                case .log: log
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    /// The tabs, then what acts on the one showing; the build's summary is the
    /// status bar's.
    @ViewBuilder
    private var header: some View {
        Picker("Build Panel", selection: $project.panelTab) {
            ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.tabs)
        .labelsHidden()
        .fixedSize()
        .layoutPriority(1)
        Spacer(minLength: 0)
        if project.panelTab == .issues {
            if project.warningCount > 0 {
                Toggle(isOn: $showWarnings) {
                    Label("Warnings", systemImage: "exclamationmark.triangle")
                }
                .toggleStyle(.button)
                .help(showWarnings ? "Hide Warnings" : "Show Warnings")
            }
        } else {
            Button("Copy Log", systemImage: "document.on.document") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.result?.log ?? "", forType: .string)
            }
            .help("Copy Log")
            .disabled(project.result?.log.isEmpty ?? true)
        }
        SearchField(text: $filter, prompt: "Filter")
            .frame(minWidth: BarMetrics.fieldMinWidth, maxWidth: BarMetrics.fieldMaxWidth)
    }

    /// The issues showing, each by its place in the build's errors then warnings, so
    /// a row keeps its identity as the filter and Warnings change what shows (LaTeX
    /// repeats identical warnings).
    private var items: [(offset: Int, element: LogItem)] {
        let errors = project.result?.errors ?? []
        return (errors + (project.result?.warnings ?? [])).enumerated().filter { offset, item in
            (showWarnings || offset < errors.count) && matches(item)
        }
    }

    private func matches(_ item: LogItem) -> Bool {
        filter.isEmpty || item.message.localizedCaseInsensitiveContains(filter)
            || (item.file?.localizedCaseInsensitiveContains(filter) ?? false)
    }

    /// "No Issues" before any build too: the status bar says whether one has run.
    @ViewBuilder
    private var issues: some View {
        if !items.isEmpty {
            IssueList(items: items, project: project)
        } else if !showWarnings, project.result?.warnings.contains(where: matches) == true {
            ContentUnavailableView {
                Label("Warnings Hidden", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Show Warnings") { showWarnings = true }
            }
        } else if !filter.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
        }
    }

    @ViewBuilder
    private var log: some View {
        if let text = project.result?.log, !text.isEmpty {
            let lines = filter.isEmpty
                ? text
                : text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { $0.localizedCaseInsensitiveContains(filter) }
                    .joined(separator: "\n")
            // On under the status bar, as the issues' list is, its automatic insets
            // keeping the last line clear.
            LogTextView(text: lines, scrollsToEnd: filter.isEmpty)
                .ignoresSafeArea(.container, edges: .bottom)
        } else {
            ContentUnavailableView("No Log", systemImage: "text.page",
                                   description: Text("Compile to see the log here."))
        }
    }
}

/// The errors and warnings. Choosing one shows its line and leaves the keyboard
/// in the list, as the outline does; a double-click or Return goes into the source.
private struct IssueList: View {
    let items: [(offset: Int, element: LogItem)]
    let project: ProjectModel
    @State private var selection: Int?

    var body: some View {
        List(items, id: \.offset, selection: $selection) { IssueRow(item: $0.element) }
        .listStyle(.inset)
        .accessibilityLabel("Issues")
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int.self) { rows in
            if let item = rows.first.flatMap(item) {
                if item.file != nil {
                    Button("Go to Line") { open(item) }
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
        .copyable(selection.flatMap(item).map { [$0.message] } ?? [])
        // Kept while its row shows.
        .onChange(of: items.map(\.offset)) { _, shown in
            if let selection, !shown.contains(selection) { self.selection = nil }
        }
        .onChange(of: selection) { _, id in
            if let item = id.flatMap(item) { open(item, focus: false) }
        }
    }

    private func item(_ id: Int) -> LogItem? {
        items.first { $0.offset == id }?.element
    }

    private func open(_ item: LogItem, focus: Bool = true) {
        if let file = item.file { Task { await project.open(file, line: item.line, focus: focus) } }
    }
}

/// An error or warning: its message, and its location when the log names one.
private struct IssueRow: View {
    let item: LogItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Typography.subtitleSpacing) {
                Text(item.message).lineLimit(3)
                if let location = location(line: ":") {
                    Text(location)
                        .font(Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
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

/// The build log in an NSTextView: a SwiftUI Text lays out megabyte logs whole on every change.
private struct LogTextView: NSViewRepresentable {
    let text: String
    /// Unfiltered, the log opens at its end, where the error usually is.
    let scrollsToEnd: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        // Lines the text up with the header's controls; the fragment padding
        // would put it past them.
        view.textContainerInset = NSSize(width: BarMetrics.inset, height: BarMetrics.inset)
        view.textContainer?.lineFragmentPadding = 0
        view.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                          weight: .regular)
        // A text view has no title of its own for VoiceOver.
        view.setAccessibilityLabel("Build Log")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        guard view.string != text else { return }
        view.string = text
        if scrollsToEnd { view.scrollToEndOfDocument(nil) } else { view.scrollToBeginningOfDocument(nil) }
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
    LogTextView(text: "This is pdfTeX, Version 3.141592653\n(./main.tex\nLaTeX2e <2025-06-01>\n)\nOutput written on main.pdf (4 pages).",
                scrollsToEnd: false)
        .frame(width: 480, height: 160)
}
