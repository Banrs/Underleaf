import SwiftUI

/// The build panel's tabs.
enum PanelTab: String, CaseIterable, Identifiable {
    case issues, log

    var id: Self { self }

    var title: String {
        switch self {
        case .issues: "Issues"
        case .log: "Build Log"
        }
    }
}

/// The build panel below the editors: the build's issues, or its whole log
/// (web/src/logs.js `renderLogs`). The status bar's toggle and View › Hide
/// Build Panel close it, as Xcode's debug area has no close button of its own.
struct PanelView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: ProjectModel
    @State private var filter = ""
    @State private var showWarnings = true

    var body: some View {
        VStack(spacing: 0) {
            PaneBar { header }
            Divider()
            Group {
                switch project.panelTab {
                case .issues: issues
                case .log: log
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Content, on the text's surface as the source is.
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    /// The tabs, then what acts on the one showing. The build's summary is
    /// the status bar's, directly below, so it isn't repeated here.
    private var header: some View {
        Group {
            Picker("Build Panel", selection: $project.panelTab) {
                ForEach(PanelTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .layoutPriority(1)
            Spacer(minLength: BarMetrics.groupSpacing)
            if project.panelTab == .issues {
                Toggle(isOn: $showWarnings) {
                    Label("Warnings", systemImage: "exclamationmark.triangle")
                }
                .toggleStyle(.button)
                .help(showWarnings ? "Hide Warnings" : "Show Warnings")
                .disabled(project.warningCount == 0)
            } else {
                Button("Copy Log", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(project.result?.log ?? "", forType: .string)
                }
                .help("Copy Log")
                .disabled(project.result?.log.isEmpty ?? true)
            }
            SearchField(text: $filter, prompt: "Filter")
                .frame(minWidth: BarMetrics.fieldMinWidth, maxWidth: BarMetrics.fieldMaxWidth)
        }
        .labelStyle(.iconOnly)
    }

    private var items: [LogItem] {
        let all = (project.result?.errors ?? []) + (showWarnings ? project.result?.warnings ?? [] : [])
        guard !filter.isEmpty else { return all }
        return all.filter { item in
            item.message.localizedCaseInsensitiveContains(filter)
                || (item.file?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    @ViewBuilder
    private var issues: some View {
        if project.result == nil {
            // A PDF from an earlier session may be on screen; its build's
            // issues weren't kept, so don't claim there was never one.
            ContentUnavailableView {
                Label(project.noBuildTitle, systemImage: "hammer")
            } description: {
                Text("Compile to see errors and warnings here.")
            } actions: {
                Button("Compile") { app.perform(.compileRun) }
                    .disabled(!app.isEnabled(.compileRun))
            }
        } else if items.isEmpty {
            if !filter.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else if project.result?.ok == false {
                // The build failed on something the log's parser didn't
                // pick out as an error: the log itself says what.
                ContentUnavailableView {
                    Label("Build Failed", systemImage: "xmark.octagon")
                } description: {
                    Text("The build log shows what went wrong.")
                } actions: {
                    Button("Show Build Log") { project.panelTab = .log }
                }
            } else {
                ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
            }
        } else {
            IssueList(items: items, project: project)
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
            LogTextView(text: lines, scrollsToEnd: filter.isEmpty)
        } else {
            ContentUnavailableView("No Log", systemImage: "doc.plaintext",
                                   description: Text("Compile to see the log here."))
        }
    }
}

/// The errors and warnings as a list with the system's selection: a click
/// selects, a double-click or Return opens the line — in the main file when
/// the log names none, as the web's does.
private struct IssueList: View {
    let items: [LogItem]
    let project: ProjectModel
    @State private var selection: Int?

    var body: some View {
        // By position: LaTeX repeats identical warnings, which would share
        // an id built from their contents.
        List(Array(items.enumerated()), id: \.offset, selection: $selection) { _, item in
            IssueRow(item: item, location: location(of: item))
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int.self) { rows in
            if let row = rows.first {
                if file(of: items[row]) != nil {
                    Button("Go to Line") { open(items[row]) }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(items[row].message, forType: .string)
                }
            }
        } primaryAction: { rows in
            if let row = rows.first { open(items[row]) }
        }
        .onChange(of: items.count) { _, _ in selection = nil }
    }

    private func open(_ item: LogItem) {
        if let file = file(of: item) { Task { await project.open(file, line: item.line) } }
    }

    private func file(of item: LogItem) -> String? {
        item.file ?? (item.line == nil ? nil : project.settings?.mainFile)
    }

    /// Where a row opens, so every row that goes somewhere says where.
    private func location(of item: LogItem) -> String? {
        file(of: item).map { file in item.line.map { "\(file):\($0)" } ?? file }
    }
}

/// An error or warning: its message, and where it is when the log says.
private struct IssueRow: View {
    let item: LogItem
    /// "file:line", the main file's when the log names none.
    let location: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message).lineLimit(3)
                if let location {
                    Text(location)
                        .font(Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.isError ? .red : .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.isError ? "Error" : "Warning"): \(item.message)")
    }
}

/// The build log in AppKit's text view: native scrolling and selection, the
/// system find bar (⌘F), and fast with the megabyte logs LaTeX writes, which
/// a SwiftUI Text laid out whole on every change.
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
        view.isSelectable = true
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.font = Typography.secondaryMono
        view.textColor = .labelColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        guard view.string != text else { return }
        view.string = text
        if scrollsToEnd { view.scrollToEndOfDocument(nil) } else { view.scrollToBeginningOfDocument(nil) }
    }
}
